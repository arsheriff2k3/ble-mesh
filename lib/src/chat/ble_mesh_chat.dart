import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'ble_chat_transport.dart';
import 'chat_models.dart';
import 'chat_transport.dart';
import 'crypto/chat_keys.dart';
import 'crypto/group_crypto.dart';
import 'crypto/message_cipher.dart';
import 'crypto/packet_security.dart';
import 'crypto/trust_store.dart';
import 'message_store.dart';

/// High-level offline mesh chat facade.
class BleMeshChat {
  BleMeshChat({
    this.security,
    GroupStore? groupStore,
    MessageStore? store,
    DedupeCache? dedupeCache,
    DateTime Function()? clock,
    Random? random,
    this.defaultTtl = 5,
    this.messageLifetime = const Duration(hours: 1),
    this.maximumRelayJitter = const Duration(milliseconds: 250),
    this.minimumRelaySpacing = const Duration(milliseconds: 50),
    this.maximumPendingInbound = 256,
    this.retryBackoff = const Duration(seconds: 2),
    this.maximumRetryBackoff = const Duration(minutes: 2),
    this.retrySpacing = const Duration(milliseconds: 50),
  }) : _store = store ?? InMemoryMessageStore(),
       _groupStore = groupStore ?? InMemoryGroupStore(),
       _clock = clock ?? DateTime.now,
       _random = random ?? Random.secure(),
       _dedupe = dedupeCache ?? DedupeCache(clock: clock);

  /// When present, outbound packets are signed, direct messages are sealed,
  /// and unauthenticated inbound packets are dropped.
  final PacketSecurity? security;

  final MessageStore _store;
  final GroupStore _groupStore;
  final GroupCipher _groupCipher = const GroupCipher();
  final Map<String, ChatGroup> _groups = {};
  final DedupeCache _dedupe;
  final DateTime Function() _clock;
  final Random _random;
  final int defaultTtl;
  final Duration messageLifetime;
  final Duration maximumRelayJitter;
  final Duration minimumRelaySpacing;
  final int maximumPendingInbound;
  DateTime? _lastRelayAt;
  Future<void> _inboundWork = Future<void>.value();
  int _pendingInbound = 0;

  /// First retry delay after a failed flush; doubles per consecutive failure.
  final Duration retryBackoff;

  /// Ceiling for [retryBackoff] growth.
  final Duration maximumRetryBackoff;

  /// Pause between packets while draining a backlog.
  final Duration retrySpacing;

  final _messages = StreamController<ChatMessage>.broadcast();
  final _peers = StreamController<List<ChatPeer>>.broadcast();
  final _groupChanges = StreamController<List<ChatGroup>>.broadcast();
  final _states = StreamController<MessageStateChange>.broadcast();
  final _errors = StreamController<Object>.broadcast();
  final _subscriptions = <StreamSubscription<void>>[];
  final Map<String, ChatPeer> _knownPeers = {};
  final Map<String, String> _messageIdByPacketId = {};
  final Map<String, String> _recipientByPacketId = {};

  /// Messages replayed from the store, so restoring does not rewrite them.
  final Set<String> _restoredMessageIds = {};
  final Set<String> _deliveredMessageIds = {};
  final Map<String, DateTime> _acknowledgedPacketIds = {};
  final Map<String, DateTime> _lastAcknowledgementAt = {};
  final Map<String, ReceivedChatPacket> _pendingGroupPackets = {};
  final Map<String, ReceivedChatPacket> _relayCache = {};

  /// Consecutive failed flushes, used to space out retries.
  int _flushFailures = 0;
  Timer? _retryTimer;
  List<ChatTransport> _transports = const [];
  ChatIdentity? _identity;
  bool _initialized = false;
  bool _flushing = false;

