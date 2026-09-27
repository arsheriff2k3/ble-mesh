import 'dart:convert';
import 'dart:typed_data';

import 'package:ble_mesh_chat/ble_mesh_chat.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const cipher = SealedMessageCipher();
  final aad = Uint8List.fromList(utf8.encode('header'));

  late ChatKeyPair alice;
  late ChatKeyPair bob;
  late ChatKeyPair mallory;

  setUp(() async {
    alice = await ChatKeyPair.generate();
    bob = await ChatKeyPair.generate();
    mallory = await ChatKeyPair.generate();
  });

  Future<Uint8List> sealFor(ChatKeyPair recipient, String text) =>
      cipher.encrypt(
        plaintext: Uint8List.fromList(utf8.encode(text)),
        recipient: recipient.publicKeys,
        associatedData: aad,
      );

  test('the intended recipient recovers the plaintext', () async {
    final sealed = await sealFor(bob, 'meet at the north gate');
    final opened = await cipher.decrypt(
      sealed: sealed,
      self: bob,
      associatedData: aad,
    );
    expect(utf8.decode(opened), 'meet at the north gate');
  });

  test('a different recipient cannot decrypt it', () async {
    final sealed = await sealFor(bob, 'for bob only');
    await expectLater(
      cipher.decrypt(sealed: sealed, self: mallory, associatedData: aad),
      throwsA(isA<MessageSecurityException>()),
    );
  });

  test('a relay sees no plaintext in the sealed bytes', () async {
    final sealed = await sealFor(bob, 'north gate');
    expect(utf8.decode(sealed, allowMalformed: true), isNot(contains('north')));
  });

  test('tampering with any ciphertext byte is rejected', () async {
    final sealed = await sealFor(bob, 'original text');
    for (final index in [76, sealed.length - 1]) {
      final tampered = Uint8List.fromList(sealed)..[index] ^= 0xff;
      await expectLater(
        cipher.decrypt(sealed: tampered, self: bob, associatedData: aad),
        throwsA(isA<MessageSecurityException>()),
        reason: 'byte $index must be authenticated',
      );
    }
  });

  test('tampering with the mac is rejected', () async {
    final sealed = await sealFor(bob, 'original text');
    final tampered = Uint8List.fromList(sealed)..[60] ^= 0x01;
    await expectLater(
      cipher.decrypt(sealed: tampered, self: bob, associatedData: aad),
      throwsA(isA<MessageSecurityException>()),
    );
  });

  test('swapping the ephemeral key is rejected', () async {
    final sealed = await sealFor(bob, 'original text');
    final other = await sealFor(bob, 'other text');
    final swapped = Uint8List.fromList(sealed);
    swapped.setRange(0, 32, other.sublist(0, 32));
    await expectLater(
      cipher.decrypt(sealed: swapped, self: bob, associatedData: aad),
      throwsA(isA<MessageSecurityException>()),
    );
  });

  test('changing the associated data breaks authentication', () async {
    final sealed = await sealFor(bob, 'bound to its header');
    await expectLater(
      cipher.decrypt(
        sealed: sealed,
        self: bob,
        associatedData: Uint8List.fromList(utf8.encode('different header')),
      ),
      throwsA(isA<MessageSecurityException>()),
    );
  });

  test('two encryptions of the same text differ', () async {
    final first = await sealFor(bob, 'same');
    final second = await sealFor(bob, 'same');
    expect(first, isNot(equals(second)));
    // Specifically, the ephemeral key is fresh each time.
    expect(first.sublist(0, 32), isNot(equals(second.sublist(0, 32))));
  });

  test('a truncated payload is rejected rather than crashing', () async {
    final sealed = await sealFor(bob, 'complete');
    for (final length in [0, 10, 71, sealed.length - 1]) {
      await expectLater(
        cipher.decrypt(
          sealed: Uint8List.sublistView(sealed, 0, length),
          self: bob,
          associatedData: aad,
        ),
        throwsA(isA<MessageSecurityException>()),
      );
    }
  });

  test('peer ids are derived from the signing key, not chosen', () async {
    expect(alice.peerId, startsWith('peer-'));
    expect(alice.peerId, hasLength(21));
    expect(alice.peerId, isNot(bob.peerId));

    // The same key material always yields the same id.
    final seeds = await alice.extractSeeds();
    final restored = await ChatKeyPair.fromPrivateBytes(
      signingSeed: seeds.signing,
      agreementSeed: seeds.agreement,
    );
    expect(restored.peerId, alice.peerId);
    expect(restored.publicKeys.signing, alice.publicKeys.signing);
  });

  test('an identity restored from seeds can still decrypt', () async {
    final sealed = await sealFor(bob, 'after a reinstall');
    final seeds = await bob.extractSeeds();
    final restored = await ChatKeyPair.fromPrivateBytes(
      signingSeed: seeds.signing,
      agreementSeed: seeds.agreement,
    );
    final opened = await cipher.decrypt(
      sealed: sealed,
      self: restored,
      associatedData: aad,
    );
    expect(utf8.decode(opened), 'after a reinstall');
  });

  test('public keys round-trip through the wire encoding', () async {
    final encoded = alice.publicKeys.encode();
    expect(encoded, hasLength(64));
    final decoded = ChatPublicKeys.decode(encoded);
    expect(decoded.peerId, alice.peerId);
    expect(decoded, alice.publicKeys);
  });

  test('safety numbers match on both sides and change on rotation', () async {
    final number = ChatPublicKeys.safetyNumber(
      alice.publicKeys,
      bob.publicKeys,
    );
    expect(number, matches(RegExp(r'^\d{5}( \d{5}){11}$')));
    expect(
      ChatPublicKeys.safetyNumber(bob.publicKeys, alice.publicKeys),
      number,
    );
    final rotated = await alice.rotateAgreementKey();
    expect(
      ChatPublicKeys.safetyNumber(rotated.publicKeys, bob.publicKeys),
      isNot(number),
    );
  });

  test('public keys round-trip through a contact code', () async {
    final code = alice.publicKeys.toContactCode();
    expect(code, startsWith('blemesh1:'));
    expect(ChatPublicKeys.fromContactCode('  $code\n'), alice.publicKeys);
    expect(
      () => ChatPublicKeys.fromContactCode(code.substring(0, code.length - 4)),
      throwsFormatException,
    );
    expect(
      () => ChatPublicKeys.fromContactCode('other:${code.substring(9)}'),
      throwsFormatException,
    );
  });
}
