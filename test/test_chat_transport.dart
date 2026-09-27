import 'dart:async';

import 'package:ble_mesh_chat/ble_mesh_chat.dart';

/// In-memory [ChatTransport] used to build topologies without radios.
class TestChatTransport implements ChatTransport {
  TestChatTransport(this.nodeId);

  final String nodeId;
  final _incoming = StreamController<ReceivedChatPacket>.broadcast();
  final _availability = StreamController<bool>.broadcast();
  final _peers = StreamController<List<ChatPeer>>.broadcast();
  final Map<String, TestChatTransport> _neighbors = {};
  final List<ChatPacket> sentPackets = [];

  @override
  String get id => 'test';
  @override
  bool get available => _neighbors.isNotEmpty;
  @override
  Stream<bool> get availabilityChanges => _availability.stream;
  @override
  Stream<ReceivedChatPacket> get incoming => _incoming.stream;
  @override
  Stream<List<ChatPeer>> get peers => _peers.stream;

  void connect(TestChatTransport other) {
    _neighbors[other.nodeId] = other;
    other._neighbors[nodeId] = this;
    _availability.add(true);
    other._availability.add(true);
  }

  void disconnect(TestChatTransport other) {
    _neighbors.remove(other.nodeId);
    other._neighbors.remove(nodeId);
    if (_neighbors.isEmpty) _availability.add(false);
    if (other._neighbors.isEmpty) other._availability.add(false);
  }

  /// Publishes [peers] as the peers currently reachable on this transport.
  void announcePeers(List<ChatPeer> peers) => _peers.add(peers);

  void inject(ChatPacket packet, {required TestChatTransport from}) {
    _incoming.add(
      ReceivedChatPacket(packet: packet, transportId: id, routeId: from.nodeId),
    );
  }

  @override
  Future<ChatTransportSendResult> send(
    ChatPacket packet, {
    String? routeId,
    String? excludeRouteId,
  }) async {
    sentPackets.add(packet);
    final targets = routeId == null
        ? _neighbors.entries.where((entry) => entry.key != excludeRouteId)
        : _neighbors.entries.where((entry) => entry.key == routeId);
    for (final target in targets) {
      target.value._incoming.add(
        ReceivedChatPacket(packet: packet, transportId: id, routeId: nodeId),
      );
    }
    return ChatTransportSendResult(
      attemptedRoutes: targets.length,
      deliveredRoutes: targets.length,
    );
  }

  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}

  Future<void> dispose() async {
    await _incoming.close();
    await _availability.close();
    await _peers.close();
  }
}