  Stream<ChatMessage> get messages => _messages.stream;
  Stream<List<ChatPeer>> get peers => _peers.stream;
  Stream<List<ChatGroup>> get groupChanges => _groupChanges.stream;
  Stream<MessageStateChange> get messageStates => _states.stream;
  Stream<Object> get errors => _errors.stream;
  bool get isInitialized => _initialized;
  Map<String, ChatGroup> get groups => Map.unmodifiable(_groups);

  Future<void> initialize({
    required ChatIdentity identity,
    required List<ChatTransport> transports,
  }) async {
    if (_initialized) throw StateError('BleMeshChat is already initialized');
    if (transports.isEmpty) {
      throw ArgumentError('at least one transport is required');
    }
    if (security != null && security!.identity.peerId != identity.peerId) {
      throw ArgumentError('identity must match the signing key');
    }
    _initialized = true;
    _identity = identity;
    await _store.open();
    _groups.addAll(await _groupStore.load());
    await _restore();
    await _expireQueued();
    for (final pending in await _store.queued()) {
      if (pending.type == ChatPacketType.groupKeyUpdate &&
          pending.destination.startsWith('p:')) {
        _recipientByPacketId[pending.id] = pending.destination.substring(2);
      }
    }
    _transports = List.unmodifiable(transports);
    for (final transport in _transports) {
      _subscriptions.addAll([
        transport.incoming.listen(_enqueueInbound, onError: _errors.add),
        transport.availabilityChanges.listen((available) {
          if (available) unawaited(_flushQueue());
        }, onError: _errors.add),
        transport.peers.listen(
          (peers) => _updatePeers(transport.id, peers),
          onError: _errors.add,
        ),
      ]);
      try {
        await transport.start();
      } on Object catch (error) {
        _errors.add(error);
      }
    }
    await _flushQueue();
  }

  Future<ChatMessage> send({
    required String conversationId,
    required String text,
  }) => _sendMessage(destination: 'c:$conversationId', text: text);

  Future<ChatMessage> sendDirect({
    required String peerId,
    required String text,
  }) => _sendMessage(destination: 'p:$peerId', text: text);

  /// Creates an encrypted group and delivers its first key to every member.
  /// All member public keys must already be discovered or pinned.
  Future<ChatGroup> createGroup({required Set<String> memberIds}) async {
    final identity = _requireIdentity();
    final keyed = security;
    if (keyed == null) {
      throw StateError('group encryption requires PacketSecurity');
    }
    final members = {...memberIds, identity.peerId};
    if (members.length > 64) throw ArgumentError('group has too many members');
    _requireMemberKeys(members, identity.peerId);
    final group = ChatGroup(
      id: '${identity.peerId}/${packetIdToHex(createPacketId(_random))}',
      ownerId: identity.peerId,
      epoch: 1,
      members: members,
      key: Uint8List.fromList(await (await aead.newSecretKey()).extractBytes()),
    );
    await _saveGroup(group);
    await _distributeGroup(group);
    return group;
  }

  /// Adds or removes members, replacing the key for every remaining member.
  /// Removed members never receive the new epoch and cannot open new traffic.
  Future<ChatGroup> changeGroupMembers({
    required String groupId,
    required Set<String> memberIds,
  }) async {
    final identity = _requireIdentity();
    final prior = _groups[groupId];
    if (prior == null || prior.ownerId != identity.peerId) {
      throw StateError('only the group owner may change membership');
    }
    final members = {...memberIds, identity.peerId};
    if (members.length > 64) throw ArgumentError('group has too many members');
    if (prior.epoch == 0xffffffff) throw StateError('group epoch exhausted');
    _requireMemberKeys(members, identity.peerId);
    final next = ChatGroup(
      id: prior.id,
      ownerId: prior.ownerId,
      epoch: prior.epoch + 1,
      members: members,
      key: Uint8List.fromList(await (await aead.newSecretKey()).extractBytes()),
    );
    await _saveGroup(next);
    await _distributeGroup(next);
    return next;
  }

