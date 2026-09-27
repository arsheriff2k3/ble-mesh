import 'package:ble_mesh_chat/ble_mesh_chat.dart';
import 'package:ble_mesh_chat/src/chat/nostr/bip340.dart';
import 'package:flutter_test/flutter_test.dart';

/// The outer Nostr envelope.
void main() {
  test('BIP-340 vector 0 signs and verifies as published', () {
    const secret =
        '0000000000000000000000000000000000000000000000000000000000000003';
    const zero =
        '0000000000000000000000000000000000000000000000000000000000000000';
    const signature =
        'e907831f80848d1069a5371b402410364bdf1c5f8307b0084c55f1ce2dca8215'
        '25f66a4a85ea8b71e482a74f382d2ce5ebeee8fdb2172f477df4900d310536c0';
    final keys = NostrKeyPair.fromPrivateKeyHex(secret);
    expect(
      keys.publicKeyHex,
      'f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9',
    );
    expect(bip340Sign(secret, zero, zero).toLowerCase(), signature);
    expect(bip340Verify(keys.publicKeyHex, zero, signature), isTrue);
  });

  test('BIP-340 vector 1 signs and verifies as published', () {
    const secret =
        'b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef';
    const message =
        '243f6a8885a308d313198a2e03707344a4093822299f31d0082efa98ec4e6c89';
    const aux =
        '0000000000000000000000000000000000000000000000000000000000000001';
    const signature =
        '6896bd60eeae296db48a229ff71dfe071bde413e6d43f917dc8dcf8c78de3341'
        '8906d11ac976abccb20b091292bff4ea897efcb639ea871cfa95f6de339e4b0a';
    const publicKey =
        'dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659';
    expect(bip340PublicKey(secret), publicKey);
    expect(bip340Sign(secret, message, aux), signature);
    expect(bip340Verify(publicKey, message, signature), isTrue);
    expect(bip340Verify(publicKey, aux, signature), isFalse);
  });

  test('BIP-340 verification rejects malformed input without throwing', () {
    const key =
        'dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659';
    final message = '0' * 64;
    for (final (pub, sig) in [
      (key, 'zz' * 64),
      (key, '0' * 127),
      ('f' * 64, '0' * 128),
      (key, 'f' * 128),
      ('', ''),
    ]) {
      expect(bip340Verify(pub, message, sig), isFalse, reason: '$pub $sig');
    }
  });

  test('a signed event verifies and survives JSON', () {
    final event = NostrEvent.sign(
      keys: NostrKeyPair.generate(),
      kind: 30078,
      tags: [
        ['d', 'abc'],
      ],
      content: 'payload',
      createdAt: DateTime.utc(2026, 9, 24),
    );
    expect(event.verify(), isTrue);
    final parsed = NostrEvent.fromJson(event.toJson());
    expect(parsed.verify(), isTrue);
    expect(parsed.tag('d'), 'abc');
  });

  test('changing any signed field breaks verification', () {
    final event = NostrEvent.sign(
      keys: NostrKeyPair.generate(),
      kind: 30078,
      tags: [
        ['d', 'abc'],
      ],
      content: 'payload',
      createdAt: DateTime.utc(2026, 9, 24),
    );
    NostrEvent copy({
      String? pubkey,
      int? createdAt,
      int? kind,
      List<List<String>>? tags,
      String? content,
      String? sig,
    }) => NostrEvent(
      id: event.id,
      pubkey: pubkey ?? event.pubkey,
      createdAt: createdAt ?? event.createdAt,
      kind: kind ?? event.kind,
      tags: tags ?? event.tags,
      content: content ?? event.content,
      sig: sig ?? event.sig,
    );

    expect(copy(content: 'other').verify(), isFalse);
    expect(copy(kind: 1).verify(), isFalse);
    expect(copy(createdAt: event.createdAt + 1).verify(), isFalse);
    expect(
      copy(
        tags: [
          ['d', 'xyz'],
        ],
      ).verify(),
      isFalse,
    );
    expect(
      copy(pubkey: NostrKeyPair.generate().publicKeyHex).verify(),
      isFalse,
    );
    final flipped = event.sig.startsWith('0') ? '1' : '0';
    expect(copy(sig: '$flipped${event.sig.substring(1)}').verify(), isFalse);
  });

  test('malformed event JSON is a typed error, not a crash', () {
    final valid = NostrEvent.sign(
      keys: NostrKeyPair.generate(),
      kind: 1,
      tags: const [],
      content: '',
      createdAt: DateTime.utc(2026),
    ).toJson();
    final cases = <Object?>[
      null,
      'event',
      <String, Object?>{},
      {...valid, 'id': 'not-hex'},
      {...valid, 'pubkey': 42},
      {...valid, 'sig': valid['id']},
      {...valid, 'created_at': -1},
      {...valid, 'kind': '1'},
      {...valid, 'content': null},
      {
        ...valid,
        'tags': [
          [1, 2],
        ],
      },
      {
        ...valid,
        'tags': ['d'],
      },
    ];
    for (final json in cases) {
      expect(
        () => NostrEvent.fromJson(json),
        throwsA(isA<NostrEventFormatException>()),
        reason: '$json',
      );
    }
  });

  test('private keys outside the curve order are refused', () {
    expect(() => NostrKeyPair.fromPrivateKeyHex('0' * 64), throwsArgumentError);
    expect(() => NostrKeyPair.fromPrivateKeyHex('f' * 64), throwsArgumentError);
    expect(() => NostrKeyPair.fromPrivateKeyHex('abc'), throwsArgumentError);
  });
}
