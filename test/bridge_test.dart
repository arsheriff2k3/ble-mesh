import 'dart:convert';
import 'dart:typed_data';

import 'package:ble_mesh_chat/ble_mesh_chat.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_nostr_relay.dart';
import 'test_chat_transport.dart';

const relayOne = 'wss://one.example';
const relayTwo = 'wss://two.example';
const openPolicy = BridgePolicy(allowMetered: true, allowRoaming: true);

/// Opt-in gateways between the BLE mesh and Nostr relays.
void main() {
  late FakeRelayNetwork network;

  setUp(() {
    network = FakeRelayNetwork()
      ..add(relayOne)
      ..add(relayTwo);
  });

  Future<_Node> node(
    String name, {
    TestChatTransport? local,
    List<String> relays = const [],
    bool consent = false,
    BridgePolicy? gateway,
    Duration lifetime = const Duration(hours: 1),
  }) async {
    final keys = await ChatKeyPair.generate();
    final created = _Node(
      name: name,
      keys: keys,
      local: local,
      nostr: relays.isEmpty
          ? null
          : NostrChatTransport(
              identity: ChatIdentity(peerId: keys.peerId, displayName: name),
              relays: relays,
              connector: network.connect,
              okTimeout: const Duration(seconds: 1),
              minimumReconnectDelay: const Duration(milliseconds: 10),
              maximumReconnectDelay: const Duration(milliseconds: 40),
            ),
      consent: consent,
      gateway: gateway,
      lifetime: lifetime,
    );
    addTearDown(created.dispose);
    return created;
  }

  void introduce(_Node a, _Node b) {
    a.security.trustStore.observe(b.keys.peerId, b.keys.publicKeys);
    b.security.trustStore.observe(a.keys.peerId, a.keys.publicKeys);
  }

  /// Events on [relay] carrying packet [packetId].
  Iterable<NostrEvent> eventsFor(String relay, String packetId) => network
      .relays[relay]!
      .stored
      .where((event) => event.tag('d') == packetId);

  group('the exit criterion', () {
    test('an offline client reaches an online client through a gateway, '
        'and the ACK comes back', () async {
      final c = await node('c', local: TestChatTransport('c'), consent: true);
      final a = await node(
        'a',
        local: TestChatTransport('a'),
        relays: const [relayOne, relayTwo],
        gateway: openPolicy,
      );
      final x = await node(
        'x',
        relays: const [relayOne, relayTwo],
        consent: true,
      );
      introduce(c, x);
      a.local!.connect(c.local!);
      await Future.wait([c.start(), a.start(), x.start()]);

      final sent = await c.chat.sendDirect(
        peerId: x.keys.peerId,
        text: 'from the dead zone',
      );
      await eventually(
        () => c.statesOf(sent.id).contains(MessageState.delivered),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(x.received.map((message) => message.text), ['from the dead zone']);
      // The packet id survived the crossing, so relays hold the same id.
      expect(eventsFor(relayOne, sent.id), hasLength(1));
      expect(a.chat.bridgeStatus.bridgedPackets, 2, reason: 'message + ACK');
    });

    test('an online client reaches an offline client through a gateway, '
        'shown once despite two relays', () async {
      final c = await node('c', local: TestChatTransport('c'), consent: true);
      final a = await node(
        'a',
        local: TestChatTransport('a'),
        relays: const [relayOne, relayTwo],
        gateway: openPolicy,
      );
      final x = await node(
        'x',
        relays: const [relayOne, relayTwo],
        consent: true,
      );
      introduce(c, x);
      a.local!.connect(c.local!);
      await Future.wait([c.start(), a.start(), x.start()]);
      await eventually(() => a.chat.bridgeStatus.bridgedPeers == 1);

      final sent = await x.chat.sendDirect(
        peerId: c.keys.peerId,
        text: 'reaching into the mesh',
      );
      await eventually(
        () => x.statesOf(sent.id).contains(MessageState.delivered),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(c.received.map((message) => message.text), [
        'reaching into the mesh',
      ]);
      expect(a.nostr!.bridgedPeers, {c.keys.peerId});
    });
  });

  test('two gateways and a BLE loop deliver once and stop', () async {
    final c = await node('c', local: TestChatTransport('c'), consent: true);
    final a = await node(
      'a',
      local: TestChatTransport('a'),
      relays: const [relayOne, relayTwo],
      gateway: openPolicy,
    );
    final b = await node(
      'b',
      local: TestChatTransport('b'),
      relays: const [relayOne, relayTwo],
      gateway: openPolicy,
    );
    final x = await node(
      'x',
      relays: const [relayOne, relayTwo],
      consent: true,
    );
    introduce(c, x);
    a.local!
      ..connect(c.local!)
      ..connect(b.local!);
    b.local!.connect(c.local!);
    await Future.wait([c.start(), a.start(), b.start(), x.start()]);
    await eventually(
      () =>
          a.chat.bridgeStatus.bridgedPeers == 1 &&
          b.chat.bridgeStatus.bridgedPeers == 1,
    );

    final out = await c.chat.sendDirect(peerId: x.keys.peerId, text: 'out');
    final back = await x.chat.sendDirect(peerId: c.keys.peerId, text: 'back');
    await eventually(
      () =>
          c.statesOf(out.id).contains(MessageState.delivered) &&
          x.statesOf(back.id).contains(MessageState.delivered),
    );
    final storedAfterDelivery = network.relays[relayOne]!.stored.length;
    await Future<void>.delayed(const Duration(milliseconds: 600));

    expect(x.received.map((message) => message.text), ['out']);
    expect(c.received.map((message) => message.text), ['back']);
    expect(
      network.relays[relayOne]!.stored.length,
      storedAfterDelivery,
      reason: 'nothing keeps circulating after delivery',
    );
    // Each gateway carried each packet across at most once.
    for (final gateway in [a, b]) {
      expect(gateway.chat.bridgeStatus.bridgedPackets, lessThanOrEqualTo(4));
    }
    // C's message: one event per gateway at most, one id throughout, and
    // every crossing cost a hop.
    final published = eventsFor(relayOne, out.id).toList();
    expect(published.length, inInclusiveRange(1, 2));
    const codec = ChatPacketCodec();
    for (final event in published) {
      final packet = codec.decode(base64.decode(event.content));
      expect(packet.id, out.id);
      expect(packet.ttl, lessThan(5));
    }
  });

  test('without the sender\'s consent nothing reaches a relay', () async {
    final c = await node('c', local: TestChatTransport('c'));
    final a = await node(
      'a',
      local: TestChatTransport('a'),
      relays: const [relayOne],
      gateway: openPolicy,
    );
    final x = await node('x', relays: const [relayOne]);
    introduce(c, x);
    a.local!.connect(c.local!);
    await Future.wait([c.start(), a.start(), x.start()]);

    final sent = await c.chat.sendDirect(peerId: x.keys.peerId, text: 'local');
    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(eventsFor(relayOne, sent.id), isEmpty);
    expect(x.received, isEmpty);
    expect(a.chat.bridgeStatus.bridgedPeers, 0, reason: 'c never registered');
  });

  test(
    'a device that is not a gateway publishes nothing and says why',
    () async {
      final c = await node('c', local: TestChatTransport('c'), consent: true);
      final a = await node(
        'a',
        local: TestChatTransport('a'),
        relays: const [relayOne],
      );
      final x = await node('x', relays: const [relayOne]);
      introduce(c, x);
      a.local!.connect(c.local!);
      await Future.wait([c.start(), a.start(), x.start()]);

      final sent = await c.chat.sendDirect(peerId: x.keys.peerId, text: 'no');
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(eventsFor(relayOne, sent.id), isEmpty);
      expect(a.chat.bridgeStatus.active, isFalse);
      expect(a.chat.bridgeStatus.reason, BridgeInactiveReason.disabled);
      expect(a.nostr!.bridgedPeers, isEmpty);
    },
  );

  test('metered and roaming rules hold until an allowed connection '
      'appears', () async {
    final c = await node('c', local: TestChatTransport('c'), consent: true);
    final a = await node(
      'a',
      local: TestChatTransport('a'),
      relays: const [relayOne],
      gateway: const BridgePolicy(),
    );
    final x = await node('x', relays: const [relayOne], consent: true);
    introduce(c, x);
    a.local!.connect(c.local!);
    await Future.wait([c.start(), a.start(), x.start()]);
    final statuses = <BridgeStatus>[];
    a.chat.bridgeStatusChanges.listen(statuses.add);

    expect(
      a.chat.bridgeStatus.reason,
      BridgeInactiveReason.networkConditionsUnknown,
    );
    final sent = await c.chat.sendDirect(peerId: x.keys.peerId, text: 'wait');
    a.chat.updateNetworkConditions(
      const NetworkConditions(metered: true, roaming: false),
    );
    expect(a.chat.bridgeStatus.reason, BridgeInactiveReason.metered);
    a.chat.updateNetworkConditions(
      const NetworkConditions(metered: false, roaming: true),
    );
    expect(a.chat.bridgeStatus.reason, BridgeInactiveReason.roaming);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(eventsFor(relayOne, sent.id), isEmpty);

    a.chat.updateNetworkConditions(
      const NetworkConditions(metered: false, roaming: false),
    );
    expect(a.chat.bridgeStatus.active, isTrue);
    // C keeps retrying until acknowledged; the next retry crosses.
    await eventually(
      () => c.statesOf(sent.id).contains(MessageState.delivered),
    );
    expect(x.received.map((message) => message.text), ['wait']);
    expect(
      statuses.map((status) => status.reason),
      containsAllInOrder([
        BridgeInactiveReason.metered,
        BridgeInactiveReason.roaming,
        null,
      ]),
    );
  });

  test('an expired backlog is never published', () async {
    final c = await node(
      'c',
      local: TestChatTransport('c'),
      consent: true,
      lifetime: const Duration(milliseconds: 400),
    );
    final a = await node(
      'a',
      local: TestChatTransport('a'),
      relays: const [relayOne],
      gateway: openPolicy,
    );
    final x = await node('x', relays: const [relayOne]);
    introduce(c, x);
    network.relays[relayOne]!.goOffline();
    a.local!.connect(c.local!);
    await Future.wait([c.start(), a.start(), x.start()]);
    expect(a.chat.bridgeStatus.reason, BridgeInactiveReason.relaysUnavailable);

    final sent = await c.chat.sendDirect(peerId: x.keys.peerId, text: 'stale');
    await eventually(() => c.statesOf(sent.id).contains(MessageState.failed));
    network.relays[relayOne]!.goOnline();
    await eventually(() => a.chat.bridgeStatus.active);
    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(eventsFor(relayOne, sent.id), isEmpty);
    expect(x.received, isEmpty);
  });

  test('a replacement gateway continues the backlog without the first '
      'one', () async {
    const deadRelay = 'wss://dead.example';
    network.add(deadRelay).goOffline();
    final c = await node('c', local: TestChatTransport('c'), consent: true);
    final a = await node(
      'a',
      local: TestChatTransport('a'),
      relays: const [deadRelay],
      gateway: openPolicy,
    );
    final b = await node(
      'b',
      local: TestChatTransport('b'),
      relays: const [relayOne],
      gateway: openPolicy,
    );
    final x = await node('x', relays: const [relayOne], consent: true);
    introduce(c, x);
    a.local!.connect(c.local!);
    await Future.wait([c.start(), a.start(), b.start(), x.start()]);

    final first = await c.chat.sendDirect(peerId: x.keys.peerId, text: 'one');
    final second = await c.chat.sendDirect(peerId: x.keys.peerId, text: 'two');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(x.received, isEmpty, reason: 'a cannot reach any relay');

    a.local!.disconnect(c.local!);
    b.local!.connect(c.local!);
    await eventually(
      () =>
          c.statesOf(first.id).contains(MessageState.delivered) &&
          c.statesOf(second.id).contains(MessageState.delivered),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(x.received.map((message) => message.text).toList()..sort(), [
      'one',
      'two',
    ]);
  });

  test('a stranger cannot use a gateway to reach an offline device', () async {
    final c = await node('c', local: TestChatTransport('c'), consent: true);
    final a = await node(
      'a',
      local: TestChatTransport('a'),
      relays: const [relayOne],
      gateway: openPolicy,
    );
    final stranger = await node('s', relays: const [relayOne], consent: true);
    // The stranger learned c's code; c never added the stranger.
    stranger.security.trustStore.observe(c.keys.peerId, c.keys.publicKeys);
    a.local!.connect(c.local!);
    await Future.wait([c.start(), a.start(), stranger.start()]);
    await eventually(() => a.chat.bridgeStatus.bridgedPeers == 1);

    await stranger.chat.sendDirect(peerId: c.keys.peerId, text: 'spam');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(c.received, isEmpty);
  });

  test('gateways cap how many offline devices they subscribe for', () async {
    final c1 = await node('c1', local: TestChatTransport('c1'), consent: true);
    final c2 = await node('c2', local: TestChatTransport('c2'), consent: true);
    final a = await node(
      'a',
      local: TestChatTransport('a'),
      relays: const [relayOne],
      gateway: const BridgePolicy(
        allowMetered: true,
        allowRoaming: true,
        maximumRoutes: 1,
      ),
    );
    a.local!
      ..connect(c1.local!)
      ..connect(c2.local!);
    await Future.wait([c1.start(), c2.start(), a.start()]);
    await eventually(() => a.chat.bridgeStatus.bridgedPeers == 1);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(a.nostr!.bridgedPeers, hasLength(1));
  });

  test('an online device does not register with gateways', () async {
    final c = await node(
      'c',
      local: TestChatTransport('c'),
      relays: const [relayOne],
      consent: true,
    );
    final a = await node(
      'a',
      local: TestChatTransport('a'),
      relays: const [relayOne],
      gateway: openPolicy,
    );
    a.local!.connect(c.local!);
    await Future.wait([c.start(), a.start()]);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(
      c.local!.sentPackets.where(
        (packet) => packet.type == ChatPacketType.bridgeRegistration,
      ),
      isEmpty,
    );
    expect(a.chat.bridgeStatus.bridgedPeers, 0);
  });

  group('the consent flag', () {
    test('cannot be added by a relay', () async {
      final keys = await ChatKeyPair.generate();
      final now = DateTime.now();
      final packet = await PacketSecurity(identity: keys).protect(
        ChatPacket(
          type: ChatPacketType.message,
          packetId: createPacketId(),
          senderId: keys.peerId,
          destination: 'p:peer-somebody',
          ttl: 4,
          createdAt: now,
          expiresAt: now.add(const Duration(minutes: 5)),
          payload: Uint8List.fromList(utf8.encode('private')),
        ),
        encrypt: false,
      );
      final upgraded = ChatPacket(
        type: packet.type,
        packetId: packet.packetId,
        senderId: packet.senderId,
        destination: packet.destination,
        ttl: packet.ttl,
        createdAt: packet.createdAt,
        expiresAt: packet.expiresAt,
        payload: packet.payload,
        signature: packet.signature,
        senderKeys: packet.senderKeys,
        bridgeable: true,
      );
      final verifier = PacketSecurity(identity: await ChatKeyPair.generate());
      expect(
        await verifier.verifyForRelay(packet, senderKeys: keys.publicKeys),
        isTrue,
      );
      expect(
        await verifier.verifyForRelay(upgraded, senderKeys: keys.publicKeys),
        isFalse,
      );
    });

    test('survives the codec and leaves other packets unchanged', () async {
      const codec = ChatPacketCodec();
      final now = DateTime.utc(2026, 9, 24);
      ChatPacket build({required bool bridgeable}) => ChatPacket(
        type: ChatPacketType.message,
        packetId: Uint8List(16),
        senderId: 's',
        destination: 'p:d',
        ttl: 3,
        createdAt: now,
        expiresAt: now.add(const Duration(minutes: 1)),
        payload: Uint8List.fromList([1, 2, 3]),
        bridgeable: bridgeable,
      );
      final plain = build(bridgeable: false);
      final consented = build(bridgeable: true);
      expect(codec.decode(codec.encode(consented)).bridgeable, isTrue);
      expect(codec.decode(codec.encode(plain)).bridgeable, isFalse);
      // Flag bits live in byte 5; only bit 2 differs.
      expect(codec.encode(consented)[5] ^ codec.encode(plain)[5], 0x04);
      expect(plain.signingInput[5], 0, reason: 'unchanged for old packets');
      expect(consented.signingInput[5], 2);
    });

    test('the Nostr transport refuses to bridge without it', () async {
      final gateway = await node('g', relays: const [relayOne]);
      await gateway.start();
      final origin = await ChatKeyPair.generate();
      final now = DateTime.now();
      Future<ChatPacket> packet({
        required bool bridgeable,
        String destination = 'p:peer-elsewhere',
        Duration lifetime = const Duration(minutes: 5),
      }) => PacketSecurity(identity: origin).protect(
        ChatPacket(
          type: ChatPacketType.message,
          packetId: createPacketId(),
          senderId: origin.peerId,
          destination: destination,
          ttl: 4,
          createdAt: now,
          expiresAt: now.add(lifetime),
          payload: Uint8List.fromList([1]),
          bridgeable: bridgeable,
        ),
        encrypt: false,
      );

      final refused = [
        await packet(bridgeable: false),
        await packet(bridgeable: true, destination: 'c:general'),
        await packet(bridgeable: true, lifetime: Duration.zero),
      ];
      for (final item in refused) {
        expect((await gateway.nostr!.bridge(item)).attemptedRoutes, 0);
      }
      expect(network.relays[relayOne]!.stored, isEmpty);
      expect(
        (await gateway.nostr!.bridge(await packet(bridgeable: true))).sent,
        isTrue,
      );
    });
  });
}

class _Node {
  _Node({
    required this.name,
    required this.keys,
    required this.local,
    required this.nostr,
    required bool consent,
    required BridgePolicy? gateway,
    required Duration lifetime,
  }) : security = PacketSecurity(identity: keys) {
    chat = BleMeshChat(
      security: security,
      maximumRelayJitter: Duration.zero,
      minimumRelaySpacing: Duration.zero,
      retryBackoff: const Duration(milliseconds: 100),
      maximumRetryBackoff: const Duration(milliseconds: 200),
      messageLifetime: lifetime,
      bridgeConsent: consent,
      bridgePolicy: gateway,
      bridgeRegistrationInterval: const Duration(milliseconds: 400),
    );
  }

  final String name;
  final ChatKeyPair keys;
  final PacketSecurity security;
  final TestChatTransport? local;
  final NostrChatTransport? nostr;
  late final BleMeshChat chat;
  final List<ChatMessage> received = [];
  final Map<String, List<MessageState>> states = {};
  bool _started = false;

  List<MessageState> statesOf(String id) => states[id] ?? const [];

  Future<void> start() async {
    _started = true;
    chat.messages.where((message) => !message.isLocal).listen(received.add);
    chat.messageStates.listen(
      (change) =>
          states.putIfAbsent(change.messageId, () => []).add(change.state),
    );
    await chat.initialize(
      identity: ChatIdentity(peerId: keys.peerId, displayName: name),
      transports: [?local, ?nostr],
    );
  }

  Future<void> dispose() async {
    if (_started) {
      await chat.dispose();
    } else {
      await nostr?.dispose();
    }
    await local?.dispose();
  }
}

Future<void> eventually(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
