import 'dart:convert';
import 'dart:typed_data';

import 'package:ble_mesh_chat/ble_mesh_chat.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_chat_transport.dart';

/// Floods and abuse that automated attackers can generate cheaply: signing
/// identities cost nothing, so "the packet is signed" is not a limit.
void main() {
  late ChatKeyPair local;
  late TestChatTransport transport;
  late TestChatTransport neighbor;

  setUp(() async {
    local = await ChatKeyPair.generate();
    transport = TestChatTransport('local');
    neighbor = TestChatTransport('neighbor');
    transport.connect(neighbor);
    addTearDown(() async {
      await transport.dispose();
      await neighbor.dispose();
    });
  });

  Future<BleMeshChat> start({
    MessageStore? store,
    InboundRateLimit? perSender,
    InboundRateLimit? perRoute,
    Set<String> contactsOnlyTransports = const {},
  }) async {
    final chat = BleMeshChat(
      security: PacketSecurity(identity: local),
      store: store,
      maximumRelayJitter: Duration.zero,
      minimumRelaySpacing: Duration.zero,
      perSenderLimit:
          perSender ?? const InboundRateLimit(burst: 100, perSecond: 2),
      perRouteLimit:
          perRoute ?? const InboundRateLimit(burst: 400, perSecond: 20),
      contactsOnlyTransports: contactsOnlyTransports,
    );
    addTearDown(chat.dispose);
    await chat.initialize(
      identity: ChatIdentity(peerId: local.peerId, displayName: 'local'),
      transports: [transport],
    );
    return chat;
  }

  Future<ChatPacket> signed(
    ChatKeyPair sender,
    String text, {
    String destination = 'c:general',
    DateTime? createdAt,
    DateTime? expiresAt,
  }) {
    final now = DateTime.now();
    return PacketSecurity(identity: sender).protect(
      ChatPacket(
        type: ChatPacketType.message,
        packetId: createPacketId(),
        senderId: sender.peerId,
        destination: destination,
        ttl: 3,
        createdAt: createdAt ?? now,
        expiresAt: expiresAt ?? now.add(const Duration(minutes: 30)),
        payload: Uint8List.fromList(utf8.encode(text)),
      ),
      encrypt: false,
    );
  }

  test('packets claiming a far-future expiry cannot exhaust replay '
      'protection', () async {
    final chat = await start(
      store: InMemoryMessageStore(maximumSeenPackets: 20),
    );
    final received = <String>[];
    chat.messages.listen((message) => received.add(message.text));

    final attacker = await ChatKeyPair.generate();
    for (var i = 0; i < 20; i++) {
      transport.inject(
        await signed(attacker, 'spam $i', expiresAt: DateTime.utc(2100)),
        from: neighbor,
      );
    }
    final honest = await ChatKeyPair.generate();
    transport.inject(await signed(honest, 'real message'), from: neighbor);
    await pumpEventQueue(times: 50);

    expect(received, contains('real message'));
    expect(received.where((text) => text.startsWith('spam')), isEmpty);
  });

  test('packets dated in the future are dropped', () async {
    final chat = await start();
    final received = <String>[];
    chat.messages.listen((message) => received.add(message.text));
    final sender = await ChatKeyPair.generate();
    final later = DateTime.now().add(const Duration(days: 1));

    transport.inject(
      await signed(
        sender,
        'from tomorrow',
        createdAt: later,
        expiresAt: later.add(const Duration(minutes: 5)),
      ),
      from: neighbor,
    );
    await pumpEventQueue(times: 20);
    expect(received, isEmpty);
  });

  test('one sender cannot flood past its budget, and others still get '
      'through', () async {
    final chat = await start(
      perSender: const InboundRateLimit(burst: 5, perSecond: 0.001),
    );
    final received = <String>[];
    chat.messages.listen((message) => received.add(message.text));

    final flooder = await ChatKeyPair.generate();
    for (var i = 0; i < 50; i++) {
      transport.inject(await signed(flooder, 'flood $i'), from: neighbor);
    }
    final honest = await ChatKeyPair.generate();
    transport.inject(await signed(honest, 'still heard'), from: neighbor);
    await pumpEventQueue(times: 100);

    expect(received.where((text) => text.startsWith('flood')), hasLength(5));
    expect(received, contains('still heard'));
    // Over-budget packets are not relayed either, so a flood stops here
    // instead of crossing the whole mesh.
    expect(
      neighbor.sentPackets,
      isEmpty,
      reason: 'the only neighbour is the arrival route',
    );
    final relayedFlood = transport.sentPackets.where(
      (packet) => packet.senderId == flooder.peerId,
    );
    expect(relayedFlood.length, lessThanOrEqualTo(5));
  });

  test('a swarm of fresh identities is bounded by the route budget', () async {
    final chat = await start(
      perRoute: const InboundRateLimit(burst: 10, perSecond: 0.001),
    );
    final received = <String>[];
    chat.messages.listen((message) => received.add(message.text));

    for (var i = 0; i < 40; i++) {
      final sybil = await ChatKeyPair.generate();
      transport.inject(await signed(sybil, 'sybil $i'), from: neighbor);
    }
    await pumpEventQueue(times: 100);
    expect(received.length, 10);
  });

  test(
    'contacts-only transports drop strangers without pinning them',
    () async {
      final chat = await start(contactsOnlyTransports: {transport.id});
      final received = <String>[];
      chat.messages.listen((message) => received.add(message.text));
      final errors = <Object>[];
      chat.errors.listen(errors.add);

      final stranger = await ChatKeyPair.generate();
      transport.inject(
        await PacketSecurity(identity: stranger).protect(
          ChatPacket(
            type: ChatPacketType.message,
            packetId: createPacketId(),
            senderId: stranger.peerId,
            destination: 'p:${local.peerId}',
            ttl: 3,
            createdAt: DateTime.now(),
            expiresAt: DateTime.now().add(const Duration(minutes: 5)),
            payload: Uint8List.fromList(utf8.encode('hi, click this')),
          ),
          encrypt: true,
          recipient: local.publicKeys,
        ),
        from: neighbor,
      );
      await pumpEventQueue(times: 20);

      expect(received, isEmpty);
      expect(
        transport.sentPackets.where(
          (packet) => packet.type == ChatPacketType.acknowledgement,
        ),
        isEmpty,
        reason: 'no ACK, so the stranger learns nothing',
      );
      expect(errors.whereType<UnknownSenderException>(), hasLength(1));
    },
  );
}