  Future<ChatMessage> sendGroup({
    required String groupId,
    required String text,
  }) async {
    final identity = _requireIdentity();
    final keyed = security;
    final group = _groups[groupId];
    if (keyed == null ||
        group == null ||
        !group.members.contains(identity.peerId)) {
      throw StateError('group key unavailable');
    }
    if (text.isEmpty) {
      throw ArgumentError.value(text, 'text', 'must not be empty');
    }
    final now = _clock();
    final original = ChatPacket(
      type: ChatPacketType.groupMessage,
      packetId: createPacketId(_random),
      senderId: identity.peerId,
      destination: 'g:$groupId',
      ttl: defaultTtl,
      createdAt: now,
      expiresAt: now.add(messageLifetime),
      payload: Uint8List.fromList(utf8.encode(text)),
    ).withSenderKeys(keyed.identity.publicKeys);
    final ciphertext = await _groupCipher.encrypt(original, group);
    final packet = await keyed.protect(
      ChatPacket(
        type: original.type,
        packetId: original.packetId,
        senderId: original.senderId,
        destination: original.destination,
        ttl: original.ttl,
        createdAt: original.createdAt,
        expiresAt: original.expiresAt,
        payload: ciphertext,
        senderKeys: original.senderKeys,
      ),
      encrypt: false,
    );
    final message = ChatMessage(
      id: packet.id,
      conversationId: groupId,
      threadId: groupId,
      isDirect: false,
      senderId: identity.peerId,
      text: text,
      createdAt: now,
      isLocal: true,
    );
    _dedupe.remember(packet.id, packet.expiresAt);
    await _remember(packet);
    await _persist(message);
    _messages.add(message);
    await _attemptSend(packet, emitSending: true);
    return message;
  }

  void _requireMemberKeys(Set<String> members, String selfId) {
    for (final id in members) {
      if (id != selfId && _keysFor(id) == null) {
        throw MessageSecurityException('member key unknown: $id');
      }
    }
  }

  Future<void> _saveGroup(ChatGroup group) async {
    if (!_groups.containsKey(group.id) && _groups.length >= 256) {
      throw StateError('group limit reached');
    }
    final next = {..._groups, group.id: group};
    await _groupStore.save(next);
    _groups
      ..clear()
      ..addAll(next);
    _groupChanges.add(List.unmodifiable(_groups.values));
  }

  Future<void> _distributeGroup(ChatGroup group) async {
    final keyed = security!;
    final now = _clock();
    final payload = Uint8List.fromList(utf8.encode(jsonEncode(group.toJson())));
    for (final id in group.members) {
      if (id == keyed.identity.peerId) continue;
      final packet = await keyed.protect(
        ChatPacket(
          type: ChatPacketType.groupKeyUpdate,
          packetId: createPacketId(_random),
          senderId: keyed.identity.peerId,
          destination: 'p:$id',
          ttl: defaultTtl,
          createdAt: now,
          expiresAt: now.add(messageLifetime),
          payload: payload,
        ),
        encrypt: true,
        recipient: _keysFor(id),
      );
      _recipientByPacketId[packet.id] = id;
      await _attemptSend(packet);
    }
  }

  Future<void> _acceptGroupUpdate(ChatPacket packet, String selfId) async {
    if (packet.isSealed || packet.type != ChatPacketType.groupKeyUpdate) {
      throw const MessageSecurityException('invalid group update');
    }
    final decoded =
        jsonDecode(utf8.decode(packet.payload)) as Map<String, dynamic>;
    final group = ChatGroup.fromJson(decoded);
    if (group.ownerId != packet.senderId ||
        !group.members.contains(selfId) ||
        group.id.length > 128 ||
        packet.payload.length > 4096) {
      throw const MessageSecurityException('invalid group update');
    }
    final prior = _groups[group.id];
    if (prior != null && group.epoch <= prior.epoch) return;
    await _saveGroup(group);
    _retryPendingGroup(group.id);
  }

  void _retryPendingGroup(String groupId) {
    final pending = _pendingGroupPackets.entries
        .where((entry) => entry.value.packet.destination == 'g:$groupId')
        .toList();
    for (final entry in pending) {
      _pendingGroupPackets.remove(entry.key);
      _enqueueInbound(entry.value, replayGroup: true);
    }
  }

