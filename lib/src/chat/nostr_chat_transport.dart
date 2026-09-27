import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as hashing;

import 'chat_models.dart';
import 'chat_transport.dart';
import 'nostr/nostr_event.dart';
import 'nostr/nostr_socket.dart';
import 'packet_codec.dart';

/// A relay-level problem: a failed connection, a rejected publish, a notice,
/// or an inbound event that failed validation.
class NostrRelayException implements Exception {
  /// Creates an exception for [relay] described by [message].
  const NostrRelayException(this.relay, this.message);

  /// Relay the problem concerns.
  final Uri relay;

  /// Human-readable description. Relay-supplied reasons are included, cut
  /// to 200 characters, so treat this text as untrusted.
  final String message;

  @override
  String toString() => 'NostrRelayException($relay): $message';
}

/// Carries signed chat packets through Nostr relays for online delivery.
///
/// Each packet travels as one NIP-01 event whose content is the base64 wire
/// encoding produced by [ChatPacketCodec]. The packet keeps its own Ed25519
/// signature and, for direct messages, its sealed payload, so relays see
/// authenticated ciphertext plus routing metadata only.
///
/// The outer event is signed with a fresh secp256k1 key per packet unless a
/// [publisherKey] is given. Sender identity is proven by the packet, not the
/// event, so a per-packet key keeps relays from linking a sender's events to
/// one another.
///
/// Scope in this release:
///
/// * only direct (`p:`) packets are published: messages, acknowledgements,
///   and group-key updates. Channel and group traffic stays on BLE;
/// * only packets this device originated are published. Relaying and
///   BLE/Nostr bridging are deliberately absent;
/// * a relay `OK` counts as a delivered *route*. The facade still reports
///   `delivered` only after the recipient's signed acknowledgement.
class NostrChatTransport implements RelayChatTransport {
  /// Creates a transport for [identity] over [relays]; call [start] to
  /// connect.
  ///
  /// An empty [relays] list is allowed: the transport stays idle and
  /// unavailable until [setRelays] adds some. Throws [ArgumentError] if
  /// [relays] lists more than [maximumRelays], or contains an entry that is
  /// not a `wss://` URL with a host. `ws://` is accepted only with [allowInsecureRelays], which exposes
  /// all relay traffic, including tags and timing, to the network path.
  /// Duplicate URLs are merged. [connector] defaults to [connectWebSocket].
  NostrChatTransport({
    required this.identity,
    required List<String> relays,
    NostrSocketConnector? connector,
    this.publisherKey,
    this.eventKind = defaultEventKind,
    this.backfill = const Duration(hours: 2),
    this.subscriptionLimit = 200,
    this.okTimeout = const Duration(seconds: 5),
    this.connectTimeout = const Duration(seconds: 10),
    this.minimumReconnectDelay = const Duration(seconds: 1),
    this.maximumReconnectDelay = const Duration(seconds: 30),
    this.maximumPacketSize = 32 * 1024,
    this.keepAliveInterval = const Duration(seconds: 30),
    this.keepAliveTimeout = const Duration(seconds: 10),
    this.allowInsecureRelays = false,
    DateTime Function()? clock,
    Random? random,
  }) : _connector = connector ?? connectWebSocket,
       _clock = clock ?? DateTime.now,
       _random = random ?? Random.secure(),
       _codec = ChatPacketCodec(maxPacketSize: maximumPacketSize),
       _relays = _parseRelays(relays, allowInsecure: allowInsecureRelays) {
    _ownRouteKey = routeKey('p:${identity.peerId}');
  }

  /// NIP-78 application-specific data. Addressable, so relays store it for
  /// offline recipients, and the `d` tag carries the packet id.
  static const defaultEventKind = 30078;

  /// Single-letter tag carrying [routeKey], so relays can index it.
  static const routeTag = 'y';

  /// Upper bound on configured relays.
  static const maximumRelays = 16;

  /// Hashed routing key for a packet destination.
  ///
  /// Hashing gives every route tag the same length and keeps raw mesh
  /// addresses out of relay indexes. It is not secrecy: anyone who knows a
  /// peer id can compute the key and watch for traffic to it.
  static String routeKey(String destination) => hashing.sha256
      .convert(utf8.encode('ble_mesh/nostr/route/v1\u0000$destination'))
      .toString();

