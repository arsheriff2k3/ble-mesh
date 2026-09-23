import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../ble_api.g.dart';
import '../ble_mesh_transport.dart';
import '../models.dart';
import 'chat_models.dart';
import 'chat_transport.dart';
import 'crypto/chat_keys.dart';
import 'crypto/message_cipher.dart';
import 'crypto/packet_security.dart';
import 'crypto/trust_store.dart';
import 'fragmentation.dart';
import 'packet_codec.dart';
import 'message_store.dart';

/// Adapts the low-level dual-role BLE byte pipe to complete chat packets.
class BleChatTransport implements ChatTransport {
  BleChatTransport({
    required this.identity,
    BleMeshTransport? transport,
    this.config,
    this.codec = const ChatPacketCodec(),
    this.fragmenter = const PacketFragmenter(),
    this.security,
    PacketReassembler? reassembler,
  }) : _ble = transport ?? BleMeshTransport(),
       _ownsBle = transport == null,
       _reassembler = reassembler ?? PacketReassembler() {
    final keyed = security;
    if (keyed != null && keyed.identity.peerId != identity.peerId) {
      throw ArgumentError(
        'identity.peerId must be the fingerprint of the signing key; '
        'expected ${keyed.identity.peerId}',
      );
    }
  }

  final ChatIdentity identity;

  /// When present, announcements are signed and unauthenticated peers are
  /// refused. Null keeps the pre-Phase-3 plaintext behaviour for tests and
  /// for hosts that have not migrated.
  final PacketSecurity? security;
  final BleMeshTransport _ble;
  final bool _ownsBle;
  final BleConfig? config;
  final ChatPacketCodec codec;
  final PacketFragmenter fragmenter;
  final PacketReassembler _reassembler;

  final _incoming = StreamController<ReceivedChatPacket>.broadcast();
  final _availability = StreamController<bool>.broadcast();
  final _peers = StreamController<List<ChatPeer>>.broadcast();
  final _errors = StreamController<Object>.broadcast();
  final _subscriptions = <StreamSubscription<void>>[];
  final Map<String, String> _peerByLink = {};
  final Map<String, String> _nameByPeer = {};
  final Map<String, ChatPublicKeys> _keysByPeer = {};
  final Map<String, PeerTrust> _trustByPeer = {};
  final Map<String, Uint8List> _challenges = {};
  final Map<String, DateTime> _challengeTimes = {};
  final Map<String, DateTime> _answeredAt = {};
  final Map<String, ChatPacket> _advertisements = {};
  final DedupeCache _discoverySeen = DedupeCache();
  Future<void> _frameWork = Future<void>.value();
  int _pendingFrames = 0;
  final Set<Future<void>> _backgroundWork = {};
  Timer? _discoveryTimer;
  Timer? _handshakeTimer;
  bool _started = false;
  bool _lastAvailable = false;

  @override
  String get id => 'ble';
  @override
  bool get available =>
      security == null ? _ble.links.isNotEmpty : _peerByLink.isNotEmpty;
  @override
  Stream<bool> get availabilityChanges => _availability.stream;
  @override
  Stream<ReceivedChatPacket> get incoming => _incoming.stream;
  @override
  Stream<List<ChatPeer>> get peers => _peers.stream;
  Stream<Object> get errors => _errors.stream;
  BleMeshTransport get rawTransport => _ble;

  @override
  Future<void> start() async {
    if (_started) return;
    _started = true;
    _subscriptions.addAll([
      _ble.linkUp.listen((link) {
        _publishAvailability();
        _background(() => _beginLink(link.linkId));
      }),
      _ble.linkDown.listen((down) {
        _peerByLink.remove(down.linkId);
        _challenges.remove(down.linkId);
        _challengeTimes.remove(down.linkId);
        _answeredAt.remove(down.linkId);
        _reassembler.discardRoute(down.linkId);
        _publishPeers();
        _publishAvailability();
      }),
      _ble.frames.listen(_onFrame),
      _ble.errors.listen(_errors.add),
    ]);
    if (!_ble.isRunning) await _ble.start(config: config);
    for (final linkId in _ble.links.keys) {
      _background(() => _beginLink(linkId));
    }
    if (security != null) {
      _handshakeTimer = Timer.periodic(const Duration(seconds: 10), (_) {
        _background(retryAuthentication);
      });
      _discoveryTimer = Timer.periodic(const Duration(minutes: 1), (_) {
        _background(_publishAdvertisement);
      });
    }
    _publishAvailability();
  }

