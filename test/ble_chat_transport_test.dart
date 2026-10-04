import 'package:ble_mesh_chat/ble_mesh_chat.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';

import 'fake_ble_platform_api.dart';

void main() {
  late FakeBlePlatformApi platform;
  late BleMeshTransport ble;
  late BleChatTransport transport;

  setUp(() async {
    platform = FakeBlePlatformApi();
    ble = BleMeshTransport(api: platform);
    transport = BleChatTransport(
      identity: const ChatIdentity(peerId: 'a', displayName: 'Alice'),
      transport: ble,
    );
    await transport.start();
  });

  tearDown(() async {
    await transport.dispose();
    await ble.dispose();
    await platform.close();
  });

  test(
    'large negotiated MTUs cannot exceed the 512-byte attribute limit',
    () async {
      platform.emitLinkUp('large', maxFrameSize: 514);
      await pumpEventQueue(times: 20);
      platform.sent.clear();
      final result = await transport.send(
        packet(
          type: ChatPacketType.message,
          sender: 'a',
          destination: '*',
          payload: List.filled(1800, 42),
        ),
      );
      expect(result.deliveredRoutes, 1);
      expect(platform.sent.length, greaterThan(3));
      expect(platform.sent.every((frame) => frame.frame.length <= 512), isTrue);
    },
  );

  test(
    'frame submission keeps a bounded queue and waits for every completion',
    () async {
      platform.emitLinkUp('window', maxFrameSize: 512);
      await pumpEventQueue(times: 20);
      platform.sent.clear();
      platform.sendDelay = const Duration(milliseconds: 10);
      platform.peakSends = 0;
      final result = await transport.send(
        packet(
          type: ChatPacketType.message,
          sender: 'a',
          destination: '*',
          payload: List.filled(6000, 42),
        ),
      );
      expect(result.deliveredRoutes, 1);
      expect(platform.peakSends, 4);
      expect(platform.activeSends, 0);
      expect(platform.sent.length, greaterThan(12));
    },
  );

  test('keeps both physical roles but sends once per peer', () async {
    final peers = <List<ChatPeer>>[];
    transport.peers.listen(peers.add);
    platform.emitLinkUp('central', role: BleLinkRole.central);
    platform.emitLinkUp('peripheral', role: BleLinkRole.peripheral);
    await pumpEventQueue(times: 10);

    expect(
      platform.sent.where((frame) => frame.linkId == 'central'),
      isNotEmpty,
    );
    expect(
      platform.sent.where((frame) => frame.linkId == 'peripheral'),
      isNotEmpty,
    );

    final announcement = packet(
      type: ChatPacketType.announce,
      sender: 'z',
      destination: '*',
      payload: 'Zed'.codeUnits,
    );
    emitPacket(platform, 'central', announcement);
    emitPacket(platform, 'peripheral', announcement);
    await pumpEventQueue(times: 20);

    expect(platform.disconnected, isEmpty);
    platform.sent.clear();
    final sent = await transport.send(
      packet(
        type: ChatPacketType.message,
        sender: 'a',
        destination: '*',
        payload: [42],
      ),
    );
    expect(sent.deliveredRoutes, 1);
    expect(platform.sent.map((frame) => frame.linkId).toSet(), {'central'});
    platform.sent.clear();
    platform.sendFailures['central'] = PlatformException(code: 'unknown_link');
    final retry = await transport.send(
      packet(
        type: ChatPacketType.message,
        sender: 'a',
        destination: '*',
        payload: [44],
      ),
    );
    expect(retry.attemptedRoutes, 2);
    expect(retry.deliveredRoutes, 1);
    expect(platform.sent.map((frame) => frame.linkId).toSet(), {'peripheral'});
    expect(platform.disconnected, isEmpty);
    platform.sendFailures.clear();
    platform.sent.clear();
    platform.emitLinkDown('central');
    await pumpEventQueue(times: 20);
    final fallback = await transport.send(
      packet(
        type: ChatPacketType.message,
        sender: 'a',
        destination: '*',
        payload: [43],
      ),
    );
    expect(fallback.deliveredRoutes, 1);
    expect(platform.sent.map((frame) => frame.linkId).toSet(), {'peripheral'});
    expect(peers.last.single.id, 'z');
    expect(peers.last.single.displayName, 'Zed');
  });

  test('reassembles small BLE frames before publishing a packet', () async {
    platform.emitLinkUp('tiny', maxFrameSize: 20);
    await pumpEventQueue(times: 5);
    final incoming = <ReceivedChatPacket>[];
    transport.incoming.listen(incoming.add);
    final message = packet(
      type: ChatPacketType.message,
      sender: 'z',
      destination: 'p:a',
      payload: List<int>.filled(100, 0x41),
    );
    emitPacket(platform, 'tiny', message, maxFrameSize: 20);
    await pumpEventQueue(times: 10);

    expect(incoming, hasLength(1));
    expect(incoming.single.packet.payload, hasLength(100));
  });
}

ChatPacket packet({
  required ChatPacketType type,
  required String sender,
  required String destination,
  required List<int> payload,
}) {
  final now = DateTime.now();
  return ChatPacket(
    type: type,
    packetId: createPacketId(),
    senderId: sender,
    destination: destination,
    ttl: 5,
    createdAt: now,
    expiresAt: now.add(const Duration(minutes: 5)),
    payload: Uint8List.fromList(payload),
  );
}

void emitPacket(
  FakeBlePlatformApi platform,
  String linkId,
  ChatPacket packet, {
  int maxFrameSize = 244,
}) {
  final encoded = const ChatPacketCodec().encode(packet);
  final fragments = const PacketFragmenter().fragment(
    packet.packetId,
    encoded,
    maxFrameSize,
  );
  for (final fragment in fragments) {
    platform.emitFrame(linkId, fragment);
  }
}
