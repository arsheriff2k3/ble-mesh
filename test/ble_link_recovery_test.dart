import 'package:ble_mesh_chat/ble_mesh_chat.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ble_chat_transport_test.dart' show emitPacket, packet;
import 'fake_ble_platform_api.dart';
import 'test_chat_transport.dart';

/// Restart and radio-loss recovery: a peer that closes the app, a radio
/// switched off, and a start attempted before Bluetooth was on must not leave
/// messages queued behind links that no longer exist.
void main() {
  late FakeBlePlatformApi platform;
  late BleMeshTransport ble;
  late BleChatTransport transport;
  late List<List<ChatPeer>> peers;

  Future<void> startTransport({
    Duration staleLinkAge = const Duration(seconds: 60),
  }) async {
    ble = BleMeshTransport(api: platform);
    transport = BleChatTransport(
      identity: const ChatIdentity(peerId: 'a', displayName: 'Alice'),
      transport: ble,
      staleLinkAge: staleLinkAge,
      radioRecoveryInterval: const Duration(milliseconds: 20),
    );
    peers = [];
    transport.peers.listen(peers.add);
    await transport.start();
  }

  setUp(() => platform = FakeBlePlatformApi());
  tearDown(() async {
    await transport.dispose();
    await ble.dispose();
    await platform.close();
  });

  void announce(String linkId, String peerId) => emitPacket(
    platform,
    linkId,
    packet(
      type: ChatPacketType.announce,
      sender: peerId,
      destination: '*',
      payload: peerId.codeUnits,
    ),
  );

  List<String> currentPeers() =>
      peers.isEmpty ? const [] : peers.last.map((peer) => peer.id).toList();

  test('switching Bluetooth off forgets every authenticated peer', () async {
    await startTransport();
    platform.emitLinkUp('l1');
    await pumpEventQueue();
    announce('l1', 'z');
    await pumpEventQueue(times: 20);
    expect(currentPeers(), ['z']);

    // The platform reports only the adapter state, not a linkDown per link.
    platform.emitAdapterState(BleAdapterState.poweredOff);
    await pumpEventQueue(times: 20);
    expect(currentPeers(), isEmpty);
    expect(transport.available, isFalse);
  });

  test('a new connection that reuses a link id must identify itself '
      'again', () async {
    await startTransport();
    platform.emitLinkUp('l1');
    await pumpEventQueue();
    announce('l1', 'z');
    await pumpEventQueue(times: 20);
    expect(currentPeers(), ['z']);

    // Link ids are role + address, so a reconnect can reuse one, and the
    // linkDown for the old connection may never arrive.
    platform.emitLinkUp('l1');
    await pumpEventQueue(times: 20);
    expect(currentPeers(), isEmpty, reason: 'not yet re-announced');

    announce('l1', 'z');
    await pumpEventQueue(times: 20);
    expect(currentPeers(), ['z']);
  });

  test('the radio starts once Bluetooth is switched on after a failed '
      'start', () async {
    platform
      ..adapter = BleAdapterState.poweredOff
      ..startFailure = PlatformException(code: 'bluetooth_off');
    await startTransport();
    expect(ble.isRunning, isFalse);

    platform
      ..adapter = BleAdapterState.poweredOn
      ..startFailure = null;
    platform.emitAdapterState(BleAdapterState.poweredOn);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(ble.isRunning, isTrue);
  });

  test('the radio also recovers without an adapter event', () async {
    platform
      ..adapter = BleAdapterState.poweredOff
      ..startFailure = PlatformException(code: 'bluetooth_off');
    await startTransport();
    platform
      ..adapter = BleAdapterState.poweredOn
      ..startFailure = null;
    // Platforms that failed to start do not report adapter changes.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(ble.isRunning, isTrue);
  });

  test('after a peer restarts, its fresh link wins over a stale one', () async {
    await startTransport(staleLinkAge: const Duration(milliseconds: 50));
    // 'a' < 'z', so this side prefers its central link. The stale link sorts
    // first by id, which is exactly what used to keep it.
    platform.emitLinkUp('a-stale', role: BleLinkRole.central);
    await pumpEventQueue();
    announce('a-stale', 'z');
    await pumpEventQueue(times: 20);

    // z restarts: the old connection is half-open and never reports down,
    // and z connects again in both roles.
    await Future<void>.delayed(const Duration(milliseconds: 120));
    platform
      ..emitLinkUp('b-fresh', role: BleLinkRole.central)
      ..emitLinkUp('c-fresh', role: BleLinkRole.peripheral);
    await pumpEventQueue();
    announce('b-fresh', 'z');
    announce('c-fresh', 'z');
    await pumpEventQueue(times: 30);

    expect(platform.disconnected, containsAll(['a-stale', 'c-fresh']));
    expect(platform.disconnected, isNot(contains('b-fresh')));
  });

  test(
    'a link whose writes fail is dropped so the peer can reconnect',
    () async {
      await startTransport();
      platform.emitLinkUp('l1');
      await pumpEventQueue();
      announce('l1', 'z');
      await pumpEventQueue(times: 20);
      platform.sendFailures['l1'] = PlatformException(
        code: 'write_failed',
        message: 'GATT write timed out',
      );

      final result = await transport.send(
        packet(
          type: ChatPacketType.message,
          sender: 'a',
          destination: 'p:z',
          payload: [1, 2, 3],
        ),
      );
      await pumpEventQueue(times: 20);

      expect(result.deliveredRoutes, 0);
      expect(platform.disconnected, contains('l1'));
      expect(currentPeers(), isEmpty);
    },
  );

  test('the router tries other transports when the one listing the peer '
      'delivers nothing', () async {
    // Created only to satisfy tearDown.
    await startTransport();
    final stale = _ListedButDeadTransport();
    final online = TestChatTransport('online');
    final peer = TestChatTransport('peer');
    online.connect(peer);
    final chat = BleMeshChat(
      maximumRelayJitter: Duration.zero,
      minimumRelaySpacing: Duration.zero,
    );
    addTearDown(() async {
      await chat.dispose();
      await online.dispose();
      await peer.dispose();
    });
    await chat.initialize(
      identity: const ChatIdentity(peerId: 'a', displayName: 'A'),
      transports: [stale, online],
    );
    stale.list('z');
    await pumpEventQueue();
    final states = <MessageState>[];
    chat.messageStates.listen((change) => states.add(change.state));

    await chat.sendDirect(peerId: 'z', text: 'find another way');
    await pumpEventQueue();

    expect(states, contains(MessageState.sent));
    expect(states, isNot(contains(MessageState.queued)));
    expect(
      online.sentPackets.where((p) => p.type == ChatPacketType.message),
      hasLength(1),
    );
  });
}

/// Claims to be available and to list a peer, but delivers to no route: the
/// state a BLE transport is in when its links have silently gone away.
class _ListedButDeadTransport extends TestChatTransport {
  _ListedButDeadTransport() : super('stale');

  @override
  String get id => 'stale';
  @override
  bool get available => true;

  void list(String peerId) => announcePeers([
    ChatPeer(id: peerId, displayName: peerId, transportId: id),
  ]);

  @override
  Future<ChatTransportSendResult> send(
    ChatPacket packet, {
    String? routeId,
    String? excludeRouteId,
  }) async =>
      const ChatTransportSendResult(attemptedRoutes: 0, deliveredRoutes: 0);
}