  void _holdGroupPacket(ReceivedChatPacket received) {
    _pendingGroupPackets.removeWhere(
      (_, item) => item.packet.isExpired(_clock()),
    );
    if (_pendingGroupPackets.length >= 64) {
      _pendingGroupPackets.remove(_pendingGroupPackets.keys.first);
    }
    _pendingGroupPackets[received.packet.id] = received;
  }

  Future<ChatMessage> _sendMessage({
    required String destination,
    required String text,
  }) async {
    final identity = _requireIdentity();
    if (text.isEmpty) {
      throw ArgumentError.value(text, 'text', 'must not be empty');
    }
    final now = _clock();
    final isDirect = destination.startsWith('p:');
    var packet = ChatPacket(
      type: ChatPacketType.message,
      packetId: createPacketId(_random),
      senderId: identity.peerId,
      destination: destination,
      ttl: defaultTtl,
      createdAt: now,
      expiresAt: now.add(messageLifetime),
      payload: utf8.encode(text),
    );
    final keyed = security;
    if (keyed != null) {
      // Direct messages are sealed; the public channel remains signed and
      // readable. Encrypted groups use sendGroup().
      packet = await keyed.protect(
        packet,
        encrypt: isDirect,
        recipient: isDirect ? _keysFor(destination.substring(2)) : null,
      );
    }
    final message = ChatMessage(
      id: packet.id,
      conversationId: destination.substring(2),
      // We are the sender, so the remote participant is the destination.
      threadId: destination.substring(2),
      isDirect: isDirect,
      senderId: identity.peerId,
      text: text,
      createdAt: now,
      isLocal: true,
    );
    _messageIdByPacketId[packet.id] = message.id;
    if (isDirect) _recipientByPacketId[packet.id] = destination.substring(2);
    _dedupe.remember(packet.id, packet.expiresAt);
    await _remember(packet);
    _messages.add(message);
    await _persist(message);
    await _attemptSend(packet, emitSending: true);
    return message;
  }

  /// Prefer the explicitly approved pin over a cached live announcement.
  ChatPublicKeys? _keysFor(String peerId) {
    if (_knownPeers.values.any(
      (peer) => peer.id == peerId && peer.trust == PeerTrust.changed,
    )) {
      return null;
    }
    final pinned = security?.trustStore.keysFor(peerId);
    if (pinned != null) return pinned;
    for (final peer in _knownPeers.values) {
      if (peer.id == peerId && peer.publicKeys != null) return peer.publicKeys;
    }
    return security?.trustStore.keysFor(peerId);
  }

  /// Replays durable state so a restart looks like the app never closed.
  ///
  /// History is emitted before any transport starts, so a host that renders
  /// [messages] has the previous session on screen before the radio is even
  /// powered, which is the difference between "restored" and "reappeared".
  Future<void> _restore() async {
    try {
      final restored = await _store.messages();
      final states = await _store.states();
      _dedupe.restore(await _store.seen());
      for (final message in restored) {
        _restoredMessageIds.add(message.id);
        if (message.isLocal && message.isDirect) {
          _recipientByPacketId[message.id] = message.threadId;
        }
        _messages.add(message);
        final state = states[message.id];
        if (state != null) {
          if (state == MessageState.delivered) {
            _deliveredMessageIds.add(message.id);
          }
          _states.add(MessageStateChange(messageId: message.id, state: state));
        }
      }
    } on Object catch (error) {
      // A store we cannot read must not stop the app from chatting now.
      _errors.add(error);
    }
  }

