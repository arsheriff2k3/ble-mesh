import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'ble_chat_transport.dart';
import 'bridge_policy.dart';
import 'chat_models.dart';
import 'chat_transport.dart';
import 'crypto/chat_keys.dart';
import 'crypto/group_crypto.dart';
import 'crypto/message_cipher.dart';
import 'crypto/packet_security.dart';
import 'crypto/trust_store.dart';
import 'inbound_policy.dart';
import 'message_store.dart';

/// High-level offline mesh chat facade.
class BleMeshChat {
  /// Creates a chat facade. Nothing starts until [initialize].
  ///
  /// [store] defaults to an [InMemoryMessageStore] and [groupStore] to an
  /// [InMemoryGroupStore], so history and group keys are lost on exit unless
  /// durable stores are passed. [perSenderLimit] budgets each authenticated
  /// sender and [perRouteLimit] each arrival route (a BLE link or a relay).
  /// The bridge arguments are initial values for the getters of the same
  /// name; both default to off. [clock] and [random] exist for tests;
  /// [random] defaults to [Random.secure]. [messageLifetime] must not exceed
  /// [maximumPacketLifetime].
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
    this.redundantDelivery = false,
    this.maximumPacketLifetime = const Duration(hours: 24),
    this.maximumClockSkew = const Duration(minutes: 10),
    InboundRateLimit perSenderLimit = const InboundRateLimit(
      burst: 100,
      perSecond: 2,
    ),
    InboundRateLimit perRouteLimit = const InboundRateLimit(
      burst: 400,
      perSecond: 20,
    ),
    this.contactsOnlyTransports = const {'nostr'},
    bool bridgeConsent = false,
    BridgePolicy? bridgePolicy,
    this.bridgeRegistrationInterval = const Duration(minutes: 4),
  }) : assert(messageLifetime <= maximumPacketLifetime),
       // Mutable after construction, so not initializing formals.
       // ignore: prefer_initializing_formals
       _bridgeConsent = bridgeConsent,
       // ignore: prefer_initializing_formals
       _bridgePolicy = bridgePolicy,
       _bridgeBucket = _bridgeBucketFor(bridgePolicy, clock),
       _senderBuckets = TokenBuckets(perSenderLimit, clock: clock),
       _routeBuckets = TokenBuckets(perRouteLimit, clock: clock),
       _store = store ?? InMemoryMessageStore(),
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

  /// Hop budget given to packets this device creates. Each relay decrements
  /// it, and a packet whose TTL is 1 is not relayed further. Defaults to 5.
  final int defaultTtl;

  /// How long a packet this device creates stays deliverable. Queued
  /// messages still undelivered after this are marked
  /// [MessageState.failed], and peers drop them. Defaults to one hour.
  final Duration messageLifetime;

  /// Upper bound of the random delay added before relaying a packet, so
  /// neighbours that heard the same packet do not all transmit at once.
  /// [Duration.zero] disables it. Defaults to 250 ms.
  final Duration maximumRelayJitter;

  /// Least time between the starts of two consecutive relays. Defaults to
  /// 50 ms.
  final Duration minimumRelaySpacing;

  /// Most inbound packets and relay replays waiting to be processed. Packets
  /// arriving while the queue is full are dropped without an error. Defaults
  /// to 256.
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

  /// Sends direct packets over every available transport at once instead of
  /// preferring one on which the recipient is currently known.
  final bool redundantDelivery;

  /// Longest `expiresAt - createdAt` accepted from another device.
  ///
  /// Packet ids are retained for replay protection until the packet
  /// expires. Without a cap, signed packets claiming to expire in decades
  /// fill that store permanently and every new packet is refused.
  final Duration maximumPacketLifetime;

  /// How far in the future another device's `createdAt` may be.
  final Duration maximumClockSkew;

  /// Transports that accept packets only from senders whose key is already
  /// pinned. Nostr is included by default: anyone on the internet who learns
  /// a peer id can reach it there, and fresh identities cost nothing.
  final Set<String> contactsOnlyTransports;

  /// Budgets per authenticated sender, and per arrival route (a BLE link or
  /// a relay). The route budget also bounds swarms of fresh identities.
  final TokenBuckets _senderBuckets;
  final TokenBuckets _routeBuckets;
  final Map<String, DateTime> _lastLimitReport = {};

  /// How often a consenting offline device asks nearby gateways to receive
  /// its online traffic. Each registration lasts [_registrationLifetime].
  final Duration bridgeRegistrationInterval;
  static const _registrationLifetime = Duration(minutes: 10);
  static const _maximumRegistrationLifetime = Duration(minutes: 15);

  bool _bridgeConsent;
  BridgePolicy? _bridgePolicy;
  NetworkConditions? _network;
  TokenBuckets _bridgeBucket;

  /// Registered offline devices, by peer id, and when each registration ends.
  final Map<String, DateTime> _bridgeRoutes = {};

  /// Packets this device has carried across, so each crosses here once.
  final Map<String, DateTime> _bridgedPacketIds = {};
  int _bridgedPacketCount = 0;
  DateTime? _lastRegistrationAt;
  Timer? _bridgeTimer;
  BridgeStatus? _lastBridgeStatus;
  final _bridgeStatus = StreamController<BridgeStatus>.broadcast();

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

  /// Direct packets a route accepted but the recipient has not acknowledged.
  final Set<String> _unacknowledgedPacketIds = {};

  /// Consecutive failed flushes, used to space out retries.
  int _flushFailures = 0;
  Timer? _retryTimer;
  List<ChatTransport> _transports = const [];
  ChatIdentity? _identity;
  bool _initialized = false;
  bool _flushing = false;

  /// Messages sent by this device, messages received for it, and, during
  /// [initialize], history replayed from the store. Broadcast.
  ///
  /// History is emitted before any transport starts; subscribe before
  /// calling [initialize] to receive it. Each received packet id is emitted
  /// at most once.
  Stream<ChatMessage> get messages => _messages.stream;

  /// Every peer currently listed by any transport, emitted whenever a
  /// transport reports a change. Broadcast. A peer reachable over several
  /// transports appears once per transport.
  Stream<List<ChatPeer>> get peers => _peers.stream;

  /// Every known group, emitted after a group is created, its membership
  /// changes, or a newer key update is accepted. Broadcast.
  Stream<List<ChatGroup>> get groupChanges => _groupChanges.stream;

  /// Delivery state changes for this device's messages, plus states replayed
  /// from the store during [initialize]. Broadcast.
  ///
  /// Nothing more is emitted for a message after [MessageState.delivered].
  Stream<MessageStateChange> get messageStates => _states.stream;

  /// Non-fatal failures: transport and store errors, rejected or
  /// unauthenticated packets, unknown senders on contacts-only transports,
  /// and exhausted rate limits (reported at most once a minute per budget).
  /// Broadcast. Processing continues after every error.
  Stream<Object> get errors => _errors.stream;

  /// Whether [initialize] has been called and [dispose] has not.
  bool get isInitialized => _initialized;

  /// Whether packets this device creates may be carried between BLE and
  /// Nostr by gateways. Covers new direct messages and acknowledgements;
  /// packets already sent keep the choice they were signed with.
  bool get bridgeConsent => _bridgeConsent;

  /// This device's gateway policy, or null when it is not a gateway.
  BridgePolicy? get bridgePolicy => _bridgePolicy;

  /// Whether this device is bridging now, and why not when it is not.
  BridgeStatus get bridgeStatus => _computeBridgeStatus();

  /// Emits [bridgeStatus] whenever it differs from the last value emitted.
  /// Broadcast.
  Stream<BridgeStatus> get bridgeStatusChanges => _bridgeStatus.stream;

  /// Records the user's choice about letting gateways carry this device's
  /// packets. Turning it on while offline registers with nearby gateways.
  void setBridgeConsent(bool allow) {
    _bridgeConsent = allow;
    if (allow) unawaited(_sendRegistration(force: true));
  }

  /// Makes this device a gateway under [policy], or stops bridging when
  /// null. Should follow an explicit choice by this device's user.
  void setBridgePolicy(BridgePolicy? policy) {
    _bridgePolicy = policy;
    _bridgeBucket = _bridgeBucketFor(policy, _clock);
    if (policy == null || !policy.nostrToBle) _bridgeRoutes.clear();
    _refreshBridge();
  }

  /// Reports the current connection so the policy's metered and roaming
  /// rules can be applied. The plugin cannot observe these itself.
  void updateNetworkConditions(NetworkConditions conditions) {
    _network = conditions;
    _refreshBridge();
  }

  static TokenBuckets _bridgeBucketFor(
    BridgePolicy? policy,
    DateTime Function()? clock,
  ) {
    final perMinute = policy?.maximumPacketsPerMinute ?? 1;
    return TokenBuckets(
      InboundRateLimit(burst: perMinute, perSecond: perMinute / 60),
      maximumKeys: 1,
      clock: clock,
    );
  }

  /// Groups this device holds a key for, by group id. Unmodifiable snapshot.
  Map<String, ChatGroup> get groups => Map.unmodifiable(_groups);

  /// Opens the stores, replays history, starts [transports], and sends any
  /// queued packets that have a route.
  ///
  /// Expired queued messages are marked [MessageState.failed]. A transport
  /// that fails to start is reported on [errors] and does not abort the
  /// call. Throws [StateError] when already initialized, and
  /// [ArgumentError] when [transports] is empty or [identity] does not match
  /// [security]'s signing identity.
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
          _refreshBridge();
          if (available && transport is! RelayChatTransport) {
            unawaited(_sendRegistration());
          }
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
    _bridgeTimer = Timer.periodic(bridgeRegistrationInterval, (_) {
      _refreshBridge();
      unawaited(_sendRegistration());
    });
    _refreshBridge();
    await _sendRegistration();
    await _flushQueue();
  }

  /// Sends [text] to the public channel [conversationId].
  ///
  /// With [security] the packet is signed but readable by anyone on the
  /// mesh; use [sendGroup] for confidential group chat. The message is
  /// emitted on [messages] before transmission is attempted, and the
  /// returned future completes after the first attempt; follow
  /// [messageStates] for progress. A packet no route accepted is queued and
  /// retried until [messageLifetime] elapses; if the store refuses it, the
  /// message is marked [MessageState.failed]. Throws [ArgumentError] when
  /// [text] is empty, [StateError] before [initialize], and
  /// [SeenPacketQuotaException] when the store's replay index is full.
  Future<ChatMessage> send({
    required String conversationId,
    required String text,
  }) => _sendMessage(destination: 'c:$conversationId', text: text);

  /// Sends [text] to the peer [peerId].
  ///
  /// With [security] the packet is sealed to the recipient's key, and
  /// [MessageSecurityException] is thrown when that key is unknown or has
  /// changed without approval. The message stays queued for retry until the
  /// recipient acknowledges it ([MessageState.delivered]) or
  /// [messageLifetime] elapses. Otherwise behaves like [send].
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

  /// Encrypts [text] under the current key of group [groupId] and sends it.
  ///
  /// Throws [StateError] when [security] is absent, the group is unknown, or
  /// this device is not a member, and [ArgumentError] when [text] is empty.
  /// A queued message is marked [MessageState.failed] if the group's epoch
  /// or membership changes before a route accepts it.
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
      bridgeable: isDirect && _bridgeConsent,
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
    final (primary, fallback) = _routesFor(packet);
    for (final transports in [primary, fallback]) {
      // The fallback runs only when every preferred transport came up
      // empty, for example a BLE listing that outlived its links.
      if (deliveredRoutes > 0) break;
      for (final transport in transports) {
        try {
          final result = await transport.send(packet);
          deliveredRoutes += result.deliveredRoutes;
        } on Object catch (error) {
          _errors.add(error);
        }
      }
    }
    if (_acknowledgedPacketIds.containsKey(packet.id)) return true;
    final requiresAck =
        packet.destination.startsWith('p:') &&
        (packet.type == ChatPacketType.message ||
            packet.type == ChatPacketType.groupKeyUpdate);
    if (requiresAck && deliveredRoutes > 0) {
      while (_unacknowledgedPacketIds.length >= 4096) {
        _unacknowledgedPacketIds.remove(_unacknowledgedPacketIds.first);
      }
      _unacknowledgedPacketIds.add(packet.id);
    }
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

  /// Chooses transports for [packet]: a primary set, and a fallback tried
  /// in the same attempt only if the primary set delivers to no route.
  ///
  /// A direct packet goes first over transports on which its recipient is
  /// currently listed, so a nearby peer is reached over BLE without also
  /// publishing to relays. If those deliver nothing, the other available
  /// transports are tried at once. Once a route has accepted the packet and
  /// no acknowledgement came back, retries use every available transport: a
  /// stale nearby listing must not strand a message that another route could
  /// deliver.
  (List<ChatTransport>, List<ChatTransport>) _routesFor(ChatPacket packet) {
    final available = _transports.where((item) => item.available).toList();
    if (redundantDelivery ||
        !packet.destination.startsWith('p:') ||
        _unacknowledgedPacketIds.contains(packet.id)) {
      return (available, const []);
    }
    final peerId = packet.destination.substring(2);
    final preferred = available
        .where((item) => _knownPeers.containsKey('${item.id}:$peerId'))
        .toList();
    if (preferred.isEmpty) return (available, const []);
    return (
      preferred,
      available.where((item) => !preferred.contains(item)).toList(),
    );
  }

  void _enqueueInbound(
    ReceivedChatPacket received, {
    bool replayGroup = false,
  }) {
    if (!_initialized || _pendingInbound >= maximumPendingInbound) return;
    // Spend the route budget before any signature work, so a neighbour
    // cannot make us burn CPU faster than it is allowed to send.
    if (!replayGroup &&
        !_withinBudget(
          _routeBuckets,
          'route:${received.transportId}:${received.routeId}',
        )) {
      return;
    }
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
    if (!replayGroup && !_plausibleLifetime(packet, now)) {
      _errors.add(
        const MessageSecurityException('implausible packet lifetime'),
      );
      return;
    }

    final keyed = security;
    final directForUsEarly = packet.destination == 'p:${identity.peerId}';
    final arrivedOnline = _isOnline(received.transportId);
    if (arrivedOnline && !directForUsEarly && !_mayBridgeToLocal(packet)) {
      // Relays only deliver others' traffic to a gateway, and only for
      // devices that registered with it.
      return;
    }
    // A bridgeable packet may have crossed from the internet, so one
    // addressed to us is held to the strictest contact policy in use.
    final contactsOnly =
        (contactsOnlyTransports.contains(received.transportId) &&
            !(arrivedOnline && !directForUsEarly)) ||
        (packet.bridgeable &&
            directForUsEarly &&
            contactsOnlyTransports.isNotEmpty);
    if (keyed != null) {
      if (contactsOnly &&
          packet.senderId != identity.peerId &&
          keyed.trustStore.keysFor(packet.senderId) == null) {
        // Checked before admit(), which would otherwise pin the stranger on
        // first contact. No ACK is sent, so probing learns nothing.
        _errors.add(
          UnknownSenderException(packet.senderId, received.transportId),
        );
        return;
      }
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
        // An origin retrying through a gateway that failed to publish the
        // first copy gets another chance here; a packet already carried
        // across is not carried again.
        if (!directForUs) await _maybeBridge(received, packet);
        return;
      }
      // Charged after authentication, so the id cannot be forged to spend
      // someone else's budget, and before the id is reserved, so a dropped
      // packet can still be delivered when its sender retries.
      if (!_withinBudget(_senderBuckets, 'sender:${packet.senderId}')) return;
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
      _unacknowledgedPacketIds.remove(acknowledgedId);
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

    if (packet.type == ChatPacketType.bridgeRegistration && !replayGroup) {
      _onRegistration(received, packet);
    }

    // Relays are not a mesh: nothing that arrived online is flooded back.
    final shouldRelay =
        packet.ttl > 1 && !directForUs && !replayGroup && !arrivedOnline;
    if (shouldRelay) {
      _relayCache.removeWhere((_, item) => item.packet.isExpired(_clock()));
      if (_relayCache.length >= 256) {
        _relayCache.remove(_relayCache.keys.first);
      }
      _relayCache[packet.id] = received;
      await _relay(received);
    }
    if (!directForUs && !replayGroup) await _maybeBridge(received, packet);
  }

  bool _isOnline(String transportId) => _transports.any(
    (transport) =>
        transport.id == transportId && transport is RelayChatTransport,
  );

  Iterable<RelayChatTransport> get _onlineTransports =>
      _transports.whereType<RelayChatTransport>();

  Iterable<ChatTransport> get _localTransports =>
      _transports.where((transport) => transport is! RelayChatTransport);

  /// Whether a packet that arrived online, not addressed to us, is one this
  /// gateway should carry onto BLE.
  bool _mayBridgeToLocal(ChatPacket packet) {
    final policy = _bridgePolicy;
    if (policy == null || !policy.nostrToBle || !packet.bridgeable) {
      return false;
    }
    if (!packet.destination.startsWith('p:')) return false;
    final expiry = _bridgeRoutes[packet.destination.substring(2)];
    return expiry != null && expiry.isAfter(_clock());
  }

  static bool _bridgedType(ChatPacketType type) =>
      type == ChatPacketType.message || type == ChatPacketType.acknowledgement;

  /// Carries [packet] between BLE and Nostr when every condition holds: the
  /// origin consented, this device is an active gateway, the packet is a
  /// live direct message or acknowledgement with hops left, it has not
  /// crossed here before, and the bridge budget allows it.
  ///
  /// Crossing costs a hop and packet ids never change, so a packet that
  /// meets several gateways is deduplicated everywhere and stops within
  /// its TTL and expiry.
  Future<void> _maybeBridge(
    ReceivedChatPacket received,
    ChatPacket packet,
  ) async {
    final policy = _bridgePolicy;
    if (policy == null ||
        !packet.bridgeable ||
        !_bridgedType(packet.type) ||
        packet.ttl <= 1 ||
        !packet.destination.startsWith('p:') ||
        packet.senderId == _identity?.peerId ||
        _bridgeInactiveReason() != null) {
      return;
    }
    final now = _clock();
    if (packet.isExpired(now)) return;
    _bridgedPacketIds.removeWhere((_, expiry) => !expiry.isAfter(now));
    if (_bridgedPacketIds.containsKey(packet.id)) return;
    final recipient = packet.destination.substring(2);
    final forwarded = packet.withTtl(packet.ttl - 1);
    var delivered = 0;
    if (_isOnline(received.transportId)) {
      if (!_mayBridgeToLocal(packet)) return;
      if (!_withinBudget(_bridgeBucket, 'bridge')) return;
      for (final transport in _localTransports.where(
        (item) => item.available,
      )) {
        try {
          delivered += (await transport.send(forwarded)).deliveredRoutes;
        } on Object catch (error) {
          _errors.add(error);
        }
      }
    } else {
      if (!policy.bleToNostr) return;
      // A recipient listed on a local transport is already reachable there.
      if (_knownPeers.values.any(
        (peer) => peer.id == recipient && !_isOnline(peer.transportId),
      )) {
        return;
      }
      if (!_withinBudget(_bridgeBucket, 'bridge')) return;
      for (final online in _onlineTransports.where((item) => item.available)) {
        try {
          delivered += (await online.bridge(forwarded)).deliveredRoutes;
        } on Object catch (error) {
          _errors.add(error);
        }
      }
    }
    if (delivered == 0) return;
    while (_bridgedPacketIds.length >= 4096) {
      _bridgedPacketIds.remove(_bridgedPacketIds.keys.first);
    }
    _bridgedPacketIds[packet.id] = packet.expiresAt;
    _bridgedPacketCount++;
    _publishBridgeStatus();
  }

  /// Records a nearby device's request to receive its online traffic here.
  void _onRegistration(ReceivedChatPacket received, ChatPacket packet) {
    final policy = _bridgePolicy;
    if (policy == null ||
        !policy.nostrToBle ||
        security == null ||
        _isOnline(received.transportId) ||
        !packet.bridgeable ||
        packet.isSealed ||
        packet.destination != '*' ||
        packet.senderId == _identity?.peerId ||
        packet.expiresAt.difference(packet.createdAt) >
            _maximumRegistrationLifetime) {
      return;
    }
    final now = _clock();
    _bridgeRoutes.removeWhere((_, expiry) => !expiry.isAfter(now));
    if (!_bridgeRoutes.containsKey(packet.senderId) &&
        _bridgeRoutes.length >= policy.maximumRoutes) {
      return;
    }
    _bridgeRoutes[packet.senderId] = packet.expiresAt;
    _refreshBridge();
  }

  /// Asks nearby gateways to receive this device's online traffic.
  ///
  /// Sent only with consent, only while no relay is reachable directly, and
  /// only over local transports. A device that is online itself does not
  /// need a gateway and should not reveal its presence to one.
  Future<void> _sendRegistration({bool force = false}) async {
    final keyed = security;
    final identity = _identity;
    if (!_initialized || !_bridgeConsent || keyed == null || identity == null) {
      return;
    }
    if (_onlineTransports.any((item) => item.available)) return;
    final locals = _localTransports.where((item) => item.available).toList();
    if (locals.isEmpty) return;
    final now = _clock();
    final last = _lastRegistrationAt;
    if (!force &&
        last != null &&
        now.difference(last) < bridgeRegistrationInterval ~/ 8) {
      return;
    }
    _lastRegistrationAt = now;
    final packet = await keyed.protect(
      ChatPacket(
        type: ChatPacketType.bridgeRegistration,
        packetId: createPacketId(_random),
        senderId: identity.peerId,
        destination: '*',
        ttl: 3,
        createdAt: now,
        expiresAt: now.add(_registrationLifetime),
        payload: Uint8List(0),
        bridgeable: true,
      ),
      encrypt: false,
    );
    _dedupe.remember(packet.id, packet.expiresAt);
    for (final transport in locals) {
      try {
        await transport.send(packet);
      } on Object catch (error) {
        _errors.add(error);
      }
    }
  }

  BridgeInactiveReason? _bridgeInactiveReason() {
    final policy = _bridgePolicy;
    if (policy == null) return BridgeInactiveReason.disabled;
    if (security == null) return BridgeInactiveReason.requiresSecurity;
    if (!_onlineTransports.any((item) => item.available)) {
      return BridgeInactiveReason.relaysUnavailable;
    }
    if (!policy.allowMetered || !policy.allowRoaming) {
      final network = _network;
      if (network == null) return BridgeInactiveReason.networkConditionsUnknown;
      if (network.metered && !policy.allowMetered) {
        return BridgeInactiveReason.metered;
      }
      if (network.roaming && !policy.allowRoaming) {
        return BridgeInactiveReason.roaming;
      }
    }
    return null;
  }

  BridgeStatus _computeBridgeStatus() {
    final reason = _bridgeInactiveReason();
    final now = _clock();
    return BridgeStatus(
      active: reason == null,
      reason: reason,
      bridgedPeers: reason == null
          ? _bridgeRoutes.values.where((expiry) => expiry.isAfter(now)).length
          : 0,
      bridgedPackets: _bridgedPacketCount,
    );
  }

  /// Aligns relay subscriptions with live registrations and publishes any
  /// status change.
  void _refreshBridge() {
    final now = _clock();
    _bridgeRoutes.removeWhere((_, expiry) => !expiry.isAfter(now));
    final policy = _bridgePolicy;
    final receiving = _bridgeInactiveReason() == null && policy!.nostrToBle
        ? _bridgeRoutes.keys.toSet()
        : const <String>{};
    for (final online in _onlineTransports) {
      online.setBridgedPeers(receiving);
    }
    _publishBridgeStatus();
  }

  void _publishBridgeStatus() {
    final status = _computeBridgeStatus();
    if (status == _lastBridgeStatus || _bridgeStatus.isClosed) return;
    _lastBridgeStatus = status;
    _bridgeStatus.add(status);
  }

  bool _plausibleLifetime(ChatPacket packet, DateTime now) =>
      !packet.createdAt.isAfter(now.add(maximumClockSkew)) &&
      packet.expiresAt.isAfter(packet.createdAt) &&
      packet.expiresAt.difference(packet.createdAt) <= maximumPacketLifetime;

  /// Spends a token, reporting a newly exhausted budget at most once a
  /// minute per key.
  bool _withinBudget(TokenBuckets buckets, String key) {
    if (buckets.take(key)) return true;
    final now = _clock();
    _lastLimitReport.removeWhere(
      (_, at) => now.difference(at) >= const Duration(minutes: 1),
    );
    if (!_lastLimitReport.containsKey(key) && _lastLimitReport.length < 256) {
      _lastLimitReport[key] = now;
      _errors.add(InboundRateLimitedException(key));
    }
    return false;
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
    // Forward only on the transport the packet arrived on. Crossing between
    // BLE and Nostr is bridging, which needs consent and loop prevention.
    for (final transport in _transports.where(
      (item) => item.available && item.id == received.transportId,
    )) {
      try {
        await transport.send(forwarded, excludeRouteId: received.routeId);
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
      // The reply may take the path the original took, but only if this
      // device consents as well.
      bridgeable: original.bridgeable && _bridgeConsent,
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

  /// Stops retries, waits for inbound processing to finish, closes the
  /// message store, stops and disposes the transports, and closes every
  /// stream.
  ///
  /// Do not reuse the instance afterwards: its streams are closed. The group
  /// store is not closed.
  Future<void> dispose() async {
    _retryTimer?.cancel();
    _retryTimer = null;
    _bridgeTimer?.cancel();
    _bridgeTimer = null;
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
      if (transport is RelayChatTransport) await transport.dispose();
    }
    await _messages.close();
    await _peers.close();
    await _groupChanges.close();
    await _states.close();
    await _bridgeStatus.close();
    await _errors.close();
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
