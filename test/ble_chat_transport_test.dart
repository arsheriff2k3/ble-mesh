import 'dart:typed_data';

import 'package:ble_mesh/ble_mesh.dart';
import 'package:flutter_test/flutter_test.dart';

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

  test('announces on link-up and suppresses the duplicate peer link', () async {
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

    expect(platform.disconnected, contains('peripheral'));
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