  Future<bool> _attemptSend(
    ChatPacket packet, {
    bool emitSending = false,
  }) async {
    if (packet.type == ChatPacketType.groupMessage) {
      final group = packet.destination.startsWith('g:')
          ? _groups[packet.destination.substring(2)]
          : null;
      final epoch = packet.payload.length >= 4
          ? ByteData.sublistView(packet.payload).getUint32(0)
          : 0;
      if (group == null ||
          group.epoch != epoch ||
          !group.members.contains(packet.senderId)) {
        await _store.remove(packet.id);
        _emitState(
          packet.id,
          MessageState.failed,
          StateError('group membership changed before delivery'),
        );
        return false;
      }
    }
    if (packet.isExpired(_clock())) {
      await _store.remove(packet.id);
      if (packet.type == ChatPacketType.message ||
          packet.type == ChatPacketType.groupMessage) {
        _emitState(
          packet.id,
          MessageState.failed,
          StateError('message expired'),
        );
      }
      return false;
    }
    _acknowledgedPacketIds.removeWhere(
      (_, expiry) => !expiry.isAfter(_clock()),
    );
    if (_acknowledgedPacketIds.containsKey(packet.id)) return true;
    if (emitSending &&
        (packet.type == ChatPacketType.message ||
            packet.type == ChatPacketType.groupMessage)) {
      _emitState(packet.id, MessageState.sending);
    }
    var deliveredRoutes = 0;
    for (final transport in _transports.where((item) => item.available)) {
      try {
        final result = await transport.send(packet);
        deliveredRoutes += result.deliveredRoutes;
      } on Object catch (error) {
        _errors.add(error);
      }
    }
    if (_acknowledgedPacketIds.containsKey(packet.id)) return true;
    final requiresAck =
        packet.destination.startsWith('p:') &&
        (packet.type == ChatPacketType.message ||
            packet.type == ChatPacketType.groupKeyUpdate);
    if (deliveredRoutes > 0 && !requiresAck) {
      await _store.remove(packet.id);
      if (packet.type == ChatPacketType.message ||
          packet.type == ChatPacketType.groupMessage) {
        _emitState(packet.id, MessageState.sent);
      }
      return true;
    }
    try {
      await _store.enqueue(packet);
      if (_acknowledgedPacketIds.containsKey(packet.id)) {
        await _store.remove(packet.id);
        return true;
      }
      if (packet.type == ChatPacketType.message ||
          packet.type == ChatPacketType.groupMessage) {
        _emitState(
          packet.id,
          deliveredRoutes > 0 ? MessageState.sent : MessageState.queued,
        );
      }
      if (deliveredRoutes > 0) _scheduleRetry();
    } on Object catch (error) {
      // A full or unwritable store must produce an honest failure rather than
      // a message the user believes is still on its way.
      _errors.add(error);
      if (packet.type == ChatPacketType.message ||
          packet.type == ChatPacketType.groupMessage) {
        _emitState(packet.id, MessageState.failed, error);
      }
    }
    return deliveredRoutes > 0;
  }

  void _enqueueInbound(
    ReceivedChatPacket received, {
    bool replayGroup = false,
  }) {
    if (!_initialized || _pendingInbound >= maximumPendingInbound) return;
    _pendingInbound++;
    _inboundWork = _inboundWork
        .then((_) => _onPacket(received, replayGroup: replayGroup))
        .catchError((Object error) {
          if (!_errors.isClosed) _errors.add(error);
        })
        .whenComplete(() => _pendingInbound--);
  }