  /// Local identity. Its peer id selects the route this transport
  /// subscribes to, and only packets it sent are published by [send].
  final ChatIdentity identity;

  /// Fixed envelope key for relays that rate-limit or allow-list by pubkey.
  /// Using one links every event this device publishes.
  final NostrKeyPair? publisherKey;

  /// Nostr event kind published and subscribed to. Defaults to
  /// [defaultEventKind]; every participant must use the same kind.
  final int eventKind;

  /// How far back a new subscription asks relays for stored events.
  final Duration backfill;

  /// Maximum stored events each relay is asked to return on subscription.
  final int subscriptionLimit;

  /// How long a publish waits for a relay's `OK` before counting that relay
  /// as not delivered.
  final Duration okTimeout;

  /// How long opening one relay connection may take before it is retried.
  final Duration connectTimeout;

  /// Base reconnect delay, doubled after each consecutive failure.
  final Duration minimumReconnectDelay;

  /// Cap on the reconnect delay. The actual delay is jittered between half
  /// and all of the current ceiling.
  final Duration maximumReconnectDelay;

  /// Largest encoded packet published or accepted. Public relays commonly
  /// cap events near 64 KiB and base64 adds a third.
  final int maximumPacketSize;

  /// How often each connected relay is probed.
  ///
  /// Mobile hotspots and carrier NATs silently drop idle connections, which
  /// leaves a socket that looks open but delivers nothing: relay pushes,
  /// including recipients' acknowledgements, are lost and nothing reconnects.
  /// A probe is a `REQ` for an event id that cannot exist, which every
  /// NIP-01 relay answers with `EOSE`. It also keeps NAT mappings alive.
  final Duration keepAliveInterval;

  /// A probe unanswered for this long marks the connection dead; it is
  /// dropped, reconnected, and resubscribed with backfill, which recovers
  /// whatever was missed.
  final Duration keepAliveTimeout;

  final NostrSocketConnector _connector;
  final DateTime Function() _clock;
  final Random _random;
  final ChatPacketCodec _codec;
  final List<_Relay> _relays;
  late final String _ownRouteKey;

  /// Whether plain `ws://` relays are accepted, for local test relays only.
  final bool allowInsecureRelays;

  /// Route keys of offline BLE peers this gateway receives for, mapped to
  /// their peer ids. Empty unless the facade is acting as a gateway.
  final Map<String, String> _bridgedRoutes = {};

  /// Upper bound on routes a gateway subscribes to on behalf of others.
  static const maximumBridgedPeers = 64;

  final _incoming = StreamController<ReceivedChatPacket>.broadcast();
  final _availability = StreamController<bool>.broadcast();
  final _relayChanges = StreamController<List<Uri>>.broadcast();
  final _peers = StreamController<List<ChatPeer>>.broadcast();
  final _errors = StreamController<Object>.broadcast();

  /// Signed events by packet id, so a retry republishes the same event id
  /// and skips relays that already stored it.
  final Map<String, _Published> _published = {};

  /// Recently processed event ids. Short-lived on purpose: it absorbs the
  /// same live event arriving from several relays, while a backfill after a
  /// reconnect still reaches the facade and can re-trigger a lost ACK.
  final Map<String, DateTime> _recentEvents = {};
  static const _recentEventWindow = Duration(minutes: 2);
  static const _maximumRecentEvents = 4096;
  static const _maximumPublished = 512;
  static const _maximumPendingEvents = 256;

  Future<void> _eventWork = Future<void>.value();
  int _pendingEvents = 0;
  bool _started = false;
  bool _lastAvailable = false;
  String _lastConnected = '';

  @override
  String get id => 'nostr';

  @override
  bool get available => _relays.any((relay) => relay.ready);

  @override
  Stream<bool> get availabilityChanges => _availability.stream;

  @override
  Stream<ReceivedChatPacket> get incoming => _incoming.stream;

  /// Relays do not reveal who is online, so no peers are ever reported.
  @override
  Stream<List<ChatPeer>> get peers => _peers.stream;

