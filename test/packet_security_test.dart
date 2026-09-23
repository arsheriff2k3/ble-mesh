import 'dart:convert';
import 'dart:typed_data';

import 'package:ble_mesh/ble_mesh.dart';
import 'package:flutter_test/flutter_test.dart';

/// Phase 3: everything a relay or an impostor might try against a packet.
void main() {
  late ChatKeyPair alice;
  late ChatKeyPair bob;
  late ChatKeyPair mallory;
  late PacketSecurity aliceSide;
  late PacketSecurity bobSide;
  late DateTime now;

  setUp(() async {
    alice = await ChatKeyPair.generate();
    bob = await ChatKeyPair.generate();
    mallory = await ChatKeyPair.generate();
    aliceSide = PacketSecurity(identity: alice);
    bobSide = PacketSecurity(identity: bob);
    now = DateTime.utc(2026, 5, 1, 9);
  });

  ChatPacket plainPacket({
    required String sender,
    required String destination,
    String text = 'hello',
  }) => ChatPacket(
    type: ChatPacketType.message,
    packetId: createPacketId(),
    senderId: sender,
    destination: destination,
    ttl: 4,
    createdAt: now,
    expiresAt: now.add(const Duration(hours: 1)),
    payload: Uint8List.fromList(utf8.encode(text)),
  );

  Future<ChatPacket> aliceToBob([String text = 'private words']) =>
      aliceSide.protect(
        plainPacket(
          sender: alice.peerId,
          destination: 'p:${bob.peerId}',
          text: text,
        ),
        encrypt: true,
        recipient: bob.publicKeys,
      );

  test('bob opens a direct message alice sealed for him', () async {
    final packet = await aliceToBob('meet at nine');
    final verified = await bobSide.admit(
      packet,
      announcedKeys: alice.publicKeys,
    );
    expect(utf8.decode(verified.packet.payload), 'meet at nine');
    expect(verified.trust, PeerTrust.firstContact);
  });

  test('a relay can authenticate the packet but not read it', () async {
    final packet = await aliceToBob('north gate at dusk');
    final relay = PacketSecurity(identity: mallory);

    // The relay proves it is genuine so it can forward it...
    expect(
      await relay.verifyForRelay(packet, senderKeys: alice.publicKeys),
      isTrue,
    );
    // ...but the content is not available to it.
    expect(
      utf8.decode(packet.payload, allowMalformed: true),
      isNot(contains('north gate')),
    );
    await expectLater(
      relay.admit(packet, announcedKeys: alice.publicKeys),
      throwsA(isA<MessageSecurityException>()),
    );
  });

  test('a tampered payload fails before it can be relayed', () async {
    final packet = await aliceToBob();
    final tampered = ChatPacket(
      type: packet.type,
      packetId: packet.packetId,
      senderId: packet.senderId,
      destination: packet.destination,
      ttl: packet.ttl,
      createdAt: packet.createdAt,
      expiresAt: packet.expiresAt,
      payload: Uint8List.fromList(packet.payload)..[5] ^= 0xff,
      signature: packet.signature,
      isSealed: true,
    );
    expect(
      await PacketSecurity(
        identity: mallory,
      ).verifyForRelay(tampered, senderKeys: alice.publicKeys),
      isFalse,
    );
  });

  test('a relay cannot redirect a packet to itself', () async {
    final packet = await aliceToBob();
    final redirected = ChatPacket(
      type: packet.type,
      packetId: packet.packetId,
      senderId: packet.senderId,
      destination: 'p:${mallory.peerId}',
      ttl: packet.ttl,
      createdAt: packet.createdAt,
      expiresAt: packet.expiresAt,
      payload: packet.payload,
      signature: packet.signature,
      isSealed: true,
    );
    expect(
      await PacketSecurity(
        identity: mallory,
      ).verifyForRelay(redirected, senderKeys: alice.publicKeys),
      isFalse,
      reason: 'destination is covered by the signature',
    );
  });

  test('a relay cannot extend the expiry to keep a packet alive', () async {
    final packet = await aliceToBob();
    final extended = ChatPacket(
      type: packet.type,
      packetId: packet.packetId,
      senderId: packet.senderId,
      destination: packet.destination,
      ttl: packet.ttl,
      createdAt: packet.createdAt,
      expiresAt: packet.expiresAt.add(const Duration(days: 30)),
      payload: packet.payload,
      signature: packet.signature,
      isSealed: true,
    );
    expect(
      await PacketSecurity(
        identity: mallory,
      ).verifyForRelay(extended, senderKeys: alice.publicKeys),
      isFalse,
    );
  });

  test('decrementing TTL does not invalidate the signature', () async {
    final packet = await aliceToBob('still valid three hops later');
    var forwarded = packet;
    for (var hop = 0; hop < 3; hop++) {
      forwarded = forwarded.withTtl(forwarded.ttl - 1);
    }
    expect(forwarded.ttl, packet.ttl - 3);
    final verified = await bobSide.admit(
      forwarded,
      announcedKeys: alice.publicKeys,
    );
    expect(utf8.decode(verified.packet.payload), 'still valid three hops later');
  });

  test('an unsigned packet is refused', () async {
    final unsigned = plainPacket(
      sender: alice.peerId,
      destination: 'p:${bob.peerId}',
    );
    await expectLater(
      bobSide.admit(unsigned, announcedKeys: alice.publicKeys),
      throwsA(isA<MessageSecurityException>()),
    );
  });

  test('a packet signed by the wrong key is refused', () async {
    // Mallory signs but claims to be alice.
    final forged = await PacketSecurity(identity: mallory).protect(
      plainPacket(sender: alice.peerId, destination: 'c:general'),
      encrypt: false,
    );
    await expectLater(
      bobSide.admit(forged, announcedKeys: alice.publicKeys),
      throwsA(isA<MessageSecurityException>()),
    );
  });

  test('a chosen sender id that does not match the key is refused', () async {
    final forged = await PacketSecurity(
      identity: mallory,
    ).protect(plainPacket(sender: 'peer-9950', destination: 'c:general'),
        encrypt: false);
    await expectLater(
      bobSide.admit(forged, announcedKeys: mallory.publicKeys),
      throwsA(isA<MessageSecurityException>()),
    );
  });

  test('a sender we have never heard announce is refused', () async {
    final packet = await aliceToBob();
    await expectLater(
      bobSide.admit(packet),
      throwsA(isA<MessageSecurityException>()),
    );
  });

  test('a key change for a pinned peer is refused, not adopted', () async {
    await bobSide.admit(await aliceToBob(), announcedKeys: alice.publicKeys);
    expect(bobSide.trustStore.classify(alice.peerId, alice.publicKeys),
        PeerTrust.known);

    // Somebody presents different keys under the same peer id.
    final impostorKeys = ChatPublicKeys(
      signing: mallory.publicKeys.signing,
      agreement: mallory.publicKeys.agreement,
    );
    expect(
      bobSide.trustStore.classify(alice.peerId, impostorKeys),
      PeerTrust.changed,
    );
  });

  test('an approved rotation replaces the pinned key', () async {
    await bobSide.admit(await aliceToBob(), announcedKeys: alice.publicKeys);
    final rotated = await ChatKeyPair.generate();

    bobSide.trustStore.acceptRotation(alice.peerId, rotated.publicKeys);
    expect(
      bobSide.trustStore.classify(alice.peerId, rotated.publicKeys),
      PeerTrust.known,
    );
    expect(
      bobSide.trustStore.classify(alice.peerId, alice.publicKeys),
      PeerTrust.changed,
      reason: 'the old key must stop being trusted',
    );
  });

  test('sending a direct message to an unknown key fails loudly', () async {
    await expectLater(
      aliceSide.protect(
        plainPacket(sender: alice.peerId, destination: 'p:${bob.peerId}'),
        encrypt: true,
      ),
      throwsA(isA<MessageSecurityException>()),
      reason: 'never silently downgrade to plaintext',
    );
  });

  test('a signed packet survives the codec round trip', () async {
    const codec = ChatPacketCodec();
    final packet = await aliceToBob('through the wire');
    final decoded = codec.decode(codec.encode(packet));

    expect(decoded.signature, packet.signature);
    expect(decoded.isSealed, isTrue);
    final verified = await bobSide.admit(
      decoded,
      announcedKeys: alice.publicKeys,
    );
    expect(utf8.decode(verified.packet.payload), 'through the wire');
  });

  test('a replayed packet verifies but stays one message upstream', () async {
    // Signatures alone do not stop replay; the dedupe cache does. This
    // documents the division of responsibility.
    final packet = await aliceToBob('replay me');
    final cache = DedupeCache(clock: () => now);
    expect(cache.remember(packet.id, packet.expiresAt), isTrue);
    expect(cache.remember(packet.id, packet.expiresAt), isFalse);
  });
}
