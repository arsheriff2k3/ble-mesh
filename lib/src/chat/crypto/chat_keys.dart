import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashing;
import 'package:cryptography/cryptography.dart';

/// Algorithms fixed by the default suite.
///
/// Held as top-level finals rather than constructed per call so a platform
/// that offers hardware-backed implementations is picked up once.
final ed25519 = Ed25519();

/// X25519 key agreement (RFC 7748).
final x25519 = X25519();

/// XChaCha20-Poly1305 AEAD with a 24-byte nonce and 16-byte tag.
final aead = Xchacha20.poly1305Aead();

/// HKDF-SHA256 producing 32-byte keys.
final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

/// The public half of a peer's identity.
///
/// Two keys, not one: signing and key agreement are separate algorithms, and
/// reusing a single key across both is exactly the kind of shortcut that turns
/// a reviewed primitive into an unreviewed protocol.
class ChatPublicKeys {
  /// Creates keys from raw 32-byte [signing] and [agreement] public keys.
  ///
  /// Lengths are not checked here; [decode] checks the combined length.
  const ChatPublicKeys({required this.signing, required this.agreement});

  /// Ed25519 public key, 32 bytes. Identity is derived from this.
  final Uint8List signing;

  /// X25519 public key, 32 bytes, used to encrypt to this peer.
  final Uint8List agreement;

  /// Stable peer id: `peer-` plus the first 8 bytes of SHA-256 over the
  /// signing key.
  ///
  /// Deriving the id from the key is what makes impersonation detectable. A
  /// device that copies a display name and peer id but lacks the private key
  /// produces announcements that fail verification.
  String get peerId => 'peer-${_fingerprint(signing)}';

  /// Wire form: [signing] followed by [agreement], 64 bytes.
  Uint8List encode() {
    final bytes = BytesBuilder()
      ..add(signing)
      ..add(agreement);
    return bytes.toBytes();
  }

  /// Parses the 64-byte output of [encode].
  ///
  /// Throws [FormatException] if [bytes] is not exactly 64 bytes. The keys
  /// are views into [bytes] and are not otherwise validated; parsing grants
  /// no trust.
  static ChatPublicKeys decode(Uint8List bytes) {
    if (bytes.length != 64) {
      throw const FormatException('peer keys must be 64 bytes');
    }
    return ChatPublicKeys(
      signing: Uint8List.sublistView(bytes, 0, 32),
      agreement: Uint8List.sublistView(bytes, 32, 64),
    );
  }

  /// Sixty digits two peers compare to confirm they hold each other's keys.
  ///
  /// Both sides compute the same number. It covers both parties' signing
  /// and agreement keys, so it changes after any key rotation. Each half is
  /// one party's fingerprint, stretched with 5200 hash rounds so that
  /// grinding a key to match the first few groups a person might check is
  /// expensive. Compare it in person or over two independent channels:
  /// voices and video can be synthesized.
  static String safetyNumber(ChatPublicKeys a, ChatPublicKeys b) {
    final halves = [_fingerprintDigits(a), _fingerprintDigits(b)]..sort();
    final digits = halves.join();
    return [
      for (var i = 0; i < digits.length; i += 5) digits.substring(i, i + 5),
    ].join(' ');
  }

  static String _fingerprintDigits(ChatPublicKeys keys) {
    final encoded = keys.encode();
    var hash = _sha256([...utf8.encode('ble_mesh/safety/v1'), ...encoded]);
    for (var round = 0; round < 5200; round++) {
      hash = _sha256([...hash, ...encoded]);
    }
    final buffer = StringBuffer();
    for (var group = 0; group < 6; group++) {
      var value = 0;
      for (var i = 0; i < 5; i++) {
        value = value * 256 + hash[group * 5 + i];
      }
      buffer.write((value % 100000).toString().padLeft(5, '0'));
    }
    return buffer.toString();
  }

  static const _contactPrefix = 'blemesh1:';

  /// Shareable text form of these keys, for adding a contact who has never
  /// been in BLE range. Whoever supplies the code decides who you trust, so
  /// it must arrive over a channel you already trust.
  String toContactCode() =>
      '$_contactPrefix${base64Url.encode(encode()).replaceAll('=', '')}';

  /// Parses [toContactCode] output, ignoring surrounding whitespace.
  static ChatPublicKeys fromContactCode(String code) {
    final trimmed = code.trim();
    if (!trimmed.startsWith(_contactPrefix)) {
      throw const FormatException('not a ble_mesh contact code');
    }
    final body = trimmed.substring(_contactPrefix.length);
    return decode(base64Url.decode(base64Url.normalize(body)));
  }