  @override
  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    _discoveryTimer?.cancel();
    _discoveryTimer = null;
    _handshakeTimer?.cancel();
    _handshakeTimer = null;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    await Future.wait(_backgroundWork.toList());
    await _frameWork;
    if (_ble.isRunning) await _ble.stop();
    _peerByLink.clear();
    _challenges.clear();
    _challengeTimes.clear();
    _answeredAt.clear();
    _advertisements.clear();
    _publishPeers();
    _publishAvailability();
  }

  Future<void> dispose() async {
    await stop();
    if (_ownsBle) await _ble.dispose();
    await _incoming.close();
    await _availability.close();
    await _peers.close();
    await _errors.close();
  }

  @override
  Future<ChatTransportSendResult> send(
    ChatPacket packet, {
    String? routeId,
    String? excludeRouteId,
  }) async {
    final handshake =
        packet.type == ChatPacketType.linkChallenge ||
        packet.type == ChatPacketType.announce;
    final targets =
        (routeId == null
                ? _ble.links.values
                      .where((link) => link.linkId != excludeRouteId)
                      .toList()
                : [_ble.links[routeId]].whereType<BleLink>().toList())
            .where(
              (link) =>
                  security == null ||
                  handshake ||
                  _peerByLink.containsKey(link.linkId),
            )
            .toList();
    var delivered = 0;
    final encoded = codec.encode(packet);
    for (final link in targets) {
      try {
        final fragments = fragmenter.fragment(
          packet.packetId,
          encoded,
          link.maxFrameSize,
        );
        for (final fragment in fragments) {
          await _ble.send(link.linkId, fragment);
        }
        delivered++;
      } catch (error) {
        // A link that vanished mid-send is ordinary mesh behaviour, not a
        // fault worth showing: the route simply does not count as delivered
        // and the router queues or retries on what is left.
        if (!_isVanishedLink(error)) _errors.add(error);
      }
    }
    return ChatTransportSendResult(
      attemptedRoutes: targets.length,
      deliveredRoutes: delivered,
    );
  }

  /// Whether [error] means the link disappeared before the frame went out.
  ///
  /// The Dart-side link cache and the platform registry drop a link at
  /// slightly different moments, so either layer can be the one to notice.
  static bool _isVanishedLink(Object error) =>
      error is BleUnknownLinkException ||
      (error is PlatformException && error.code == 'unknown_link');

  void _background(Future<void> Function() action) {
    late final Future<void> work;
    work = Future<void>.sync(action)
        .catchError((Object error) {
          if (_started) _errors.add(error);
        })
        .whenComplete(() => _backgroundWork.remove(work));
    _backgroundWork.add(work);
  }

  /// Reflects an explicitly approved trust change in the public peer list.
  void refreshTrust() {
    final keyed = security;
    if (keyed == null) return;
    for (final entry in _keysByPeer.entries) {
      _trustByPeer[entry.key] = keyed.trustStore.classify(
        entry.key,
        entry.value,
      );
    }
    _publishPeers();
  }

  /// Reissues expired link challenges, including after an approved rotation.
  Future<void> retryAuthentication() async {
    if (!_started || security == null) return;
    for (final linkId in _ble.links.keys.toList()) {
      if (_peerByLink.containsKey(linkId)) continue;
      final issued = _challengeTimes[linkId];
      if (issued == null ||
          DateTime.now().difference(issued) >= const Duration(seconds: 30)) {
        await _beginLink(linkId);
      }
    }
  }

  Future<void> _beginLink(String linkId) async {
    if (security == null) return _sendAnnouncement(linkId);
    final pending = _challengeTimes[linkId];
    if (pending != null &&
        DateTime.now().difference(pending) < const Duration(seconds: 30)) {
      return;
    }
    final nonce = Uint8List.fromList([
      ...createPacketId(),
      ...createPacketId(),
    ]);
    final now = DateTime.now();
    _challenges[linkId] = nonce;
    _challengeTimes[linkId] = now;
    await send(
      ChatPacket(
        type: ChatPacketType.linkChallenge,
        packetId: createPacketId(),
        senderId: identity.peerId,
        destination: '*',
        ttl: 1,
        createdAt: now,
        expiresAt: now.add(const Duration(seconds: 30)),
        payload: nonce,
      ),
      routeId: linkId,
    );
  }

  Future<void> _sendAnnouncement(String linkId, [Uint8List? challenge]) async {
    final now = DateTime.now();
    final packet = ChatPacket(
      type: ChatPacketType.announce,
      packetId: createPacketId(),
      senderId: identity.peerId,
      destination: '*',
      ttl: 1,
      createdAt: now,
      expiresAt: now.add(const Duration(minutes: 5)),
      payload: _announcementPayload(challenge),
    );
    final keyed = security;
    await send(
      keyed == null ? packet : await keyed.protect(packet, encrypt: false),
      routeId: linkId,
    );
  }

  /// `publicKeys || displayName`, so a peer arrives with everything needed to
  /// verify it and to encrypt back to it in one frame.
  Uint8List _announcementPayload([Uint8List? challenge]) {
    final name = utf8.encode(identity.displayName);
    final keyed = security;
    if (keyed == null) return Uint8List.fromList(name);
    return (BytesBuilder()
          ..add(keyed.identity.publicKeys.encode())
          ..add(challenge ?? Uint8List(0))
          ..add(name))
        .toBytes();
  }

  void _onFrame(BleFrame frame) {
    if (!_started || _pendingFrames >= 256) return;
    _pendingFrames++;
    _frameWork = _frameWork
        .then((_) async {
          if (!_started || !_ble.links.containsKey(frame.linkId)) return;
          final complete = _reassembler.add(frame.linkId, frame.data);
          if (complete == null) return;
          final packet = codec.decode(complete);
          if (packet.isExpired(DateTime.now())) return;
          if (packet.type == ChatPacketType.linkChallenge && security != null) {
            final now = DateTime.now();
            if (packet.payload.length != 32 || packet.ttl != 1) return;
            final last = _answeredAt[frame.linkId];
            if (last != null &&
                now.difference(last) < const Duration(seconds: 5)) {
              return;
            }
            _answeredAt[frame.linkId] = now;
            await _sendAnnouncement(frame.linkId, packet.payload);
            return;
          }
          if (packet.type == ChatPacketType.announce) {
            await _onAnnouncement(frame.linkId, packet);
            return;
          }
          if (security != null && !_peerByLink.containsKey(frame.linkId)) {
            return;
          }
          if (packet.type == ChatPacketType.peerAdvertisement) {
            if (security != null) await _onAdvertisement(frame.linkId, packet);
            return;
          }
          _incoming.add(
            ReceivedChatPacket(
              packet: packet,
              transportId: id,
              routeId: frame.linkId,
              senderKeys: packet.senderKeys ?? _keysByPeer[packet.senderId],
            ),
          );
        })
        .catchError((Object error) {
          _errors.add(error);
        })
        .whenComplete(() {
          _pendingFrames--;
        });
  }

  bool _freshDiscovery(ChatPacket packet) {
    final now = DateTime.now();
    return !packet.isSealed &&
        !packet.isExpired(now) &&
        !packet.createdAt.isAfter(now.add(const Duration(seconds: 30))) &&
        packet.expiresAt.difference(packet.createdAt) <=
            const Duration(minutes: 5) &&
        packet.createdAt.isBefore(packet.expiresAt) &&
        packet.payload.length <= 1120;
  }

  Future<void> _onAnnouncement(String linkId, ChatPacket packet) async {
    if (packet.senderId.isEmpty || packet.senderId == identity.peerId) return;
    final keyed = security;
    if (keyed == null) {
      _peerByLink[linkId] = packet.senderId;
      _nameByPeer[packet.senderId] = _decodeName(packet.payload);
      await _suppressDuplicateLinks(packet.senderId);
      _publishPeers();
      return;
    }
    final nonce = _challenges[linkId];
    final issued = _challengeTimes[linkId];
    if (!_freshDiscovery(packet) ||
        packet.payload.length < 96 ||
        nonce == null ||
        issued == null ||
        DateTime.now().difference(issued) > const Duration(seconds: 30)) {
      return;
    }
    for (var i = 0; i < nonce.length; i++) {
      if (nonce[i] != packet.payload[64 + i]) return;
    }
    final keys = ChatPublicKeys.decode(
      Uint8List.sublistView(packet.payload, 0, 64),
    );
    PeerTrust trust;
    try {
      trust = (await keyed.admit(packet, announcedKeys: keys)).trust;
    } on PeerKeyChangedException catch (error) {
      if (!await keyed.verifyForRelay(packet, senderKeys: keys)) rethrow;
      trust = PeerTrust.changed;
      _errors.add(error);
    }
    if (!_ble.links.containsKey(linkId)) return;
    _challenges.remove(linkId);
    _challengeTimes.remove(linkId);
    _peerByLink[linkId] = packet.senderId;
    _keysByPeer[packet.senderId] = keys;
    _trustByPeer[packet.senderId] = trust;
    _nameByPeer[packet.senderId] = _decodeName(
      Uint8List.sublistView(packet.payload, 96),
    );
    await _suppressDuplicateLinks(packet.senderId);
    _publishPeers();
    // Share cached, still-valid discovery records with a newly joined peer.
    for (final cached in _advertisements.values.toList()) {
      if (!cached.isExpired(DateTime.now()) && cached.ttl > 1) {
        await send(cached.withTtl(cached.ttl - 1), routeId: linkId);
      }
    }
    await _publishAdvertisement();
    _publishAvailability();
  }

  Future<void> _publishAdvertisement() async {
    final keyed = security;
    if (!_started || keyed == null) return;
    final now = DateTime.now();
    _advertisements.removeWhere((_, p) => p.isExpired(now));
    final packet = await keyed.protect(
      ChatPacket(
        type: ChatPacketType.peerAdvertisement,
        packetId: createPacketId(),
        senderId: identity.peerId,
        destination: '*',
        ttl: 5,
        createdAt: now,
        expiresAt: now.add(const Duration(minutes: 5)),
        payload: _announcementPayload(),
      ),
      encrypt: false,
    );
    _discoverySeen.remember(packet.id, packet.expiresAt);
    await send(packet);
    _publishPeers();
  }

  Future<void> _onAdvertisement(String linkId, ChatPacket packet) async {
    if (packet.senderId == identity.peerId ||
        !_freshDiscovery(packet) ||
        packet.destination != '*' ||
        packet.payload.length < 64) {
      return;
    }
    final keys = ChatPublicKeys.decode(
      Uint8List.sublistView(packet.payload, 0, 64),
    );
    PeerTrust trust;
    try {
      trust = (await security!.admit(packet, announcedKeys: keys)).trust;
    } on PeerKeyChangedException catch (error) {
      if (!await security!.verifyForRelay(packet, senderKeys: keys)) rethrow;
      trust = PeerTrust.changed;
      _errors.add(error);
    }
    if (!_discoverySeen.remember(packet.id, packet.expiresAt)) return;
    final previous = _advertisements[packet.senderId];
    if (previous != null && !packet.createdAt.isAfter(previous.createdAt)) {
      return;
    }
    // Bound the live discovery table. Durable trust remains owned by the host.
    if (!_advertisements.containsKey(packet.senderId) &&
        _advertisements.length >= 256) {
      return;
    }
    _advertisements[packet.senderId] = packet;
    _keysByPeer[packet.senderId] = keys;
    _trustByPeer[packet.senderId] = trust;
    _nameByPeer[packet.senderId] = _decodeName(
      Uint8List.sublistView(packet.payload, 64),
    );
    _publishPeers();
    if (packet.ttl > 1) {
      await Future<void>.delayed(Duration(milliseconds: packet.packetId.first));
      if (_started) {
        await send(packet.withTtl(packet.ttl - 1), excludeRouteId: linkId);
      }
    }
  }

  String _decodeName(List<int> bytes) {
    try {
      final name = utf8.decode(bytes);
      return name.isEmpty ? 'unknown' : name;
    } on FormatException {
      return 'unknown';
    }
  }

  Future<void> _suppressDuplicateLinks(String peerId) async {
    final candidates = _peerByLink.entries
        .where((entry) => entry.value == peerId)
        .map((entry) => _ble.links[entry.key])
        .whereType<BleLink>()
        .toList();
    if (candidates.length < 2) return;
    final desiredRole = identity.peerId.compareTo(peerId) < 0
        ? BleLinkRole.central
        : BleLinkRole.peripheral;
    candidates.sort((a, b) {
      final aPreferred = a.role == desiredRole ? 0 : 1;
      final bPreferred = b.role == desiredRole ? 0 : 1;
      final roleOrder = aPreferred.compareTo(bPreferred);
      return roleOrder != 0 ? roleOrder : a.linkId.compareTo(b.linkId);
    });
    for (final duplicate in candidates.skip(1)) {
      _peerByLink.remove(duplicate.linkId);
      await _ble.disconnect(duplicate.linkId);
    }
    _publishPeers();
  }

  void _publishAvailability() {
    final next = available;
    if (next == _lastAvailable) return;
    _lastAvailable = next;
    _availability.add(next);
  }

  void _publishPeers() {
    _advertisements.removeWhere(
      (_, packet) => packet.isExpired(DateTime.now()),
    );
    final peerIds = {..._peerByLink.values, ..._advertisements.keys};
    _keysByPeer.removeWhere((id, _) => !peerIds.contains(id));
    _nameByPeer.removeWhere((id, _) => !peerIds.contains(id));
    _trustByPeer.removeWhere((id, _) => !peerIds.contains(id));
    _peers.add(
      peerIds
          .map(
            (peerId) => ChatPeer(
              id: peerId,
              displayName: _nameByPeer[peerId] ?? peerId,
              transportId: id,
              publicKeys: _keysByPeer[peerId],
              trust: _trustByPeer[peerId],
            ),
          )
          .toList(growable: false),
    );
  }
}
