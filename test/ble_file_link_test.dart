import 'dart:typed_data';

import 'package:ble_mesh_chat/ble_mesh_chat.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ble_chat_transport_test.dart' show emitPacket;
import 'fake_ble_platform_api.dart';

void main() {
  late FakeBlePlatformApi platform;
  late BleMeshTransport ble;
  late BleChatTransport radio;
  late ChatKeyPair local;
  late ChatKeyPair bob;
  late ChatKeyPair carol;
  late PacketSecurity security;
  late List<ChatPeer> peers;

  List<ChatPacket> sent(String link) {
    final reassembler = PacketReassembler();
    final packets = <ChatPacket>[];
    for (final frame in platform.sent.where((f) => f.linkId == link)) {
      final bytes = reassembler.add(link, frame.frame);
      if (bytes != null) packets.add(const ChatPacketCodec().decode(bytes));
    }
    return packets;
  }

  Future<void> authenticate(String link, ChatKeyPair keys) async {
    platform.emitLinkUp(link);
    await pumpEventQueue(times: 20);
    final nonce = sent(
      link,
    ).singleWhere((p) => p.type == ChatPacketType.linkChallenge).payload;
    final now = DateTime.now();
    final response = await PacketSecurity(identity: keys).protect(
      ChatPacket(
        type: ChatPacketType.announce,
        packetId: createPacketId(),
        senderId: keys.peerId,
        destination: '*',
        ttl: 1,
        createdAt: now,
        expiresAt: now.add(const Duration(minutes: 1)),
        payload:
            (BytesBuilder()
                  ..add(keys.publicKeys.encode())
                  ..add(nonce)
                  ..add('Peer'.codeUnits))
                .toBytes(),
      ),
      encrypt: false,
    );
    emitPacket(platform, link, response);
    await pumpEventQueue(times: 50);
    expect(peers.any((p) => p.id == keys.peerId), isTrue);
  }

  Future<ChatPacket> filePacket(ChatKeyPair sender, String recipient) {
    final now = DateTime.now();
    return PacketSecurity(identity: sender).protect(
      ChatPacket(
        type: ChatPacketType.fileTransfer,
        packetId: createPacketId(),
        senderId: sender.peerId,
        destination: 'p:$recipient',
        ttl: 1,
        createdAt: now,
        expiresAt: now.add(const Duration(minutes: 1)),
        payload: Uint8List(4096),
      ),
      encrypt: true,
      recipient: recipient == local.peerId ? local.publicKeys : bob.publicKeys,
    );
  }

  setUp(() async {
    local = await ChatKeyPair.generate();
    bob = await ChatKeyPair.generate();
    carol = await ChatKeyPair.generate();
    security = PacketSecurity(identity: local);
    platform = FakeBlePlatformApi();
    ble = BleMeshTransport(api: platform);
    radio = BleChatTransport(
      identity: ChatIdentity(peerId: local.peerId, displayName: 'Local'),
      transport: ble,
      security: security,
    );
    peers = [];
    radio.peers.listen((value) => peers = value);
    await radio.start();
    await authenticate('bob-link', bob);
    await authenticate('carol-link', carol);
  });
  tearDown(() async {
    await radio.dispose();
    await ble.dispose();
    await platform.close();
  });

  test(
    'late native MTU refresh preserves authenticated identity and uses larger frames',
    () async {
      final old = ble.links['bob-link']!;
      platform.platformLinks = ble.links.values
          .map(
            (link) => BleLink(
              linkId: link.linkId,
              remoteId: link.remoteId,
              role: link.role,
              maxFrameSize: link.linkId == 'bob-link' ? 20 : link.maxFrameSize,
              rssi: link.rssi,
              connectedAtMs: link.connectedAtMs,
            ),
          )
          .toList();
      await ble.refreshLinks();
      platform.platformLinks = platform.platformLinks
          .map(
            (link) => BleLink(
              linkId: link.linkId,
              remoteId: link.remoteId,
              role: link.role,
              maxFrameSize: link.linkId == 'bob-link' ? 512 : link.maxFrameSize,
              rssi: link.rssi,
              connectedAtMs: link.connectedAtMs,
            ),
          )
          .toList();
      platform.sent.clear();
      final report = await radio.send(await filePacket(local, bob.peerId));
      expect(report.deliveredRoutes, 1);
      expect(ble.links[old.linkId]!.maxFrameSize, 512);
      expect(platform.sent.any((f) => f.frame.length > 20), isTrue);
      expect(peers.any((p) => p.id == bob.peerId), isTrue);
    },
  );

  test(
    'file fragments go only to the destination authenticated BLE link',
    () async {
      platform.sent.clear();
      final packet = await filePacket(local, bob.peerId);
      final report = await radio.send(packet);
      expect(report.deliveredRoutes, 1);
      expect(platform.sent.map((frame) => frame.linkId).toSet(), {'bob-link'});
      expect(platform.sent.length, greaterThan(10));
      expect(sent('bob-link').single.type, ChatPacketType.fileTransfer);
      expect(sent('bob-link').single.payload, packet.payload);
      final wrongRoute = await radio.send(packet, routeId: 'carol-link');
      expect(wrongRoute.deliveredRoutes, 0);
    },
  );

  test(
    'file packet origin must match its authenticated physical link',
    () async {
      final incoming = <ReceivedChatPacket>[];
      radio.incoming.listen(incoming.add);
      final packet = await filePacket(bob, local.peerId);
      emitPacket(platform, 'carol-link', packet);
      await pumpEventQueue(times: 30);
      expect(incoming, isEmpty);
      emitPacket(platform, 'bob-link', packet);
      await pumpEventQueue(times: 30);
      expect(incoming, hasLength(1));
      expect(incoming.single.packet.payload, packet.payload);
    },
  );

  test('file packet type is appended and survives wire-v3 codec', () async {
    expect(ChatPacketType.bridgeRegistration.index, 7);
    expect(ChatPacketType.fileTransfer.index, 8);
    final packet = await filePacket(local, bob.peerId);
    final decoded = const ChatPacketCodec().decode(
      const ChatPacketCodec().encode(packet),
    );
    expect(decoded.type, ChatPacketType.fileTransfer);
    expect(
      (await PacketSecurity(identity: bob).admit(decoded)).packet.payload,
      Uint8List(4096),
    );
  });
}