  /// Relay failures, rejected publishes, notices, and dropped inbound
  /// events, usually as [NostrRelayException]. Informational; the transport
  /// keeps running.
  Stream<Object> get errors => _errors.stream;

  /// Emits [connectedRelays] whenever a relay connects or drops.
  Stream<List<Uri>> get connectedRelayChanges => _relayChanges.stream;

  /// Relays with an open connection and an active subscription.
  List<Uri> get connectedRelays => [
    for (final relay in _relays)
      if (relay.ready) relay.url,
  ];

  int get _maximumContentLength => (maximumPacketSize + 2) ~/ 3 * 4;

  @override
  Future<void> start() async {
    if (_started) return;
    _started = true;
    await Future.wait(_relays.map(_connect));
  }

  @override
  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    for (final relay in _relays) {
      relay.reconnectTimer?.cancel();
      relay.reconnectTimer = null;
      await _drop(relay, relay.socket, reconnect: false);
    }
    await _eventWork;
    _publishAvailability();
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _incoming.close();
    await _availability.close();
    await _relayChanges.close();
    await _peers.close();
    await _errors.close();
  }

  /// Skips any pending backoff and reconnects every closed relay now.
  ///
  /// Call this when the host sees connectivity return; otherwise recovery
  /// waits for the current backoff, which can reach [maximumReconnectDelay].
  void reconnectNow() {
    if (!_started) return;
    for (final relay in _relays) {
      if (relay.socket != null || relay.connecting) continue;
      relay.reconnectTimer?.cancel();
      relay.reconnectTimer = null;
      relay.failures = 0;
      unawaited(_connect(relay));
    }
  }

  /// Replaces the configured relays while running.
  ///
  /// Relays that stay are left connected, removed ones are closed, and added
  /// ones connect at once. An empty list leaves the transport idle and
  /// unavailable. Throws [ArgumentError] for an invalid URL, leaving the
  /// current relays unchanged.
  Future<void> setRelays(List<String> relays) async {
    final next = _parseRelays(relays, allowInsecure: allowInsecureRelays);
    final wanted = {for (final relay in next) relay.key};
    final removed = _relays
        .where((relay) => !wanted.contains(relay.key))
        .toList();
    for (final relay in removed) {
      _relays.remove(relay);
      relay.reconnectTimer?.cancel();
      relay.reconnectTimer = null;
      await _drop(relay, relay.socket, reconnect: false);
    }
    final existing = {for (final relay in _relays) relay.key};
    final added = next.where((relay) => !existing.contains(relay.key)).toList();
    _relays.addAll(added);
    _publishAvailability();
    if (_started) await Future.wait(added.map(_connect));
  }

  /// URLs of the configured relays, connected or not.
  List<Uri> get relays => [for (final relay in _relays) relay.url];

  static const _none = ChatTransportSendResult(
    attemptedRoutes: 0,
    deliveredRoutes: 0,
  );

  @override
  Future<ChatTransportSendResult> send(
    ChatPacket packet, {
    // Relays are not paths to a peer, so every connected relay is used.
    String? routeId,
    String? excludeRouteId,
  }) async {
    if (!_started || !_publishable(packet)) return _none;
    return _publishToRelays(packet);
  }

  /// Publishes another device's packet as a gateway.
  ///
  /// Only direct, signed packets whose origin set the signed
  /// [ChatPacket.bridgeable] flag are accepted, so a gateway cannot expose
  /// traffic whose sender did not consent. Policy (whether to bridge at all) belongs to
  /// the facade.
  @override
  Future<ChatTransportSendResult> bridge(ChatPacket packet) async {
    if (!_started ||
        packet.senderId == identity.peerId ||
        !packet.bridgeable ||
        !packet.destination.startsWith('p:') ||
        packet.signature == null ||
        packet.senderKeys == null ||
        packet.isExpired(_clock())) {
      return _none;
    }
    return _publishToRelays(packet);
  }

  /// Offline peers, reachable over BLE, whose online traffic this gateway
  /// should receive. Replaces the previous set and updates every relay
  /// subscription.
  ///
  /// Subscribing reveals the peers' route keys to relays, so the facade
  /// passes only peers that registered consent.
  @override
  void setBridgedPeers(Set<String> peerIds) {
    final next = <String, String>{
      for (final peerId in peerIds.take(maximumBridgedPeers))
        if (peerId != identity.peerId) routeKey('p:$peerId'): peerId,
    };
    if (next.length == _bridgedRoutes.length &&
        next.keys.every(_bridgedRoutes.containsKey)) {
      return;
    }
    _bridgedRoutes
      ..clear()
      ..addAll(next);
    for (final relay in _relays) {
      final socket = relay.socket;
      if (relay.ready && socket != null) {
        // NIP-01: a REQ reusing a subscription id replaces its filter.
        _sendRequest(relay, socket);
      }
    }
  }

  /// Peers currently bridged by this gateway.
  Set<String> get bridgedPeers => _bridgedRoutes.values.toSet();

  Future<ChatTransportSendResult> _publishToRelays(ChatPacket packet) async {
    final relays = _relays.where((relay) => relay.ready).toList();
    if (relays.isEmpty) return _none;
    final _Published published;
    try {
      published = _publishedFor(packet);
    } on ChatPacketFormatException catch (error) {
      _errors.add(error);
      return _none;
    }
    final results = await Future.wait(
      relays.map((relay) => _publish(relay, published)),
    );
    return ChatTransportSendResult(
      attemptedRoutes: relays.length,
      deliveredRoutes: results.where((accepted) => accepted).length,
    );
  }

  bool _publishable(ChatPacket packet) =>
      packet.senderId == identity.peerId &&
      packet.destination.startsWith('p:') &&
      packet.signature != null &&
      packet.senderKeys != null &&
      !packet.isExpired(_clock());

  _Published _publishedFor(ChatPacket packet) {
    final now = _clock();
    _published.removeWhere((_, item) => !item.expiresAt.isAfter(now));
    final existing = _published[packet.id];
    if (existing != null) return existing;
    final content = base64.encode(_codec.encode(packet));
    final expiration = (packet.expiresAt.millisecondsSinceEpoch + 999) ~/ 1000;
    final event = NostrEvent.sign(
      keys: publisherKey ?? NostrKeyPair.generate(_random),
      kind: eventKind,
      tags: [
        ['d', packet.id],
        [routeTag, routeKey(packet.destination)],
        ['expiration', '$expiration'],
        ['alt', 'ble_mesh chat packet'],
      ],
      content: content,
      createdAt: now,
      random: _random,
    );
    while (_published.length >= _maximumPublished) {
      _published.remove(_published.keys.first);
    }
    return _published[packet.id] = _Published(event, packet.expiresAt);
  }

  Future<bool> _publish(_Relay relay, _Published published) async {
    if (published.acceptedBy.contains(relay.key)) return true;
    final socket = relay.socket;
    if (socket == null) return false;
    final eventId = published.event.id;
    var completer = relay.pendingOk[eventId];
    if (completer == null) {
      completer = Completer<bool>();
      relay.pendingOk[eventId] = completer;
      try {
        socket.send(jsonEncode(['EVENT', published.event.toJson()]));
      } on Object catch (error) {
        relay.pendingOk.remove(eventId);
        _errors.add(NostrRelayException(relay.url, 'publish failed: $error'));
        return false;
      }
    }
    try {
      final accepted = await completer.future.timeout(okTimeout);
      if (accepted) published.acceptedBy.add(relay.key);
      return accepted;
    } on TimeoutException {
      return false;
    } finally {
      if (identical(relay.pendingOk[eventId], completer)) {
        relay.pendingOk.remove(eventId);
      }
    }
  }

  Future<void> _connect(_Relay relay) async {
    if (!_started || relay.connecting || relay.socket != null) return;
    relay.connecting = true;
    try {
      final socket = await _connector(relay.url).timeout(connectTimeout);
      if (!_started) {
        await socket.close();
        return;
      }
      relay.socket = socket;
      relay.subscription = socket.messages.listen(
        (message) => _onRelayMessage(relay, message),
        onError: (Object error) {
          _errors.add(
            NostrRelayException(relay.url, 'connection error: $error'),
          );
          unawaited(_drop(relay, socket));
        },
        onDone: () => unawaited(_drop(relay, socket)),
        cancelOnError: true,
      );
      _subscribe(relay, socket);
    } on Object catch (error) {
      _errors.add(NostrRelayException(relay.url, 'connect failed: $error'));
      _scheduleReconnect(relay);
    } finally {
      relay.connecting = false;
    }
  }

  void _subscribe(_Relay relay, NostrSocket socket) {
    relay.subscriptionId = 'bm-${_randomHex(6)}';
    if (!_sendRequest(relay, socket)) return;
    relay.ready = true;
    _publishAvailability();
    relay.keepAliveTimer?.cancel();
    relay.keepAliveTimer = Timer.periodic(
      keepAliveInterval,
      (_) => _probe(relay, socket),
    );
  }

  static final _impossibleEventId = '0' * 64;

  void _probe(_Relay relay, NostrSocket socket) {
    if (!identical(relay.socket, socket) || relay.probeId != null) return;
    final probeId = 'bm-ping-${_randomHex(4)}';
    relay.probeId = probeId;
    try {
      socket.send(
        jsonEncode([
          'REQ',
          probeId,
          {
            'ids': [_impossibleEventId],
            'limit': 1,
          },
        ]),
      );
    } on Object catch (error) {
      _errors.add(NostrRelayException(relay.url, 'keep-alive failed: $error'));
      unawaited(_drop(relay, socket));
      return;
    }
    relay.probeTimer = Timer(keepAliveTimeout, () {
      if (!identical(relay.socket, socket) || relay.probeId != probeId) return;
      _errors.add(
        NostrRelayException(
          relay.url,
          'relay stopped responding; reconnecting',
        ),
      );
      unawaited(_drop(relay, socket));
    });
  }

  bool _sendRequest(_Relay relay, NostrSocket socket) {
    final since = _clock().subtract(backfill).millisecondsSinceEpoch ~/ 1000;
    try {
      socket.send(
        jsonEncode([
          'REQ',
          relay.subscriptionId,
          {
            'kinds': [eventKind],
            '#$routeTag': [_ownRouteKey, ..._bridgedRoutes.keys],
            'since': since,
            'limit': subscriptionLimit,
          },
        ]),
      );
      return true;
    } on Object catch (error) {
      _errors.add(NostrRelayException(relay.url, 'subscribe failed: $error'));
      unawaited(_drop(relay, socket));
      return false;
    }
  }

  /// Tears down [socket] if it is still the relay's current one.
  Future<void> _drop(
    _Relay relay,
    NostrSocket? socket, {
    bool reconnect = true,
  }) async {
    if (socket == null || !identical(relay.socket, socket)) return;
    relay.socket = null;
    relay.ready = false;
    relay.subscriptionId = null;
    relay.keepAliveTimer?.cancel();
    relay.keepAliveTimer = null;
    relay.probeTimer?.cancel();
    relay.probeTimer = null;
    relay.probeId = null;
    final subscription = relay.subscription;
    relay.subscription = null;
    for (final pending in relay.pendingOk.values) {
      if (!pending.isCompleted) pending.complete(false);
    }
    relay.pendingOk.clear();
    _publishAvailability();
    if (reconnect && _started) _scheduleReconnect(relay);
    await subscription?.cancel();
    try {
      await socket.close();
    } on Object {
      // Already closed by the relay.
    }
  }

  /// Exponential backoff with jitter: half the delay is fixed and half is
  /// random, so relays recovering together do not see a synchronized burst.
  void _scheduleReconnect(_Relay relay) {
    if (!_started || relay.reconnectTimer != null) return;
    relay.failures++;
    final exponent = min(relay.failures - 1, 20);
    final ceiling = min(
      minimumReconnectDelay.inMilliseconds * pow(2, exponent),
      maximumReconnectDelay.inMilliseconds.toDouble(),
    );
    final delay = Duration(
      milliseconds: (ceiling / 2 + _random.nextDouble() * ceiling / 2).round(),
    );
    relay.reconnectTimer = Timer(delay, () {
      relay.reconnectTimer = null;
      unawaited(_connect(relay));
    });
  }

  void _onRelayMessage(_Relay relay, String message) {
    // Bound the work before parsing: JSON decoding is proportional to size.
    if (message.length > _maximumContentLength + 4096) {
      _errors.add(NostrRelayException(relay.url, 'oversized relay message'));
      return;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(message);
    } on FormatException {
      _errors.add(NostrRelayException(relay.url, 'malformed relay message'));
      return;
    }
    if (decoded is! List || decoded.isEmpty || decoded.first is! String) {
      _errors.add(NostrRelayException(relay.url, 'malformed relay message'));
      return;
    }
    switch (decoded.first) {
      case 'EVENT':
        if (decoded.length == 3 && decoded[1] == relay.subscriptionId) {
          _enqueueEvent(relay, decoded[2]);
        }
      case 'OK':
        if (decoded.length >= 3 && decoded[1] is String && decoded[2] is bool) {
          final reason = decoded.length >= 4 && decoded[3] is String
              ? decoded[3] as String
              : '';
          // NIP-01 allows `true` with a `duplicate:` prefix; some relays send
          // `false` for a duplicate. Either way the relay holds the event.
          final accepted =
              decoded[2] == true || reason.startsWith('duplicate:');
          if (!accepted) {
            _errors.add(
              NostrRelayException(
                relay.url,
                'event rejected: ${_trim(reason)}',
              ),
            );
          }
          final pending = relay.pendingOk[decoded[1]];
          if (pending != null && !pending.isCompleted) {
            pending.complete(accepted);
          }
        }
      case 'EOSE':
        // The subscription is healthy, so the next failure starts the
        // backoff from the bottom again.
        if (decoded.length >= 2 && decoded[1] == relay.subscriptionId) {
          relay.failures = 0;
        }
        if (decoded.length >= 2 &&
            relay.probeId != null &&
            decoded[1] == relay.probeId) {
          final probeId = relay.probeId!;
          relay.probeTimer?.cancel();
          relay.probeTimer = null;
          relay.probeId = null;
          try {
            relay.socket?.send(jsonEncode(['CLOSE', probeId]));
          } on Object {
            // The next probe will find out.
          }
        }
      case 'CLOSED':
        if (decoded.length >= 2 && decoded[1] == relay.subscriptionId) {
          final reason = decoded.length >= 3 ? '${decoded[2]}' : '';
          _errors.add(
            NostrRelayException(
              relay.url,
              'subscription closed: ${_trim(reason)}',
            ),
          );
          // Reconnecting resubscribes, under backoff.
          unawaited(_drop(relay, relay.socket));
        }
      case 'NOTICE':
        _errors.add(
          NostrRelayException(
            relay.url,
            'notice: ${_trim(decoded.length >= 2 ? '${decoded[1]}' : '')}',
          ),
        );
      default:
      // AUTH, COUNT, and future message types are not used.
    }
  }

  void _enqueueEvent(_Relay relay, Object? json) {
    if (!_started || _pendingEvents >= _maximumPendingEvents) return;
    _pendingEvents++;
    _eventWork = _eventWork
        .then((_) => _onEvent(relay, json))
        .catchError((Object error) {
          if (!_errors.isClosed) {
            _errors.add(
              error is NostrRelayException
                  ? error
                  : NostrRelayException(relay.url, 'invalid event: $error'),
            );
          }
        })
        .whenComplete(() => _pendingEvents--);
  }

  Future<void> _onEvent(_Relay relay, Object? json) async {
    if (!_started) return;
    NostrRelayException reject(String reason) =>
        NostrRelayException(relay.url, 'invalid event: $reason');

    final event = NostrEvent.fromJson(json);
    // Cheap structural checks first; signature verification is the costly
    // step and should only run on events that could be for us.
    if (event.kind != eventKind) throw reject('unexpected kind');
    if (event.content.length > _maximumContentLength) {
      throw reject('oversized content');
    }
    final route = event.tag(routeTag);
    final bridgedPeer = _bridgedRoutes[route];
    if (route != _ownRouteKey && bridgedPeer == null) {
      throw reject('not addressed to this peer');
    }
    final packetId = event.tag('d');
    if (packetId == null || !_packetIdPattern.hasMatch(packetId)) {
      throw reject('missing packet id');
    }
    final now = _clock();
    final expiration = int.tryParse(event.tag('expiration') ?? '');
    if (expiration != null && expiration * 1000 <= now.millisecondsSinceEpoch) {
      return;
    }
    _recentEvents.removeWhere((_, expiry) => !expiry.isAfter(now));
    // Checked before verifying so a flood of copies costs one verification.
    // An event is only remembered after it verifies, so a forgery reusing a
    // genuine id cannot suppress the genuine event.
    if (_recentEvents.containsKey(event.id)) return;
    if (!event.verify()) throw reject('bad event signature');
    while (_recentEvents.length >= _maximumRecentEvents) {
      _recentEvents.remove(_recentEvents.keys.first);
    }
    _recentEvents[event.id] = now.add(_recentEventWindow);

    final ChatPacket packet;
    try {
      packet = _codec.decode(base64.decode(event.content));
    } on FormatException catch (error) {
      throw reject('undecodable packet: ${error.message}');
    }
    if (packet.id != packetId) throw reject('packet id does not match tag');
    final expected = bridgedPeer == null
        ? 'p:${identity.peerId}'
        : 'p:$bridgedPeer';
    if (packet.destination != expected) {
      throw reject('packet destination does not match its route');
    }
    if (bridgedPeer != null && !packet.bridgeable) {
      throw reject('packet for a bridged peer lacks bridge consent');
    }
    if (packet.signature == null || packet.senderKeys == null) {
      // Internet peers are anonymous; only signed packets are admitted.
      throw reject('unsigned packet');
    }
    if (packet.senderId == identity.peerId || packet.isExpired(now)) return;
    if (!_started || _incoming.isClosed) return;
    _incoming.add(
      ReceivedChatPacket(
        packet: packet,
        transportId: id,
        routeId: relay.key,
        senderKeys: packet.senderKeys,
      ),
    );
  }

  void _publishAvailability() {
    final next = available;
    final connected = connectedRelays;
    final key = connected.join(' ');
    if (key != _lastConnected && !_relayChanges.isClosed) {
      _lastConnected = key;
      _relayChanges.add(connected);
    }
    if (next == _lastAvailable || _availability.isClosed) return;
    _lastAvailable = next;
    _availability.add(next);
  }

  String _randomHex(int length) => List<int>.generate(
    length,
    (_) => _random.nextInt(256),
  ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  static String _trim(String value) =>
      value.length <= 200 ? value : '${value.substring(0, 200)}…';

  static final _packetIdPattern = RegExp(r'^[0-9a-f]{32}$');

  static List<_Relay> _parseRelays(
    List<String> relays, {
    required bool allowInsecure,
  }) {
    if (relays.length > maximumRelays) {
      throw ArgumentError('at most $maximumRelays relays are supported');
    }
    final parsed = <String, _Relay>{};
    for (final value in relays) {
      final uri = Uri.tryParse(value.trim());
      final secure = uri?.scheme == 'wss';
      final insecure = uri?.scheme == 'ws';
      if (uri == null ||
          uri.host.isEmpty ||
          !(secure || (insecure && allowInsecure))) {
        throw ArgumentError.value(
          value,
          'relays',
          allowInsecure
              ? 'must be a ws:// or wss:// URL'
              : 'must be a wss:// URL',
        );
      }
      parsed.putIfAbsent(uri.toString(), () => _Relay(uri));
    }
    return parsed.values.toList();
  }
}

class _Relay {
  _Relay(this.url);

  final Uri url;
  NostrSocket? socket;
  StreamSubscription<String>? subscription;
  String? subscriptionId;
  bool ready = false;
  bool connecting = false;
  int failures = 0;
  Timer? reconnectTimer;
  Timer? keepAliveTimer;
  Timer? probeTimer;
  String? probeId;
  final Map<String, Completer<bool>> pendingOk = {};

  String get key => url.toString();
}

class _Published {
  _Published(this.event, this.expiresAt);

  final NostrEvent event;
  final DateTime expiresAt;
  final Set<String> acceptedBy = {};
}