  Future<void> _onPacket(
    ReceivedChatPacket received, {
    bool replayGroup = false,
  }) async {
    var packet = received.packet;
    final identity = _requireIdentity();
    final now = _clock();
    if (packet.isExpired(now)) return;

    final keyed = security;
    final directForUsEarly = packet.destination == 'p:${identity.peerId}';
    if (keyed != null) {
      try {
        if (directForUsEarly) {
          // Addressed to us, so open it as well as authenticate it.
          packet = (await keyed.admit(
            packet,
            announcedKeys: received.senderKeys,
          )).packet;
        } else {
          // Only passing through. Prove it is genuine so a forgery cannot be
          // relayed, but leave the payload sealed.
          final keys =
              packet.senderKeys ??
              received.senderKeys ??
              keyed.trustStore.keysFor(packet.senderId);
          if (keys == null ||
              !await keyed.verifyForRelay(packet, senderKeys: keys)) {
            throw const MessageSecurityException('unverified packet');
          }
        }
      } on MessageSecurityException catch (error) {
        _errors.add(error);
        return;
      }
    }

    final directForUs = packet.destination == 'p:${identity.peerId}';
    Uint8List? groupPlaintext;
    if (packet.type == ChatPacketType.groupMessage) {
      if (security == null ||
          packet.isSealed ||
          !packet.destination.startsWith('g:')) {
        return;
      }
      final group = _groups[packet.destination.substring(2)];
      if (group == null) {
        _holdGroupPacket(received);
      } else if (group.members.contains(identity.peerId) &&
          group.members.contains(packet.senderId)) {
        try {
          groupPlaintext = await _groupCipher.decrypt(packet, group);
        } on MessageSecurityException catch (error) {
          if (error.reason == 'group epoch unavailable' &&
              packet.payload.length >= 4 &&
              ByteData.sublistView(packet.payload).getUint32(0) > group.epoch) {
            _holdGroupPacket(received);
          } else {
            _errors.add(error);
          }
        }
      }
      // A device without the group key still forwards the signed ciphertext.
    }
    if (packet.type == ChatPacketType.groupKeyUpdate && directForUs) {
      try {
        await _acceptGroupUpdate(packet, identity.peerId);
      } on Object catch (error) {
        _errors.add(error);
        return;
      }
    }

    // Reserve only authenticated IDs. This synchronous check also rejects
    // concurrent duplicates whose signature verification finished together.
    if (!replayGroup) {
      if (await _store.hasSeen(packet.id)) {
        // The previous ACK may have been lost. A source retries a direct
        // packet until the recipient confirms it, even across a restart.
        if (directForUs &&
            (packet.type == ChatPacketType.message ||
                packet.type == ChatPacketType.groupKeyUpdate)) {
          await _sendAcknowledgement(packet, received);
        }
        return;
      }
      if (!_dedupe.remember(packet.id, packet.expiresAt)) return;
      await _store.rememberSeen(packet.id, packet.expiresAt);
    }

    final channelPacket = packet.destination.startsWith('c:');
    if (packet.type == ChatPacketType.acknowledgement && directForUs) {
      final acknowledgedId = utf8.decode(packet.payload, allowMalformed: true);
      if (_recipientByPacketId[acknowledgedId] != packet.senderId) {
        _errors.add(
          const MessageSecurityException('unexpected acknowledgement'),
        );
        return;
      }
      final messageId = _messageIdByPacketId[acknowledgedId] ?? acknowledgedId;
      _acknowledgedPacketIds.removeWhere(
        (_, expiry) => !expiry.isAfter(_clock()),
      );
      while (_acknowledgedPacketIds.length >= 4096) {
        _acknowledgedPacketIds.remove(_acknowledgedPacketIds.keys.first);
      }
      _acknowledgedPacketIds[acknowledgedId] = packet.expiresAt;
      await _store.remove(acknowledgedId);
      _recipientByPacketId.remove(acknowledgedId);
      if (_messageIdByPacketId.containsKey(acknowledgedId) ||
          _restoredMessageIds.contains(acknowledgedId)) {
        _emitState(messageId, MessageState.delivered);
      }
      return;
    }

    if (packet.type == ChatPacketType.groupKeyUpdate && directForUs) {
      await _sendAcknowledgement(packet, received);
    }

    if ((packet.type == ChatPacketType.message &&
            (directForUs || channelPacket)) ||
        (packet.type == ChatPacketType.groupMessage &&
            groupPlaintext != null)) {
      try {
        final message = ChatMessage(
          id: packet.id,
          conversationId: packet.destination.substring(2),
          // A direct packet is addressed to us, so the remote participant
          // is the sender rather than the destination.
          threadId: directForUs
              ? packet.senderId
              : packet.destination.substring(2),
          isDirect: directForUs,
          senderId: packet.senderId,
          text: utf8.decode(groupPlaintext ?? packet.payload),
          createdAt: packet.createdAt,
          isLocal: false,
        );
        _messages.add(message);
        await _persist(message);
      } on FormatException catch (error) {
        _errors.add(error);
        return;
      }
      if (directForUs) {
        await _sendAcknowledgement(packet, received);
      }
    }

    final shouldRelay = packet.ttl > 1 && !directForUs && !replayGroup;
    if (shouldRelay) {
      _relayCache.removeWhere((_, item) => item.packet.isExpired(_clock()));
      if (_relayCache.length >= 256) {
        _relayCache.remove(_relayCache.keys.first);
      }
      _relayCache[packet.id] = received;
      await _relay(received);
    }
  }

