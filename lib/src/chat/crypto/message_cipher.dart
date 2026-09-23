import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'chat_keys.dart';

/// Thrown when a packet cannot be authenticated or decrypted.
///
/// Deliberately carries no detail about which check failed: telling a caller
/// whether the signature or the tag was wrong hands an attacker an oracle.
class MessageSecurityException implements Exception {
  const MessageSecurityException(this.reason);

  /// A coarse category, safe to log. Never the offending bytes.
  final String reason;

  @override
  String toString() => 'MessageSecurityException: $reason';
}

/// A verified signing identity advertised a different agreement key.
/// Hosts may show a fingerprint comparison before explicitly accepting it.
class PeerKeyChangedException extends MessageSecurityException {
  const PeerKeyChangedException(this.peerId, this.proposedKeys)
    : super('peer key changed');
  final String peerId;
  final ChatPublicKeys proposedKeys;
}

/// Sealed payload produced by [MessageCipher.encrypt].
class SealedPayload {
  const SealedPayload({
    required this.ephemeralPublicKey,
    required this.nonce,
    required this.ciphertext,
    required this.mac,
  });

  final Uint8List ephemeralPublicKey;
  final Uint8List nonce;
  final Uint8List ciphertext;
  final Uint8List mac;

  Uint8List encode() {
    final builder = BytesBuilder()
      ..add(ephemeralPublicKey)
      ..add(nonce)
      ..add(mac);
    final length = ByteData(4)..setUint32(0, ciphertext.length);
    builder
      ..add(length.buffer.asUint8List())
      ..add(ciphertext);
    return builder.toBytes();
  }

  static SealedPayload decode(Uint8List bytes) {
    const header = 32 + 24 + 16 + 4;
    if (bytes.length < header) {
      throw const MessageSecurityException('malformed');
    }
    final view = ByteData.sublistView(bytes);
    final length = view.getUint32(72);
    if (header + length != bytes.length) {
      throw const MessageSecurityException('malformed');
    }
    return SealedPayload(
      ephemeralPublicKey: Uint8List.sublistView(bytes, 0, 32),
      nonce: Uint8List.sublistView(bytes, 32, 56),
      mac: Uint8List.sublistView(bytes, 56, 72),
      ciphertext: Uint8List.sublistView(bytes, header),
    );
  }
}

/// Extension seam for message confidentiality.
///
/// Implementing this is not permission to ship an unreviewed cipher. The
/// default suite is documented in `docs/CRYPTO.md`.
abstract interface class MessageCipher {
  /// Identifier recorded on the wire so a future suite can coexist.
  String get suiteId;

  /// Encrypts [plaintext] to [recipient], binding [associatedData] so packet
  /// metadata cannot be altered without breaking authentication.
  Future<Uint8List> encrypt({
    required Uint8List plaintext,
    required ChatPublicKeys recipient,
    required Uint8List associatedData,
  });

  /// Decrypts a sealed payload addressed to us.
  Future<Uint8List> decrypt({
    required Uint8List sealed,
    required ChatKeyPair self,
    required Uint8List associatedData,
  });
}

/// Default suite: X25519 to a per-message ephemeral key, HKDF-SHA256, then
/// XChaCha20-Poly1305.
///
/// Ephemeral-to-static rather than static-to-static so compromising a sender's
/// long-term key later does not reveal messages already sent. There is no
/// handshake, which is the property that matters for a mesh: the recipient may
/// be asleep, out of range, or hours away behind a relay when the packet is
/// created.
class SealedMessageCipher implements MessageCipher {
  const SealedMessageCipher();

  @override
  String get suiteId => 'x25519-xchacha20poly1305-v1';

  static final _info = utf8.encode('ble_mesh/message/v1');

  @override
  Future<Uint8List> encrypt({
    required Uint8List plaintext,
    required ChatPublicKeys recipient,
    required Uint8List associatedData,
  }) async {
    final ephemeral = await x25519.newKeyPair();
    final ephemeralPublic = await ephemeral.extractPublicKey();
    final shared = await x25519.sharedSecretKey(
      keyPair: ephemeral,
      remotePublicKey: SimplePublicKey(
        recipient.agreement,
        type: KeyPairType.x25519,
      ),
    );
    final key = await _deriveKey(
      shared: shared,
      ephemeralPublicKey: ephemeralPublic.bytes,
      recipient: recipient.agreement,
    );
    final nonce = aead.newNonce();
    final box = await aead.encrypt(
      plaintext,
      secretKey: key,
      nonce: nonce,
      aad: associatedData,
    );
    return SealedPayload(
      ephemeralPublicKey: Uint8List.fromList(ephemeralPublic.bytes),
      nonce: Uint8List.fromList(box.nonce),
      ciphertext: Uint8List.fromList(box.cipherText),
      mac: Uint8List.fromList(box.mac.bytes),
    ).encode();
  }

  @override
  Future<Uint8List> decrypt({
    required Uint8List sealed,
    required ChatKeyPair self,
    required Uint8List associatedData,
  }) async {
    final payload = SealedPayload.decode(sealed);
    try {
      final shared = await x25519.sharedSecretKey(
        keyPair: self.agreementKeyPair,
        remotePublicKey: SimplePublicKey(
          payload.ephemeralPublicKey,
          type: KeyPairType.x25519,
        ),
      );
      final key = await _deriveKey(
        shared: shared,
        ephemeralPublicKey: payload.ephemeralPublicKey,
        recipient: self.publicKeys.agreement,
      );
      final clear = await aead.decrypt(
        SecretBox(
          payload.ciphertext,
          nonce: payload.nonce,
          mac: Mac(payload.mac),
        ),
        secretKey: key,
        aad: associatedData,
      );
      return Uint8List.fromList(clear);
    } on MessageSecurityException {
      rethrow;
    } on Object {
      // Wrong recipient, tampered ciphertext, and a mangled nonce all land
      // here and must be indistinguishable to the caller.
      throw const MessageSecurityException('authentication failed');
    }
  }

  /// Binds both public keys into the KDF so a shared secret cannot be reused
  /// in a different pairing.
  Future<SecretKey> _deriveKey({
    required SecretKey shared,
    required List<int> ephemeralPublicKey,
    required List<int> recipient,
  }) => hkdf.deriveKey(
    secretKey: shared,
    info: _info,
    nonce:
        (BytesBuilder()
              ..add(ephemeralPublicKey)
              ..add(recipient))
            .toBytes(),
  );
}
