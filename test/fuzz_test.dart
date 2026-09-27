import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:ble_mesh_chat/ble_mesh_chat.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_ble_platform_api.dart';
import 'fake_nostr_relay.dart';
import 'test_chat_transport.dart';

/// Randomised hostile input against every parser that sees untrusted bytes.
///
/// Automated fuzzing is cheap for an attacker; these checks make sure it is
/// run here first. Each parser may only fail with its typed format error,
/// and the stream it feeds must keep working afterwards. Seeds are fixed so
/// a failure reproduces.
void main() {
  const iterations = 3000;

  Uint8List randomBytes(Random random, int maximum) => Uint8List.fromList(
    List<int>.generate(random.nextInt(maximum + 1), (_) => random.nextInt(256)),
  );

  /// Bit flips, truncation, extension, and splices of a valid encoding.
  Uint8List mutate(Random random, Uint8List valid) {
    final bytes = Uint8List.fromList(valid);
    switch (random.nextInt(5)) {
      case 0:
        for (var i = 0; i < 1 + random.nextInt(4); i++) {
          bytes[random.nextInt(bytes.length)] ^= 1 << random.nextInt(8);
        }
        return bytes;
      case 1:
        return Uint8List.sublistView(bytes, 0, random.nextInt(bytes.length));
      case 2:
        return Uint8List.fromList([...bytes, ...randomBytes(random, 64)]);
      case 3:
        final at = random.nextInt(bytes.length);
        for (var index = at; index < bytes.length; index++) {
          bytes[index] = random.nextInt(256);
        }
        return bytes;
      default:
        // Rewrite a length field region with extreme values.
        final at = 36 + random.nextInt(8).clamp(0, bytes.length - 37);
        if (at < bytes.length) bytes[at] = random.nextBool() ? 0xff : 0;
        return bytes;
    }
  }

  Future<ChatPacket> validPacket({String destination = 'c:general'}) async {
    final keys = await ChatKeyPair.generate();
    final now = DateTime.now();
    return PacketSecurity(identity: keys).protect(
      ChatPacket(
        type: ChatPacketType.message,
        packetId: createPacketId(),
        senderId: keys.peerId,
        destination: destination,
        ttl: 4,
        createdAt: now,
        expiresAt: now.add(const Duration(minutes: 10)),
        payload: Uint8List.fromList(utf8.encode('fuzz baseline')),
      ),
      encrypt: false,
    );
  }

  test('the packet codec only fails with typed errors', () async {
    final random = Random(1);
    const codec = ChatPacketCodec();
    final valid = codec.encode(await validPacket());
    for (var i = 0; i < iterations; i++) {
      final input = i.isEven ? randomBytes(random, 256) : mutate(random, valid);
      try {
        final decoded = codec.decode(input);
        // Anything that decodes must re-encode to the same bytes.
        expect(codec.encode(decoded), input, reason: 'iteration $i');
      } on FormatException {
        // Expected for hostile input.
      }
    }
  });

  test('reassembly only fails with typed errors and never exceeds its '
      'size limit', () {
    final random = Random(2);
    final reassembler = PacketReassembler(
      maxPacketSize: 4096,
      maxAssemblies: 8,
    );
    for (var i = 0; i < iterations * 3; i++) {
      final frame = randomBytes(random, 64);
      if (frame.length >= 12 && random.nextBool()) {
        // Make most frames pass the header check so the state machine,
        // not just the magic-number test, gets exercised.
        final data = ByteData.sublistView(frame)
          ..setUint16(0, 0xb17e)
          ..setUint8(2, 1)
          ..setUint32(4, random.nextInt(4));
        data.setUint16(10, 1 + random.nextInt(random.nextBool() ? 4 : 0xffff));
        data.setUint16(8, random.nextInt(data.getUint16(10) + 1));
      }
      try {
        final result = reassembler.add('route-${random.nextInt(3)}', frame);
        if (result != null) {
          expect(result.length, lessThanOrEqualTo(4096));
        }
      } on FragmentFormatException {
        // Expected for hostile input.
      }
    }
  });

  test('Nostr event parsing only fails with typed errors', () {
    final random = Random(3);
    Object? randomJson(int depth) {
      switch (random.nextInt(depth > 3 ? 5 : 7)) {
        case 0:
          return null;
        case 1:
          return random.nextInt(1 << 32) - (1 << 31);
        case 2:
          return random.nextDouble();
        case 3:
          return String.fromCharCodes(
            List.generate(random.nextInt(80), (_) => random.nextInt(0x3000)),
          );
        case 4:
          return random.nextBool();
        case 5:
          return [
            for (var i = 0; i < random.nextInt(6); i++) randomJson(depth + 1),
          ];
        default:
          return {
            for (final key in const [
              'id',
              'pubkey',
              'created_at',
              'kind',
              'tags',
              'content',
              'sig',
            ])
              if (random.nextInt(4) > 0) key: randomJson(depth + 1),
          };
      }
    }

    final valid = NostrEvent.sign(
      keys: NostrKeyPair.generate(Random(4)),
      kind: 30078,
      tags: const [
        ['d', 'x'],
      ],
      content: 'c',
      createdAt: DateTime.utc(2026),
    ).toJson();
    for (var i = 0; i < iterations; i++) {
      final Object? input;
      if (i.isEven) {
        input = randomJson(0);
      } else {
        final keys = valid.keys.toList();
        input = {...valid, keys[random.nextInt(keys.length)]: randomJson(2)};
      }
      try {
        final event = NostrEvent.fromJson(input);
        // Parsed garbage must still fail verification, not throw.
        event.verify();
      } on NostrEventFormatException {
        // Expected for hostile input.
      }
    }
  });

  test('contact codes only fail with typed errors', () {
    final random = Random(5);
    for (var i = 0; i < iterations; i++) {
      final body = base64Url.encode(randomBytes(random, 80));
      final code = random.nextBool()
          ? 'blemesh1:$body'
          : String.fromCharCodes(
              List.generate(random.nextInt(120), (_) => random.nextInt(0x250)),
            );
      try {
        ChatPublicKeys.fromContactCode(code);
      } on FormatException {
        // Expected for hostile input.
      }
    }
  });

  test('the router survives hostile packets and still delivers', () async {
    final random = Random(6);
    final local = await ChatKeyPair.generate();
    final transport = TestChatTransport('local');
    final neighbor = TestChatTransport('neighbor');
    transport.connect(neighbor);
    final chat = BleMeshChat(
      security: PacketSecurity(identity: local),
      maximumRelayJitter: Duration.zero,
      minimumRelaySpacing: Duration.zero,
      perRouteLimit: const InboundRateLimit(burst: 10000, perSecond: 1000),
    );
    addTearDown(() async {
      await chat.dispose();
      await transport.dispose();
      await neighbor.dispose();
    });
    await chat.initialize(
      identity: ChatIdentity(peerId: local.peerId, displayName: 'local'),
      transports: [transport],
    );
    final received = <String>[];
    chat.messages.listen((message) => received.add(message.text));

    const codec = ChatPacketCodec();
    final baseline = codec.encode(await validPacket());
    var injected = 0;
    for (var i = 0; i < 600; i++) {
      try {
        final packet = codec.decode(mutate(random, baseline));
        transport.inject(packet, from: neighbor);
        injected++;
      } on FormatException {
        continue;
      }
      if (i % 50 == 0) await pumpEventQueue();
    }
    await pumpEventQueue(times: 50);
    expect(injected, greaterThan(0));
    expect(received.where((text) => text != 'fuzz baseline'), isEmpty);

    transport.inject(await validPacket(), from: neighbor);
    await pumpEventQueue(times: 50);
    expect(received, contains('fuzz baseline'));
  });

  test(
    'the BLE transport survives hostile frames and still delivers',
    () async {
      final random = Random(7);
      final platform = FakeBlePlatformApi();
      final ble = BleMeshTransport(api: platform);
      final transport = BleChatTransport(
        identity: const ChatIdentity(peerId: 'local', displayName: 'Local'),
        transport: ble,
      );
      addTearDown(() async {
        await transport.dispose();
        await ble.dispose();
        await platform.close();
      });
      await transport.start();
      final incoming = <ChatPacket>[];
      transport.incoming.listen((packet) => incoming.add(packet.packet));
      platform.emitLinkUp('link');
      await pumpEventQueue();

      const codec = ChatPacketCodec();
      const fragmenter = PacketFragmenter();
      final baseline = await validPacket();
      final encoded = codec.encode(baseline);
      for (var i = 0; i < 1500; i++) {
        final mutated = mutate(random, encoded);
        // An empty packet cannot be fragmented; send a raw frame instead.
        final frames = i.isEven || mutated.isEmpty
            ? [randomBytes(random, 244)]
            : fragmenter.fragment(createPacketId(random), mutated, 64);
        for (final frame in frames) {
          platform.emitFrame('link', frame);
        }
        if (i % 100 == 0) await pumpEventQueue(times: 5);
      }
      await pumpEventQueue(times: 50);
      incoming.clear();

      for (final frame in fragmenter.fragment(baseline.packetId, encoded, 64)) {
        platform.emitFrame('link', frame);
      }
      await pumpEventQueue(times: 50);
      expect(incoming.map((packet) => packet.id), contains(baseline.id));
    },
  );

  test('the Nostr transport survives hostile relay messages', () async {
    final random = Random(8);
    final network = FakeRelayNetwork()..add('wss://fuzz.example');
    final keys = await ChatKeyPair.generate();
    final transport = NostrChatTransport(
      identity: ChatIdentity(peerId: keys.peerId, displayName: 'fuzz'),
      relays: const ['wss://fuzz.example'],
      connector: network.connect,
    );
    addTearDown(transport.dispose);
    await transport.start();
    await pumpEventQueue();
    final relay = network.relays['wss://fuzz.example']!;
    final shapes = <String Function()>[
      () => String.fromCharCodes(
        List.generate(random.nextInt(200), (_) => random.nextInt(0x800)),
      ),
      () => jsonEncode(['EVENT', 'unknown-sub', {}]),
      () => jsonEncode(['OK', random.nextInt(10), 'yes']),
      () => jsonEncode(['EOSE']),
      () => jsonEncode(['CLOSED']),
      () =>
          jsonEncode(['NOTICE', List.filled(random.nextInt(1000), 'x').join()]),
      () => jsonEncode([random.nextInt(5)]),
      () => '[' * random.nextInt(2000),
    ];
    for (var i = 0; i < iterations; i++) {
      relay.injectRaw(shapes[random.nextInt(shapes.length)]());
      if (i % 200 == 0) await pumpEventQueue();
    }
    for (var i = 0; i < 300; i++) {
      relay.injectEvent({
        'id': 'a' * 64,
        'pubkey': 'b' * 64,
        'created_at': random.nextInt(1 << 31),
        'kind': NostrChatTransport.defaultEventKind,
        'tags': [
          ['y', NostrChatTransport.routeKey('p:${keys.peerId}')],
          ['d', 'c' * 32],
        ],
        'content': base64.encode(randomBytes(random, 300)),
        'sig': 'd' * 128,
      });
    }
    await pumpEventQueue(times: 50);
    expect(transport.connectedRelays, [Uri.parse('wss://fuzz.example')]);
  });
}