  Future<void> _relay(ReceivedChatPacket received) async {
    final packet = received.packet;
    if (packet.isExpired(_clock()) || packet.ttl <= 1) return;
    final previous = _lastRelayAt;
    if (previous != null) {
      final wait = minimumRelaySpacing - _clock().difference(previous);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
    }
    _lastRelayAt = _clock();
    final jitterMs = maximumRelayJitter.inMilliseconds == 0
        ? 0
        : _random.nextInt(maximumRelayJitter.inMilliseconds + 1);
    if (jitterMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: jitterMs));
    }
    final forwarded = packet.withTtl(packet.ttl - 1);
    for (final transport in _transports.where((item) => item.available)) {
      try {
        await transport.send(
          forwarded,
          excludeRouteId: transport.id == received.transportId
              ? received.routeId
              : null,
        );
      } on Object catch (error) {
        _errors.add(error);
      }
    }
  }

  Future<void> _sendAcknowledgement(
    ChatPacket original,
    ReceivedChatPacket received,
  ) async {
    final now = _clock();
    _lastAcknowledgementAt.removeWhere(
      (_, time) => now.difference(time) >= const Duration(seconds: 2),
    );
    if (_lastAcknowledgementAt.containsKey(original.id)) return;
    while (_lastAcknowledgementAt.length >= 4096) {
      _lastAcknowledgementAt.remove(_lastAcknowledgementAt.keys.first);
    }
    _lastAcknowledgementAt[original.id] = now;
    final identity = _requireIdentity();
    var acknowledgement = ChatPacket(
      type: ChatPacketType.acknowledgement,
      packetId: createPacketId(_random),
      senderId: identity.peerId,
      destination: 'p:${original.senderId}',
      ttl: defaultTtl,
      createdAt: now,
      expiresAt: original.expiresAt,
      payload: utf8.encode(original.id),
    );
    final keyed = security;
    if (keyed != null) {
      // Signed, so `delivered` means the recipient confirmed it rather than
      // any device on the path having claimed so.
      acknowledgement = await keyed.protect(acknowledgement, encrypt: false);
    }
    _dedupe.remember(acknowledgement.id, acknowledgement.expiresAt);
    final arrivalTransport = _transports
        .where((transport) => transport.id == received.transportId)
        .firstOrNull;
    if (arrivalTransport != null && arrivalTransport.available) {
      final result = await arrivalTransport.send(
        acknowledgement,
        routeId: received.routeId,
      );
      if (result.sent) return;
    }
    await _attemptSend(acknowledgement);
  }

  Future<void> _expireQueued() async {
    for (final packet in await _store.expiredQueued()) {
      await _store.remove(packet.id);
      if (packet.type == ChatPacketType.message ||
          packet.type == ChatPacketType.groupMessage) {
        _emitState(
          packet.id,
          MessageState.failed,
          StateError('message expired'),
        );
      }
    }
  }

  Future<void> _flushQueue() async {
    if (_flushing || !_initialized) return;
    _flushing = true;
    try {
      await _expireQueued();
      final queued = await _store.queued();
      var failed = 0;
      for (final packet in queued) {
        if (!await _attemptSend(packet, emitSending: true)) failed++;
        // Space out a backlog so draining it is not a broadcast burst that
        // every neighbour has to absorb at once.
        if (queued.length > 1 && retrySpacing > Duration.zero) {
          await Future<void>.delayed(retrySpacing);
        }
      }
      if (failed == 0) {
        _flushFailures = 0;
        if ((await _store.queued()).isNotEmpty) _scheduleRetry();
      } else {
        _flushFailures++;
        _scheduleRetry();
      }
    } finally {
      _flushing = false;
    }
  }

  /// Retries on a capped exponential backoff.
  ///
  /// Availability changes already trigger a flush; this covers the case where
  /// the transport claims to be available but sends keep failing, which would
  /// otherwise spin.
  void _scheduleRetry() {
    if (_retryTimer?.isActive ?? false) return;
    final exponent = _flushFailures.clamp(1, 6);
    final delay = Duration(
      milliseconds: (retryBackoff.inMilliseconds * (1 << (exponent - 1))).clamp(
        0,
        maximumRetryBackoff.inMilliseconds,
      ),
    );
    _retryTimer = Timer(delay, () {
      if (_initialized) unawaited(_flushQueue());
    });
  }

  void _updatePeers(String transportId, List<ChatPeer> peers) {
    final oldPeers = _knownPeers.values
        .where((peer) => peer.transportId == transportId)
        .map((peer) => peer.id)
        .toSet();
    _knownPeers.removeWhere((_, peer) => peer.transportId == transportId);
    for (final peer in peers) {
      _knownPeers['$transportId:${peer.id}'] = peer;
    }
    _peers.add(List.unmodifiable(_knownPeers.values));
    final joined = peers.any((peer) => !oldPeers.contains(peer.id));
    if (joined && _relayCache.isNotEmpty) {
      _relayCache.removeWhere((_, item) => item.packet.isExpired(_clock()));
      for (final received in _relayCache.values.toList()) {
        _enqueueRelayReplay(received);
      }
    }
  }

  void _enqueueRelayReplay(ReceivedChatPacket received) {
    if (!_initialized || _pendingInbound >= maximumPendingInbound) return;
    _pendingInbound++;
    _inboundWork = _inboundWork
        .then((_) => _relay(received))
        .catchError((Object error) {
          if (!_errors.isClosed) _errors.add(error);
        })
        .whenComplete(() => _pendingInbound--);
  }

  void _emitState(String messageId, MessageState state, [Object? error]) {
    if (_deliveredMessageIds.contains(messageId)) return;
    if (state == MessageState.delivered) _deliveredMessageIds.add(messageId);
    _states.add(
      MessageStateChange(messageId: messageId, state: state, error: error),
    );
    unawaited(_store.saveState(messageId, state).catchError(_errors.add));
  }

  /// Writes a message to durable history, skipping ones we just replayed.
  Future<void> _persist(ChatMessage message) async {
    if (_restoredMessageIds.contains(message.id)) return;
    try {
      await _store.saveMessage(message);
    } on Object catch (error) {
      _errors.add(error);
    }
  }

  /// Records a packet id durably so a replay after restart is still a
  /// duplicate rather than a second copy on screen.
  Future<void> _remember(ChatPacket packet) async {
    await _store.rememberSeen(packet.id, packet.expiresAt);
  }

  ChatIdentity _requireIdentity() {
    final identity = _identity;
    if (!_initialized || identity == null) {
      throw StateError('BleMeshChat has not been initialized');
    }
    return identity;
  }

  Future<void> dispose() async {
    _retryTimer?.cancel();
    _retryTimer = null;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    await _inboundWork;
    _initialized = false;
    await _store.close();
    for (final transport in _transports) {
      await transport.stop();
      if (transport is BleChatTransport) await transport.dispose();
    }
    await _messages.close();
    await _peers.close();
    await _groupChanges.close();
    await _states.close();
    await _errors.close();
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
