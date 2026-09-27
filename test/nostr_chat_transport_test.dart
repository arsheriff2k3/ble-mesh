import 'dart:convert';
import 'dart:typed_data';

import 'package:ble_mesh_chat/ble_mesh_chat.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_nostr_relay.dart';
import 'test_chat_transport.dart';

const relayOne = 'wss://one.example';
const relayTwo = 'wss://two.example';

/// Online delivery through Nostr relays.
void main() {
  late FakeRelayNetwork network;

  setUp(() {
    network = FakeRelayNetwork()
      ..add(relayOne)
      ..add(relayTwo);
  });

  Future<_Peer> peer(
    String name, {
    List<String> relays = const [relayOne, relayTwo],
    List<ChatTransport> extra = const [],
    bool start = true,
  }) async {
    final keys = await ChatKeyPair.generate();
    final created = _Peer(
      name: name,
      keys: keys,
      security: PacketSecurity(identity: keys),
      nostr: NostrChatTransport(
        identity: ChatIdentity(peerId: keys.peerId, displayName: name),
        relays: relays,
        connector: network.connect,
        okTimeout: const Duration(seconds: 1),
        minimumReconnectDelay: const Duration(milliseconds: 10),
        maximumReconnectDelay: const Duration(milliseconds: 40),
        keepAliveInterval: const Duration(milliseconds: 100),
        keepAliveTimeout: const Duration(milliseconds: 100),
      ),
      extra: extra,
    );
    addTearDown(created.dispose);
    if (start) await created.start();
    return created;
  }

  void introduce(_Peer a, _Peer b) {
    a.security.trustStore.observe(b.keys.peerId, b.keys.publicKeys);
    b.security.trustStore.observe(a.keys.peerId, a.keys.publicKeys);
  }

  test('two clients exchange an encrypted direct message online', () async {
    final alice = await peer('alice');
    final bob = await peer('bob');
    introduce(alice, bob);

    final sent = await alice.chat.sendDirect(
      peerId: bob.keys.peerId,
      text: 'hello over the internet',
    );
    await eventually(
      () => alice.statesOf(sent.id).contains(MessageState.delivered),
    );
    // Give the second relay's copy time to arrive.
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(bob.received.map((message) => message.text), [
      'hello over the internet',
    ]);
    expect(bob.received.single.threadId, alice.keys.peerId);
    expect(
      alice.statesOf(sent.id),
      containsAllInOrder([
        MessageState.sending,
        MessageState.sent,
        MessageState.delivered,
      ]),
    );
    // Each relay holds the message and the ACK, and neither reveals the text.
    for (final relay in network.relays.values) {
      expect(relay.stored, hasLength(2));
      for (final event in relay.stored) {
        expect(
          utf8.decode(base64.decode(event.content), allowMalformed: true),
          isNot(contains('hello over the internet')),
        );
      }
    }
    // Envelope keys are per packet, so relays cannot link the two events.
    final pubkeys = network.relays[relayOne]!.stored.map((e) => e.pubkey);
    expect(pubkeys.toSet(), hasLength(2));
  });

  test('relay acceptance is not delivery', () async {
    final alice = await peer('alice');
    final bob = await peer('bob', start: false);
    introduce(alice, bob);

    final sent = await alice.chat.sendDirect(
      peerId: bob.keys.peerId,
      text: 'while you were away',
    );
    await eventually(() => alice.statesOf(sent.id).contains(MessageState.sent));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(alice.statesOf(sent.id), isNot(contains(MessageState.delivered)));

    // Bob comes online later and finds the stored event through backfill.
    await bob.start();
    await eventually(
      () => alice.statesOf(sent.id).contains(MessageState.delivered),
    );
    expect(bob.received.map((message) => message.text), [
      'while you were away',
    ]);
  });

  test('a relay outage falls over to the other relay and reconnects', () async {
    final alice = await peer('alice');
    final bob = await peer('bob');
    introduce(alice, bob);
    final one = network.relays[relayOne]!;

    one.goOffline();
    await eventually(() => alice.nostr.connectedRelays.length == 1);
    final sent = await alice.chat.sendDirect(
      peerId: bob.keys.peerId,
      text: 'via the second relay',
    );
    await eventually(
      () => alice.statesOf(sent.id).contains(MessageState.delivered),
    );
    expect(one.stored, isEmpty);

    final attempts = one.connectionCount;
    one.goOnline();
    await eventually(() => alice.nostr.connectedRelays.length == 2);
    await eventually(() => bob.nostr.connectedRelays.length == 2);
    expect(one.connectionCount, greaterThan(attempts));
  });

  test(
    'messages queue while every relay is down and send when one returns',
    () async {
      final alice = await peer('alice');
      final bob = await peer('bob');
      introduce(alice, bob);
      for (final relay in network.relays.values) {
        relay.goOffline();
      }
      await eventually(() => !alice.nostr.available && !bob.nostr.available);

      final sent = await alice.chat.sendDirect(
        peerId: bob.keys.peerId,
        text: 'queued until a relay returns',
      );
      await pumpEventQueue();
      expect(alice.statesOf(sent.id), contains(MessageState.queued));

      network.relays[relayTwo]!.goOnline();
      await eventually(
        () => alice.statesOf(sent.id).contains(MessageState.delivered),
      );
      expect(bob.received.map((message) => message.text), [
        'queued until a relay returns',
      ]);
    },
  );

  test('a retry republishes the same event instead of a new one', () async {
    final alice = await peer('alice');
    final bob = await peer('bob', start: false);
    introduce(alice, bob);

    await alice.chat.sendDirect(peerId: bob.keys.peerId, text: 'once');
    // Several retry intervals pass without an acknowledgement.
    await Future<void>.delayed(const Duration(milliseconds: 600));

    for (final relay in network.relays.values) {
      expect(relay.stored, hasLength(1));
    }
  });

  test('duplicate and replayed events are shown once', () async {
    final alice = await peer('alice');
    final bob = await peer('bob');
    introduce(alice, bob);
    final packet = await alice.directPacket(bob, 'say it once');
    final event = envelope(packet).toJson();

    for (final relay in network.relays.values) {
      relay
        ..injectEvent(event)
        ..injectEvent(event);
    }
    await eventually(() => bob.received.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(bob.received, hasLength(1));
  });

  test(
    'invalid events are rejected without disrupting the subscription',
    () async {
      final alice = await peer('alice');
      final bob = await peer('bob', relays: const [relayOne]);
      introduce(alice, bob);
      final relay = network.relays[relayOne]!;
      final errors = <Object>[];
      bob.nostr.errors.listen(errors.add);

      final good = await alice.directPacket(bob, 'the valid one');
      final other = await peer('carol', relays: const [relayTwo]);
      final expired = await alice.directPacket(
        bob,
        'too late',
        lifetime: const Duration(milliseconds: 1),
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final unsigned = ChatPacket(
        type: ChatPacketType.message,
        packetId: createPacketId(),
        senderId: alice.keys.peerId,
        destination: 'p:${bob.keys.peerId}',
        ttl: 5,
        createdAt: DateTime.now(),
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
        payload: Uint8List.fromList(utf8.encode('unsigned')),
      );
      final valid = envelope(good);
      final tamperedSig = valid.toJson()
        ..['sig'] =
            '${valid.sig.startsWith('0') ? '1' : '0'}${valid.sig.substring(1)}';
      final tamperedContent = valid.toJson()
        ..['content'] = base64.encode(utf8.encode('rewritten'));

      final hostile = <Object?>[
        tamperedSig,
        tamperedContent,
        envelope(good, kind: 1).toJson(),
        envelope(good, omitPacketTag: true).toJson(),
        envelope(good, packetTag: packetIdToHex(createPacketId())).toJson(),
        envelope(
          good,
          route: NostrChatTransport.routeKey('p:${other.keys.peerId}'),
        ).toJson(),
        envelope(good, content: 'A' * 60000).toJson(),
        envelope(good, content: '!!not base64!!').toJson(),
        envelope(unsigned).toJson(),
        envelope(expired).toJson(),
        envelope(await alice.directPacket(other, 'for carol')).toJson(),
        {'id': 'garbage'},
      ];
      for (final event in hostile) {
        relay.injectEvent(event);
      }
      relay
        ..injectRaw('not json')
        ..injectRaw('{"an":"object"}')
        ..injectRaw(jsonEncode(['NOTICE', 'relay says hi']));
      relay.injectEvent(valid.toJson());

      await eventually(() => bob.received.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(bob.received.map((message) => message.text), ['the valid one']);
      expect(bob.nostr.connectedRelays, [Uri.parse(relayOne)]);
      // Every hostile input except the silently dropped expired packet is
      // reported.
      expect(errors.length, greaterThanOrEqualTo(hostile.length + 2));
    },
  );

  test('only direct packets this device originated are published', () async {
    final alice = await peer('alice');
    final bob = await peer('bob');
    final now = DateTime.now();
    final channel = await alice.security.protect(
      ChatPacket(
        type: ChatPacketType.message,
        packetId: createPacketId(),
        senderId: alice.keys.peerId,
        destination: 'c:general',
        ttl: 5,
        createdAt: now,
        expiresAt: now.add(const Duration(hours: 1)),
        payload: Uint8List.fromList(utf8.encode('public channel')),
      ),
      encrypt: false,
    );
    introduce(alice, bob);
    final someoneElses = await bob.directPacket(alice, 'bob to alice');

    final channelResult = await alice.nostr.send(channel);
    final relayed = await alice.nostr.send(someoneElses);

    expect(channelResult.attemptedRoutes, 0);
    expect(relayed.attemptedRoutes, 0);
    for (final relay in network.relays.values) {
      expect(relay.stored, isEmpty);
    }
  });

  test('a nearby BLE peer is reached without publishing to relays', () async {
    final aliceBle = TestChatTransport('alice');
    final bobBle = TestChatTransport('bob');
    addTearDown(() async {
      await aliceBle.dispose();
      await bobBle.dispose();
    });
    final alice = await peer('alice', extra: [aliceBle]);
    final bob = await peer('bob', extra: [bobBle]);
    introduce(alice, bob);
    aliceBle.connect(bobBle);
    aliceBle.announcePeers([
      ChatPeer(
        id: bob.keys.peerId,
        displayName: 'bob',
        transportId: aliceBle.id,
        publicKeys: bob.keys.publicKeys,
      ),
    ]);
    await pumpEventQueue();

    final sent = await alice.chat.sendDirect(
      peerId: bob.keys.peerId,
      text: 'right next to you',
    );
    await eventually(
      () => alice.statesOf(sent.id).contains(MessageState.delivered),
    );

    expect(bob.received.map((message) => message.text), ['right next to you']);
    for (final relay in network.relays.values) {
      expect(relay.stored, isEmpty, reason: 'the ACK also stays on BLE');
    }
  });

  test(
    'a retry falls back to relays when the nearby peer never answers',
    () async {
      final aliceBle = TestChatTransport('alice');
      final silent = TestChatTransport('silent');
      addTearDown(() async {
        await aliceBle.dispose();
        await silent.dispose();
      });
      final alice = await peer('alice', extra: [aliceBle]);
      final bob = await peer('bob');
      introduce(alice, bob);
      // BLE claims bob is nearby, but the link goes somewhere that never ACKs.
      aliceBle.connect(silent);
      aliceBle.announcePeers([
        ChatPeer(
          id: bob.keys.peerId,
          displayName: 'bob',
          transportId: aliceBle.id,
          publicKeys: bob.keys.publicKeys,
        ),
      ]);
      await pumpEventQueue();

      final sent = await alice.chat.sendDirect(
        peerId: bob.keys.peerId,
        text: 'find me online',
      );
      expect(network.relays[relayOne]!.stored, isEmpty);
      await eventually(
        () => alice.statesOf(sent.id).contains(MessageState.delivered),
      );
      expect(bob.received.map((message) => message.text), ['find me online']);
    },
  );

  test('packets relayed over BLE are not bridged to Nostr', () async {
    // Alice and carol use a relay bob does not, so anything on bob's relays
    // could only have come from bob.
    const elsewhere = 'wss://elsewhere.example';
    network.add(elsewhere);
    final aliceBle = TestChatTransport('alice');
    final bobBle = TestChatTransport('bob');
    final carolBle = TestChatTransport('carol');
    addTearDown(() async {
      await aliceBle.dispose();
      await bobBle.dispose();
      await carolBle.dispose();
    });
    final alice = await peer(
      'alice',
      relays: const [elsewhere],
      extra: [aliceBle],
    );
    final bob = await peer('bob', extra: [bobBle]);
    final carol = await peer(
      'carol',
      relays: const [elsewhere],
      extra: [carolBle],
    );
    introduce(alice, carol);
    aliceBle.connect(bobBle);
    bobBle.connect(carolBle);

    await alice.chat.sendDirect(peerId: carol.keys.peerId, text: 'through bob');
    await eventually(() => carol.received.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(
      bobBle.sentPackets.where(
        (packet) => packet.senderId == alice.keys.peerId,
      ),
      isNotEmpty,
      reason: 'bob relays over BLE',
    );
    expect(bob.received, isEmpty);
    for (final url in [relayOne, relayTwo]) {
      expect(
        network.relays[url]!.stored,
        isEmpty,
        reason: 'bob must not publish packets he only relayed',
      );
    }
  });

  test('strangers cannot reach you online until they are a contact', () async {
    final alice = await peer('alice');
    final bob = await peer('bob');
    final errors = <Object>[];
    bob.chat.errors.listen(errors.add);
    // Bob pinned nobody, but alice knows bob's code.
    alice.security.trustStore.observe(bob.keys.peerId, bob.keys.publicKeys);

    final sent = await alice.chat.sendDirect(
      peerId: bob.keys.peerId,
      text: 'unsolicited',
    );
    await eventually(() => alice.statesOf(sent.id).contains(MessageState.sent));
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(bob.received, isEmpty);
    expect(alice.statesOf(sent.id), isNot(contains(MessageState.delivered)));
    expect(
      bob.security.trustStore.keysFor(alice.keys.peerId),
      isNull,
      reason: 'a stranger is not pinned by trying',
    );
    expect(errors.whereType<UnknownSenderException>(), isNotEmpty);
  });

  test('a silently dead relay connection is detected and recovered', () async {
    final alice = await peer('alice', relays: const [relayOne]);
    final bob = await peer('bob', relays: const [relayOne]);
    introduce(alice, bob);
    final relay = network.relays[relayOne]!;
    final connectionsBefore = relay.connectionCount;

    // Bob's connection goes quiet without closing, as behind a hotspot NAT.
    // Everything published meanwhile is stored on the relay but never pushed
    // to bob.
    relay.stallOpenConnections();
    final sent = await alice.chat.sendDirect(
      peerId: bob.keys.peerId,
      text: 'sent while bob looked connected',
    );

    // The keep-alive notices, reconnects, and backfill brings it in; the
    // acknowledgement then reaches alice.
    await eventually(
      () => alice.statesOf(sent.id).contains(MessageState.delivered),
    );
    expect(bob.received.map((message) => message.text), [
      'sent while bob looked connected',
    ]);
    expect(relay.connectionCount, greaterThan(connectionsBefore));
  });

  test('relays can be added and removed without restarting', () async {
    final alice = await peer('alice', relays: const []);
    final bob = await peer('bob', relays: const [relayTwo]);
    introduce(alice, bob);
    expect(alice.nostr.available, isFalse);

    // Queued while alice has no relay at all.
    final sent = await alice.chat.sendDirect(
      peerId: bob.keys.peerId,
      text: 'configured later',
    );
    await pumpEventQueue();
    expect(alice.statesOf(sent.id), contains(MessageState.queued));

    await alice.nostr.setRelays(const [relayTwo]);
    await eventually(
      () => alice.statesOf(sent.id).contains(MessageState.delivered),
    );
    expect(bob.received.map((message) => message.text), ['configured later']);

    // Switching relays keeps working, and removed relays are closed.
    await alice.nostr.setRelays(const [relayOne]);
    await bob.nostr.setRelays(const [relayOne]);
    expect(alice.nostr.relays, [Uri.parse(relayOne)]);
    final second = await alice.chat.sendDirect(
      peerId: bob.keys.peerId,
      text: 'after switching relays',
    );
    await eventually(
      () => alice.statesOf(second.id).contains(MessageState.delivered),
    );
    expect(
      network.relays[relayTwo]!.stored.where(
        (event) => event.tag('d') == second.id,
      ),
      isEmpty,
    );
  });

  test('an invalid relay list leaves the current relays in place', () async {
    final alice = await peer('alice', relays: const [relayOne]);
    await expectLater(
      alice.nostr.setRelays(const ['ws://insecure.example']),
      throwsArgumentError,
    );
    expect(alice.nostr.relays, [Uri.parse(relayOne)]);
    expect(alice.nostr.connectedRelays, [Uri.parse(relayOne)]);
  });

  test('reconnecting after a long outage waits at most 30 seconds', () {
    final transport = NostrChatTransport(
      identity: const ChatIdentity(peerId: 'peer-x', displayName: 'x'),
      relays: const [relayOne],
    );
    expect(transport.maximumReconnectDelay, const Duration(seconds: 30));
  });

  test('switching between BLE and relays needs no restart', () async {
    final aliceBle = TestChatTransport('alice');
    final bobBle = TestChatTransport('bob');
    addTearDown(() async {
      await aliceBle.dispose();
      await bobBle.dispose();
    });
    final alice = await peer(
      'alice',
      relays: const [relayOne],
      extra: [aliceBle],
    );
    final bob = await peer('bob', relays: const [relayOne], extra: [bobBle]);
    introduce(alice, bob);
    final relay = network.relays[relayOne]!;
    Future<void> deliver(String text) async {
      final sent = await alice.chat.sendDirect(
        peerId: bob.keys.peerId,
        text: text,
      );
      await eventually(
        () => alice.statesOf(sent.id).contains(MessageState.delivered),
      );
    }

    // 1. Nearby, no internet: Bluetooth only.
    relay.goOffline();
    aliceBle.connect(bobBle);
    await deliver('over bluetooth');

    // 2. Walk apart, internet returns: relays only.
    aliceBle.disconnect(bobBle);
    relay.goOnline();
    await deliver('over the relay');

    // 3. Back together, internet lost again: Bluetooth only.
    relay.goOffline();
    aliceBle.connect(bobBle);
    await deliver('bluetooth again');

    // 4. Apart again with internet.
    aliceBle.disconnect(bobBle);
    relay.goOnline();
    await deliver('relay again');

    expect(bob.received.map((message) => message.text), [
      'over bluetooth',
      'over the relay',
      'bluetooth again',
      'relay again',
    ]);
  });

  test('relay URLs must be secure unless explicitly allowed', () {
    ChatIdentity identity() =>
        const ChatIdentity(peerId: 'peer-x', displayName: 'x');
    expect(
      NostrChatTransport(identity: identity(), relays: const []).available,
      isFalse,
      reason: 'no relays means idle, not an error',
    );
    expect(
      () => NostrChatTransport(
        identity: identity(),
        relays: const ['ws://plain.example'],
      ),
      throwsArgumentError,
    );
    expect(
      () => NostrChatTransport(
        identity: identity(),
        relays: const ['https://not-a-socket.example'],
      ),
      throwsArgumentError,
    );
    expect(
      NostrChatTransport(
        identity: identity(),
        relays: const ['ws://localhost:7000'],
        allowInsecureRelays: true,
      ).id,
      'nostr',
    );
  });
}

class _Peer {
  _Peer({
    required this.name,
    required this.keys,
    required this.security,
    required this.nostr,
    required this.extra,
  }) : chat = BleMeshChat(
         security: security,
         maximumRelayJitter: Duration.zero,
         minimumRelaySpacing: Duration.zero,
         retryBackoff: const Duration(milliseconds: 100),
         maximumRetryBackoff: const Duration(milliseconds: 200),
       );

  final String name;
  final ChatKeyPair keys;
  final PacketSecurity security;
  final NostrChatTransport nostr;
  final List<ChatTransport> extra;
  final BleMeshChat chat;
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
      transports: [...extra, nostr],
    );
  }

  /// A signed, sealed direct packet from this peer to [to], built outside
  /// the facade so tests can wrap it in hand-made events.
  Future<ChatPacket> directPacket(
    _Peer to,
    String text, {
    Duration lifetime = const Duration(hours: 1),
  }) {
    final now = DateTime.now();
    return security.protect(
      ChatPacket(
        type: ChatPacketType.message,
        packetId: createPacketId(),
        senderId: keys.peerId,
        destination: 'p:${to.keys.peerId}',
        ttl: 5,
        createdAt: now,
        expiresAt: now.add(lifetime),
        payload: Uint8List.fromList(utf8.encode(text)),
      ),
      encrypt: true,
      recipient: to.keys.publicKeys,
    );
  }

  Future<void> dispose() async {
    if (_started) {
      await chat.dispose();
    } else {
      await nostr.dispose();
    }
  }
}

/// Wraps [packet] in a Nostr event the way [NostrChatTransport] does, with
/// knobs for building malformed variants.
NostrEvent envelope(
  ChatPacket packet, {
  int kind = NostrChatTransport.defaultEventKind,
  String? route,
  String? packetTag,
  bool omitPacketTag = false,
  String? content,
}) => NostrEvent.sign(
  keys: NostrKeyPair.generate(),
  kind: kind,
  tags: [
    if (!omitPacketTag) ['d', packetTag ?? packet.id],
    [
      NostrChatTransport.routeTag,
      route ?? NostrChatTransport.routeKey(packet.destination),
    ],
  ],
  content: content ?? base64.encode(const ChatPacketCodec().encode(packet)),
  createdAt: DateTime.now(),
);

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
