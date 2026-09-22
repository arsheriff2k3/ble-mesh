import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'ble_chat_transport.dart';
import 'chat_models.dart';
import 'chat_transport.dart';
import 'message_store.dart';

/// High-level offline mesh chat facade.
class BleMeshChat {
  BleMeshChat({
    MessageStore? store,
    DedupeCache? dedupeCache,
    DateTime Function()? clock,
    Random? random,
    this.defaultTtl = 5,
    this.messageLifetime = const Duration(hours: 1),
    this.maximumRelayJitter = const Duration(milliseconds: 250),
    this.retryBackoff = const Duration(seconds: 2),
    this.maximumRetryBackoff = const Duration(minutes: 2),
    this.retrySpacing = Duration.zero,
  }) : _store = store ?? InMemoryMessageStore(),
       _clock = clock ?? DateTime.now,
       _random = random ?? Random.secure(),
       _dedupe = dedupeCache ?? DedupeCache(clock: clock);

  final MessageStore _store;
  final DedupeCache _dedupe;
  final DateTime Function() _clock;
  final Random _random;
  final int defaultTtl;
  final Duration messageLifetime;
  final Duration maximumRelayJitter;

  /// First retry delay after a failed flush; doubles per consecutive failure.
  final Duration retryBackoff;

  /// Ceiling for [retryBackoff] growth.
  final Duration maximumRetryBackoff;

  /// Pause between packets while draining a backlog.
  final Duration retrySpacing;

  final _messages = StreamController<ChatMessage>.broadcast();
  final _peers = StreamController<List<ChatPeer>>.broadcast();
  final _states = StreamController<MessageStateChange>.broadcast();
  final _errors = StreamController<Object>.broadcast();
  final _subscriptions = <StreamSubscription<void>>[];
  final Map<String, ChatPeer> _knownPeers = {};
  final Map<String, String> _messageIdByPacketId = {};

  /// Messages replayed from the store, so restoring does not rewrite them.
  final Set<String> _restoredMessageIds = {};

  /// Consecutive failed flushes, used to space out retries.
  int _flushFailures = 0;
  Timer? _retryTimer;
  List<ChatTransport> _transports = const [];
  ChatIdentity? _identity;
  bool _initialized = false;
  bool _flushing = false;

  Stream<ChatMessage> get messages => _messages.stream;
  Stream<List<ChatPeer>> get peers => _peers.stream;
  Stream<MessageStateChange> get messageStates => _states.stream;
  Stream<Object> get errors => _errors.stream;
  bool get isInitialized => _initialized;

