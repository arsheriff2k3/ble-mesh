import 'dart:async';
import 'dart:convert';

import '../ble_api.g.dart';
import '../ble_mesh_transport.dart';
import '../models.dart';
import 'chat_models.dart';
import 'chat_transport.dart';
import 'fragmentation.dart';
import 'packet_codec.dart';

/// Adapts the low-level dual-role BLE byte pipe to complete chat packets.
class BleChatTransport implements ChatTransport {
  BleChatTransport({
    required this.identity,
    BleMeshTransport? transport,
    this.config,
    this.codec = const ChatPacketCodec(),
    this.fragmenter = const PacketFragmenter(),
    PacketReassembler? reassembler,
  }) : _ble = transport ?? BleMeshTransport(),
       _ownsBle = transport == null,
       _reassembler = reassembler ?? PacketReassembler();

  final ChatIdentity identity;
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
  bool _started = false;
  bool _lastAvailable = false;

  @override
  String get id => 'ble';
  @override
  bool get available => _ble.links.isNotEmpty;
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
        unawaited(_sendAnnouncement(link.linkId));
      }),
      _ble.linkDown.listen((down) {
        _peerByLink.remove(down.linkId);
        _reassembler.discardRoute(down.linkId);
        _publishPeers();
        _publishAvailability();
      }),
      _ble.frames.listen(_onFrame),
      _ble.errors.listen(_errors.add),
    ]);
    if (!_ble.isRunning) await _ble.start(config: config);
    for (final linkId in _ble.links.keys) {
      unawaited(_sendAnnouncement(linkId));
    }
    _publishAvailability();
  }

  @override
  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    if (_ble.isRunning) await _ble.stop();
    _peerByLink.clear();
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
    final targets = routeId == null
        ? _ble.links.values
              .where((link) => link.linkId != excludeRouteId)
              .toList()
        : [_ble.links[routeId]].whereType<BleLink>().toList();
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
        _errors.add(error);
      }
    }
    return ChatTransportSendResult(
      attemptedRoutes: targets.length,
      deliveredRoutes: delivered,
    );
  }

  Future<void> _sendAnnouncement(String linkId) async {
    final now = DateTime.now();
    final packet = ChatPacket(
      type: ChatPacketType.announce,
      packetId: createPacketId(),
      senderId: identity.peerId,
      destination: '*',
      ttl: 1,
      createdAt: now,
      expiresAt: now.add(const Duration(minutes: 5)),
      payload: utf8.encode(identity.displayName),
    );
    await send(packet, routeId: linkId);
  }

  void _onFrame(BleFrame frame) {
    try {
      final complete = _reassembler.add(frame.linkId, frame.data);
      if (complete == null) return;
      final packet = codec.decode(complete);
      if (packet.type == ChatPacketType.announce) {
        _onAnnouncement(frame.linkId, packet);
        return;
      }
      _incoming.add(
        ReceivedChatPacket(
          packet: packet,
          transportId: id,
          routeId: frame.linkId,
        ),
      );
    } on Object catch (error) {
      _errors.add(error);
    }
  }

  void _onAnnouncement(String linkId, ChatPacket packet) {
    if (packet.senderId.isEmpty || packet.senderId == identity.peerId) return;
    _peerByLink[linkId] = packet.senderId;
    try {
      _nameByPeer[packet.senderId] = utf8.decode(packet.payload);
    } on FormatException {
      _nameByPeer[packet.senderId] = packet.senderId;
    }
    unawaited(_suppressDuplicateLinks(packet.senderId));
    _publishPeers();
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
    final peerIds = _peerByLink.values.toSet();
    _peers.add(
      peerIds
          .map(
            (peerId) => ChatPeer(
              id: peerId,
              displayName: _nameByPeer[peerId] ?? peerId,
              transportId: id,
            ),
          )
          .toList(growable: false),
    );
  }
}