  @override
  bool operator ==(Object other) =>
      other is ChatPublicKeys &&
      _constantTimeEquals(signing, other.signing) &&
      _constantTimeEquals(agreement, other.agreement);

  @override
  int get hashCode => Object.hash(peerId, agreement.length);
}

/// A peer's own key material, including private keys.
class ChatKeyPair {
  /// Creates a key pair from existing parts.
  ///
  /// [publicKeys] must match the two key pairs; this is not checked. Prefer
  /// [generate] or [fromPrivateBytes], which derive it.
  ChatKeyPair({
    required this.signingKeyPair,
    required this.agreementKeyPair,
    required this.publicKeys,
  });

  /// Ed25519 key pair that signs packets and announcements.
  final SimpleKeyPair signingKeyPair;

  /// X25519 key pair that opens messages sealed to this peer.
  final SimpleKeyPair agreementKeyPair;

  /// Public halves of both key pairs, safe to share.
  final ChatPublicKeys publicKeys;

  /// Peer id derived from the signing key; see [ChatPublicKeys.peerId].
  String get peerId => publicKeys.peerId;

  /// Generates a fresh identity.
  static Future<ChatKeyPair> generate() async {
    final signing = await ed25519.newKeyPair();
    final agreement = await x25519.newKeyPair();
    return ChatKeyPair(
      signingKeyPair: signing,
      agreementKeyPair: agreement,
      publicKeys: ChatPublicKeys(
        signing: Uint8List.fromList((await signing.extractPublicKey()).bytes),
        agreement: Uint8List.fromList(
          (await agreement.extractPublicKey()).bytes,
        ),
      ),
    );
  }

  /// Rebuilds an identity from stored private key bytes.
  static Future<ChatKeyPair> fromPrivateBytes({
    required List<int> signingSeed,
    required List<int> agreementSeed,
  }) async {
    if (signingSeed.length != 32 || agreementSeed.length != 32) {
      throw const FormatException('identity seeds must be 32 bytes');
    }
    final signing = await ed25519.newKeyPairFromSeed(signingSeed);
    final agreement = await x25519.newKeyPairFromSeed(agreementSeed);
    return ChatKeyPair(
      signingKeyPair: signing,
      agreementKeyPair: agreement,
      publicKeys: ChatPublicKeys(
        signing: Uint8List.fromList((await signing.extractPublicKey()).bytes),
        agreement: Uint8List.fromList(
          (await agreement.extractPublicKey()).bytes,
        ),
      ),
    );
  }

  /// Rotates the agreement key while retaining the signing identity.
  /// Peers must explicitly approve the changed key before further delivery.
  /// Previously queued ciphertext to the old agreement key becomes unreadable.
  Future<ChatKeyPair> rotateAgreementKey() async {
    final agreement = await x25519.newKeyPair();
    return ChatKeyPair(
      signingKeyPair: signingKeyPair,
      agreementKeyPair: agreement,
      publicKeys: ChatPublicKeys(
        signing: Uint8List.fromList(publicKeys.signing),
        agreement: Uint8List.fromList(
          (await agreement.extractPublicKey()).bytes,
        ),
      ),
    );
  }

  /// The 32-byte seeds to hand to secure storage.
  Future<({List<int> signing, List<int> agreement})> extractSeeds() async => (
    signing: await signingKeyPair.extractPrivateKeyBytes(),
    agreement: await agreementKeyPair.extractPrivateKeyBytes(),
  );
}

String _fingerprint(Uint8List signing) {
  final digest = _sha256(signing);
  return digest
      .take(8)
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
}

/// `cryptography`'s Sha256 is async; the fingerprint has to be available from
/// a plain getter, so the synchronous implementation is used here.
List<int> _sha256(List<int> input) => hashing.sha256.convert(input).bytes;

bool _constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var index = 0; index < a.length; index++) {
    difference |= a[index] ^ b[index];
  }
  return difference == 0;
}

/// Canonical bytes signed for a peer announcement.
Uint8List announcementSigningInput({
  required String peerId,
  required String displayName,
  required ChatPublicKeys keys,
  required DateTime issuedAt,
}) {
  final builder = BytesBuilder()
    ..add(utf8.encode('ble_mesh/announce/v1'))
    ..add(utf8.encode(peerId))
    ..add(utf8.encode(displayName))
    ..add(keys.encode());
  final time = ByteData(8)
    ..setUint64(0, issuedAt.toUtc().millisecondsSinceEpoch);
  builder.add(time.buffer.asUint8List());
  return builder.toBytes();
}