  Future<void> initialize({
    required ChatIdentity identity,
    required List<ChatTransport> transports,
  }) async {
    if (_initialized) throw StateError('BleMeshChat is already initialized');
    if (transports.isEmpty) {
      throw ArgumentError('at least one transport is required');
    }
    _initialized = true;
    _identity = identity;
    await _store.open();
    await _restore();
    _transports = List.unmodifiable(transports);
    for (final transport in _transports) {
      _subscriptions.addAll([
        transport.incoming.listen(
          (received) => unawaited(_onPacket(received)),
          onError: _errors.add,
        ),
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

  Future<ChatMessage> _sendMessage({
    required String destination,
    required String text,
  }) async {
    final identity = _requireIdentity();
    if (text.isEmpty) {
      throw ArgumentError.value(text, 'text', 'must not be empty');
    }
    final now = _clock();
    final packet = ChatPacket(
      type: ChatPacketType.message,
      packetId: createPacketId(_random),
      senderId: identity.peerId,
      destination: destination,
      ttl: defaultTtl,
      createdAt: now,
      expiresAt: now.add(messageLifetime),
      payload: utf8.encode(text),
    );
    final message = ChatMessage(
      id: packet.id,
      conversationId: destination.substring(2),
      // We are the sender, so the remote participant is the destination.
      threadId: destination.substring(2),
      isDirect: destination.startsWith('p:'),
      senderId: identity.peerId,
      text: text,
      createdAt: now,
      isLocal: true,
    );
    _messageIdByPacketId[packet.id] = message.id;
    _dedupe.remember(packet.id, packet.expiresAt);
    await _remember(packet);
    _messages.add(message);
    await _persist(message);
    await _attemptSend(packet, emitSending: true);
    return message;
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
        _messages.add(message);
        final state = states[message.id];
        if (state != null) {
          _states.add(
            MessageStateChange(messageId: message.id, state: state),
          );
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
    if (packet.isExpired(_clock())) {
      await _store.remove(packet.id);
      _emitState(packet.id, MessageState.failed, StateError('message expired'));
      return false;
    }
    if (emitSending) _emitState(packet.id, MessageState.sending);
    var deliveredRoutes = 0;
    for (final transport in _transports.where((item) => item.available)) {
      try {
        final result = await transport.send(packet);
        deliveredRoutes += result.deliveredRoutes;
      } on Object catch (error) {
        _errors.add(error);
      }
    }
    if (deliveredRoutes > 0) {
      await _store.remove(packet.id);
      _emitState(packet.id, MessageState.sent);
      return true;
    }
    try {
      await _store.enqueue(packet);
      _emitState(packet.id, MessageState.queued);
    } on Object catch (error) {
      // A full or unwritable store must produce an honest failure rather than
      // a message the user believes is still on its way.
      _errors.add(error);
      _emitState(packet.id, MessageState.failed, error);
    }
    return false;
  }

  Future<void> _onPacket(ReceivedChatPacket received) async {
    final packet = received.packet;
    final identity = _requireIdentity();
    final now = _clock();
    if (packet.isExpired(now) ||
        !_dedupe.remember(packet.id, packet.expiresAt)) {
      return;
    }

    final directForUs = packet.destination == 'p:${identity.peerId}';
    final channelPacket = packet.destination.startsWith('c:');
    if (packet.type == ChatPacketType.acknowledgement && directForUs) {
      final acknowledgedId = utf8.decode(packet.payload, allowMalformed: true);
      final messageId = _messageIdByPacketId[acknowledgedId] ?? acknowledgedId;
      await _store.remove(acknowledgedId);
      _emitState(messageId, MessageState.delivered);
      return;
    }

    await _remember(packet);

    if (packet.type == ChatPacketType.message &&
        (directForUs || channelPacket)) {
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
          text: utf8.decode(packet.payload),
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

    final shouldRelay = packet.ttl > 1 && !directForUs;
    if (shouldRelay) {
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
  }

  Future<void> _sendAcknowledgement(
    ChatPacket original,
    ReceivedChatPacket received,
  ) async {
    final identity = _requireIdentity();
    final now = _clock();
    final acknowledgement = ChatPacket(
      type: ChatPacketType.acknowledgement,
      packetId: createPacketId(_random),
      senderId: identity.peerId,
      destination: 'p:${original.senderId}',
      ttl: defaultTtl,
      createdAt: now,
      expiresAt: original.expiresAt,
      payload: utf8.encode(original.id),
    );
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

  Future<void> _flushQueue() async {
    if (_flushing || !_initialized) return;
    _flushing = true;
    try {
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
      milliseconds: (retryBackoff.inMilliseconds * (1 << (exponent - 1)))
          .clamp(0, maximumRetryBackoff.inMilliseconds),
    );
    _retryTimer = Timer(delay, () {
      if (_initialized) unawaited(_flushQueue());
    });
  }

  void _updatePeers(String transportId, List<ChatPeer> peers) {
    _knownPeers.removeWhere((_, peer) => peer.transportId == transportId);
    for (final peer in peers) {
      _knownPeers['$transportId:${peer.id}'] = peer;
    }
    _peers.add(List.unmodifiable(_knownPeers.values));
  }

  void _emitState(String messageId, MessageState state, [Object? error]) {
    _states.add(
      MessageStateChange(messageId: messageId, state: state, error: error),
    );
    unawaited(
      _store.saveState(messageId, state).catchError(_errors.add),
    );
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
    try {
      await _store.rememberSeen(packet.id, packet.expiresAt);
    } on Object catch (error) {
      _errors.add(error);
    }
  }

  ChatIdentity _requireIdentity() {
    final identity = _identity;
    if (!_initialized || identity == null) {
      throw StateError('BleMeshChat has not been initialized');
    }
    return identity;
  }

  Future<void> dispose() async {
    _initialized = false;
    _retryTimer?.cancel();
    _retryTimer = null;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    await _store.close();
    for (final transport in _transports) {
      await transport.stop();
      if (transport is BleChatTransport) await transport.dispose();
    }
    await _messages.close();
    await _peers.close();
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
