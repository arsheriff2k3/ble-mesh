// BIP-340 Schnorr signatures over secp256k1.
//
// Adapted from package:bip340 0.3.1 (https://github.com/fiatjaf/dart-bip340),
// Copyright 2021 fiatjaf, MIT License; see THIRD_PARTY_NOTICES.md. The
// algorithm is unchanged. It is vendored so the code on the signing path is
// the code that was reviewed, instead of whatever a later release contains.
//
// Not constant-time: BigInt arithmetic leaks timing. It signs only
// single-use Nostr envelope keys, never a long-lived identity key.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashing;
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/secp256k1.dart';

final ECDomainParameters _curve = ECCurve_secp256k1();
final BigInt _fieldPrime = BigInt.parse(
  'fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f',
  radix: 16,
);
final _hex32 = RegExp(r'^[0-9a-fA-F]{64}$');
final _hex64 = RegExp(r'^[0-9a-fA-F]{128}$');

/// Order of the secp256k1 group.
BigInt get secp256k1Order => _curve.n;

/// X-only public key for a 32-byte private key, both in lowercase hex.
String bip340PublicKey(String privateKeyHex) {
  final secret = _scalar(privateKeyHex);
  return _hex(_bytes32(_multiply(_curve.G, secret).x!.toBigInteger()!));
}

/// Signs a 32-byte [messageHex] with [privateKeyHex], using 32 bytes of
/// fresh randomness [auxHex]. Returns the 64-byte signature in hex.
String bip340Sign(String privateKeyHex, String messageHex, String auxHex) {
  final message = _decode(messageHex, 32);
  final aux = _decode(auxHex, 32);
  final secret = _scalar(privateKeyHex);
  final point = _multiply(_curve.G, secret);
  final d = _isEven(point) ? secret : _curve.n - secret;
  final t = d ^ _toBig(_taggedHash('BIP0340/aux', aux));
  final pointX = _bytes32(point.x!.toBigInteger()!);
  final k0 =
      _toBig(
        _taggedHash('BIP0340/nonce', [..._bytes32(t), ...pointX, ...message]),
      ) %
      _curve.n;
  if (k0 == BigInt.zero) throw StateError('BIP-340 nonce is zero');
  final nonce = _multiply(_curve.G, k0);
  final k = _isEven(nonce) ? k0 : _curve.n - k0;
  final nonceX = _bytes32(nonce.x!.toBigInteger()!);
  final e = _challenge(nonceX, pointX, message);
  return _hex([...nonceX, ..._bytes32((k + e * d) % _curve.n)]);
}

/// Whether [signatureHex] is a valid BIP-340 signature of [messageHex]
/// under the x-only [publicKeyHex]. Malformed input returns false.
bool bip340Verify(String publicKeyHex, String messageHex, String signatureHex) {
  if (!_hex32.hasMatch(publicKeyHex) ||
      !_hex32.hasMatch(messageHex) ||
      !_hex64.hasMatch(signatureHex)) {
    return false;
  }
  final point = _liftX(BigInt.parse(publicKeyHex, radix: 16));
  if (point == null) return false;
  final message = _decode(messageHex, 32);
  final signature = _decode(signatureHex, 64);
  final r = _toBig(signature.sublist(0, 32));
  final s = _toBig(signature.sublist(32));
  if (r >= _fieldPrime || s >= _curve.n) return false;
  final e = _challenge(
    signature.sublist(0, 32),
    _bytes32(point.x!.toBigInteger()!),
    message,
  );
  final sG = _multiply(_curve.G, s);
  final eP = _multiply(point, e);
  final ECPoint result;
  if (eP.isInfinity) {
    result = sG;
  } else {
    final negated = _curve.curve.createPoint(
      eP.x!.toBigInteger()!,
      _fieldPrime - eP.y!.toBigInteger()!,
    );
    result = (sG + negated)!;
  }
  if (result.isInfinity) return false;
  return _isEven(result) && result.x!.toBigInteger() == r;
}

BigInt _challenge(List<int> r, List<int> pointX, List<int> message) =>
    _toBig(_taggedHash('BIP0340/challenge', [...r, ...pointX, ...message])) %
    _curve.n;

ECPoint _multiply(ECPoint point, BigInt scalar) => (point * scalar)!;

bool _isEven(ECPoint point) => point.y!.toBigInteger()!.isEven;

/// The curve point with x-coordinate [x] and even y, or null.
ECPoint? _liftX(BigInt x) {
  if (x >= _fieldPrime) return null;
  final ySquared =
      (x.modPow(BigInt.from(3), _fieldPrime) + BigInt.from(7)) % _fieldPrime;
  final y = ySquared.modPow(
    (_fieldPrime + BigInt.one) ~/ BigInt.from(4),
    _fieldPrime,
  );
  if (y.modPow(BigInt.two, _fieldPrime) != ySquared) return null;
  return _curve.curve.createPoint(x, y.isEven ? y : _fieldPrime - y);
}

BigInt _scalar(String privateKeyHex) {
  if (!_hex32.hasMatch(privateKeyHex)) {
    throw const FormatException('private key must be 32 bytes of hex');
  }
  final value = BigInt.parse(privateKeyHex, radix: 16);
  if (value == BigInt.zero || value >= _curve.n) {
    throw const FormatException('private key is outside the curve order');
  }
  return value;
}

List<int> _taggedHash(String tag, List<int> message) {
  final tagHash = hashing.sha256.convert(utf8.encode(tag)).bytes;
  return hashing.sha256.convert([...tagHash, ...tagHash, ...message]).bytes;
}

Uint8List _bytes32(BigInt value) {
  final bytes = Uint8List(32);
  var remaining = value;
  for (var index = 31; index >= 0; index--) {
    bytes[index] = (remaining & BigInt.from(0xff)).toInt();
    remaining >>= 8;
  }
  return bytes;
}

BigInt _toBig(List<int> bytes) {
  var value = BigInt.zero;
  for (final byte in bytes) {
    value = (value << 8) | BigInt.from(byte);
  }
  return value;
}

Uint8List _decode(String hex, int length) {
  if (hex.length != length * 2) {
    throw FormatException('expected $length bytes of hex');
  }
  final bytes = Uint8List(length);
  for (var index = 0; index < length; index++) {
    final value = int.tryParse(
      hex.substring(index * 2, index * 2 + 2),
      radix: 16,
    );
    if (value == null) throw const FormatException('invalid hex');
    bytes[index] = value;
  }
  return bytes;
}

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
