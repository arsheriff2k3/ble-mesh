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

  final _messages = StreamController<ChatMessage>.broadcast();
  final _peers = StreamController<List<ChatPeer>>.broadcast();
  final _states = StreamController<MessageStateChange>.broadcast();
  final _errors = StreamController<Object>.broadcast();
  final _subscriptions = <StreamSubscription<void>>[];
  final Map<String, ChatPeer> _knownPeers = {};
  final Map<String, String> _messageIdByPacketId = {};
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
      senderId: identity.peerId,
      text: text,
      createdAt: now,
      isLocal: true,
    );
    _messageIdByPacketId[packet.id] = message.id;
    _dedupe.remember(packet.id, packet.expiresAt);
    _messages.add(message);
    await _attemptSend(packet, emitSending: true);
    return message;
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
    await _store.enqueue(packet);
    _emitState(packet.id, MessageState.queued);
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

    if (packet.type == ChatPacketType.message &&
        (directForUs || channelPacket)) {
      try {
        _messages.add(
          ChatMessage(
            id: packet.id,
            conversationId: packet.destination.substring(2),
            senderId: packet.senderId,
            text: utf8.decode(packet.payload),
            createdAt: packet.createdAt,
            isLocal: false,
          ),
        );
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
      for (final packet in queued) {
        await _attemptSend(packet, emitSending: true);
      }
    } finally {
      _flushing = false;
    }
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
  }

  ChatIdentity _requireIdentity() {
    final identity = _identity;
    if (!_initialized || identity == null) {
      throw StateError('BleMeshChat has not been initialized');
    }
    return identity;
  }

  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
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
