import 'dart:convert';
import 'dart:io';

import 'package:ble_mesh_chat/ble_mesh_chat.dart';
import 'package:ble_mesh_chat/file_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_chat_transport.dart';

/// End to end: encryption through the full chat facade, including the
/// relay that must move a message it cannot read.
void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('ble_mesh_crypto');
  });

  tearDown(() => directory.deleteSync(recursive: true));

  Future<
    ({BleMeshChat chat, PacketSecurity security, ChatIdentity identity})
  >
  createNode(String name) async {
    final keys = await ChatKeyPair.generate();
    final security = PacketSecurity(identity: keys);
    return (
      chat: BleMeshChat(
        security: security,
        maximumRelayJitter: Duration.zero,
        minimumRelaySpacing: Duration.zero,
      ),
      security: security,
      identity: ChatIdentity(peerId: keys.peerId, displayName: name),
    );
  }

  test('A and C exchange an encrypted direct message through relay B',
      () async {
    final a = await createNode('A');
    final b = await createNode('B');
    final c = await createNode('C');

    final aTransport = TestChatTransport(a.identity.peerId);
    final bTransport = TestChatTransport(b.identity.peerId);
    final cTransport = TestChatTransport(c.identity.peerId);
    aTransport.connect(bTransport);
    bTransport.connect(cTransport);

    addTearDown(() async {
      await a.chat.dispose();
      await b.chat.dispose();
      await c.chat.dispose();
      await aTransport.dispose();
      await bTransport.dispose();
      await cTransport.dispose();
    });

    await a.chat.initialize(identity: a.identity, transports: [aTransport]);
    await b.chat.initialize(identity: b.identity, transports: [bTransport]);
    await c.chat.initialize(identity: c.identity, transports: [cTransport]);

    // The test transport does not exchange announcements, so pin keys the way
    // a real announcement would.
    a.security.trustStore.acceptRotation(
      c.identity.peerId,
      c.security.identity.publicKeys,
    );
    c.security.trustStore.acceptRotation(
      a.identity.peerId,
      a.security.identity.publicKeys,
    );
    b.security.trustStore
      ..acceptRotation(a.identity.peerId, a.security.identity.publicKeys)
      ..acceptRotation(c.identity.peerId, c.security.identity.publicKeys);

    final atC = <ChatMessage>[];
    final atB = <ChatMessage>[];
    final states = <MessageState>[];
    c.chat.messages.listen(atC.add);
    b.chat.messages.listen(atB.add);
    a.chat.messageStates.listen((change) => states.add(change.state));

    await a.chat.sendDirect(
      peerId: c.identity.peerId,
      text: 'north gate at dusk',
    );
    await pumpEventQueue(times: 40);

    expect(atC.map((message) => message.text), ['north gate at dusk']);
    expect(atB, isEmpty, reason: 'the relay must not open the conversation');
    expect(states, contains(MessageState.delivered));

    // What B actually forwarded never contained the plaintext.
    final relayed = bTransport.sentPackets.where(
      (packet) => packet.type == ChatPacketType.message,
    );
    expect(relayed, isNotEmpty);
    for (final packet in relayed) {
      expect(packet.isSealed, isTrue);
      expect(
        utf8.decode(packet.payload, allowMalformed: true),
        isNot(contains('north gate')),
      );
    }
  });

  test('an unsigned packet from a stranger is dropped', () async {
    final bob = await createNode('Bob');
    final transport = TestChatTransport(bob.identity.peerId);
    final neighbor = TestChatTransport('stranger');
    transport.connect(neighbor);
    addTearDown(() async {
      await bob.chat.dispose();
      await transport.dispose();
      await neighbor.dispose();
    });

    final errors = <Object>[];
    final received = <ChatMessage>[];
    bob.chat.errors.listen(errors.add);
    bob.chat.messages.listen(received.add);
    await bob.chat.initialize(
      identity: bob.identity,
      transports: [transport],
    );

    transport.inject(
      ChatPacket(
        type: ChatPacketType.message,
        packetId: createPacketId(),
        senderId: 'peer-0000000000000000',
        destination: 'c:general',
        ttl: 3,
        createdAt: DateTime.now(),
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
        payload: utf8.encode('trust me'),
      ),
      from: neighbor,
    );
    await pumpEventQueue(times: 10);

    expect(received, isEmpty);
    expect(errors.whereType<MessageSecurityException>(), isNotEmpty);
  });

  test('identity and pinned peers survive a restart', () async {
    final store = FileIdentityStore(directory: directory);
    final created = await loadOrCreateIdentity(store);

    final peer = await ChatKeyPair.generate();
    final trust = await store.loadTrust();
    trust.observe(peer.peerId, peer.publicKeys);
    await store.saveTrust(trust);

    // Second launch.
    final reopened = FileIdentityStore(directory: directory);
    final restored = await loadOrCreateIdentity(reopened);
    expect(restored.peerId, created.peerId);

    final restoredTrust = await reopened.loadTrust();
    expect(
      restoredTrust.classify(peer.peerId, peer.publicKeys),
      PeerTrust.known,
    );
  });

  test('a lost identity produces a new peer id, not the old one', () async {
    final store = FileIdentityStore(directory: directory);
    final original = await loadOrCreateIdentity(store);
    await store.erase();

    final replacement = await loadOrCreateIdentity(store);
    expect(replacement.peerId, isNot(original.peerId));
  });

  test('a peer that reinstalls is flagged as changed, not accepted', () async {
    final store = FileIdentityStore(directory: directory);
    final peer = await ChatKeyPair.generate();
    final trust = await store.loadTrust();
    trust.observe(peer.peerId, peer.publicKeys);

    // Same person, new install: different keys. Because the peer id is a key
    // fingerprint the id changes too, so the old id simply stops appearing —
    // presenting different keys under the old id is the attack, and it is
    // refused.
    final reinstalled = await ChatKeyPair.generate();
    expect(
      trust.classify(peer.peerId, reinstalled.publicKeys),
      PeerTrust.changed,
    );
  });
}
