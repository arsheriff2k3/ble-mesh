// On-device smoke suite: run on every supported platform before a release.
//
//   flutter test integration_test -d <device-id>
//
// It exercises what unit tests on the host cannot: the native plugin
// registration, platform secure key storage, and the protocol stack running
// on the device's own CPU. It does not need a second device or a radio link.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ble_mesh_chat/ble_mesh_chat.dart';
import 'package:ble_mesh_chat/file_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the native plugin registers and reports capabilities', (
    tester,
  ) async {
    final ble = BleMeshTransport();
    addTearDown(ble.dispose);
    final capabilities = await ble.capabilities();
    final mobileOrMac =
        Platform.isAndroid || Platform.isIOS || Platform.isMacOS;
    expect(capabilities.supportsCentral, mobileOrMac);
    expect(capabilities.platformName, isNotEmpty);
    // Adapter state must be readable without starting the radio.
    await ble.currentAdapterState();
  });

  testWidgets('secure key storage round-trips an identity', (tester) async {
    final directory = await Directory.systemTemp.createTemp('ble_mesh_smoke');
    addTearDown(() => directory.delete(recursive: true));
    final store = PlatformIdentityStore(
      fallback: FileIdentityStore(directory: directory),
    );
    final existing = await store.load();
    if (existing != null) {
      // The example app's own identity lives under the same keys. Never
      // overwrite or erase it: only prove it loads consistently.
      final again = await store.load();
      expect(again?.peerId, existing.peerId);
      return;
    }
    final created = await ChatKeyPair.generate();
    await store.save(created);
    final loaded = await store.load();
    expect(loaded?.peerId, created.peerId);
    expect(loaded!.publicKeys, created.publicKeys);
    await store.erase();
    expect(await store.load(), isNull);
  });

  testWidgets('an encrypted message crosses a three-device relay chain', (
    tester,
  ) async {
    final keys = [for (var i = 0; i < 3; i++) await ChatKeyPair.generate()];
    final transports = [for (var i = 0; i < 3; i++) _MemoryTransport('n$i')];
    transports[0].connect(transports[1]);
    transports[1].connect(transports[2]);
    final chats = <BleMeshChat>[];
    for (var i = 0; i < 3; i++) {
      final security = PacketSecurity(identity: keys[i]);
      for (final other in keys) {
        if (other != keys[i]) {
          security.trustStore.observe(other.peerId, other.publicKeys);
        }
      }
      final chat = BleMeshChat(
        security: security,
        maximumRelayJitter: Duration.zero,
        minimumRelaySpacing: Duration.zero,
      );
      await chat.initialize(
        identity: ChatIdentity(peerId: keys[i].peerId, displayName: 'n$i'),
        transports: [transports[i]],
      );
      chats.add(chat);
    }
    addTearDown(() async {
      for (final chat in chats) {
        await chat.dispose();
      }
    });

    final received = <String>[];
    chats[2].messages
        .where((message) => !message.isLocal)
        .listen((message) => received.add(message.text));
    final delivered = Completer<void>();
    chats[0].messageStates.listen((change) {
      if (change.state == MessageState.delivered && !delivered.isCompleted) {
        delivered.complete();
      }
    });

    await chats[0].sendDirect(peerId: keys[2].peerId, text: 'on device');
    await delivered.future.timeout(const Duration(seconds: 20));
    expect(received, ['on device']);
    // The relay forwarded ciphertext, never the text.
    for (final packet in transports[1].forwarded) {
      expect(
        utf8.decode(packet.payload, allowMalformed: true),
        isNot(contains('on device')),
      );
    }
  });
}

/// Minimal in-memory transport so the suite needs no second device.
class _MemoryTransport implements ChatTransport {
  _MemoryTransport(this.nodeId);

  final String nodeId;
  final _incoming = StreamController<ReceivedChatPacket>.broadcast();
  final _availability = StreamController<bool>.broadcast();
  final _peers = StreamController<List<ChatPeer>>.broadcast();
  final Map<String, _MemoryTransport> _neighbors = {};
  final List<ChatPacket> forwarded = [];

  void connect(_MemoryTransport other) {
    _neighbors[other.nodeId] = other;
    other._neighbors[nodeId] = this;
  }

  @override
  String get id => 'memory';
  @override
  bool get available => _neighbors.isNotEmpty;
  @override
  Stream<bool> get availabilityChanges => _availability.stream;
  @override
  Stream<ReceivedChatPacket> get incoming => _incoming.stream;
  @override
  Stream<List<ChatPeer>> get peers => _peers.stream;

  @override
  Future<ChatTransportSendResult> send(
    ChatPacket packet, {
    String? routeId,
    String? excludeRouteId,
  }) async {
    forwarded.add(packet);
    final targets = _neighbors.entries
        .where(
          (entry) => routeId == null
              ? entry.key != excludeRouteId
              : entry.key == routeId,
        )
        .toList();
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
}
