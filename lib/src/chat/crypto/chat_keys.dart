import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashing;
import 'package:cryptography/cryptography.dart';

/// Algorithms fixed by the default suite.
///
/// Held as top-level finals rather than constructed per call so a platform
/// that offers hardware-backed implementations is picked up once.
final ed25519 = Ed25519();
final x25519 = X25519();
final aead = Xchacha20.poly1305Aead();
final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

/// The public half of a peer's identity.
///
/// Two keys, not one: signing and key agreement are separate algorithms, and
/// reusing a single key across both is exactly the kind of shortcut that turns
/// a reviewed primitive into an unreviewed protocol.
class ChatPublicKeys {
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

  Uint8List encode() {
    final bytes = BytesBuilder()
      ..add(signing)
      ..add(agreement);
    return bytes.toBytes();
  }

  static ChatPublicKeys decode(Uint8List bytes) {
    if (bytes.length != 64) {
      throw const FormatException('peer keys must be 64 bytes');
    }
    return ChatPublicKeys(
      signing: Uint8List.sublistView(bytes, 0, 32),
      agreement: Uint8List.sublistView(bytes, 32, 64),
    );
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
  ChatKeyPair({
    required this.signingKeyPair,
    required this.agreementKeyPair,
    required this.publicKeys,
  });

  final SimpleKeyPair signingKeyPair;
  final SimpleKeyPair agreementKeyPair;
  final ChatPublicKeys publicKeys;

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
