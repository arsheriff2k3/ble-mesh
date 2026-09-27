import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../chat_models.dart';
import 'chat_keys.dart';
import 'message_cipher.dart';
import 'trust_store.dart';

/// Result of admitting an inbound packet.
class VerifiedPacket {
  /// Creates a result; produced by [PacketSecurity.admit].
  const VerifiedPacket({
    required this.packet,
    required this.trust,
    required this.senderKeys,
  });

  /// The packet with its payload opened when it was sealed for us.
  final ChatPacket packet;

  /// How the sender's keys compared with the pinned record. Never
  /// [PeerTrust.changed]; that case throws [PeerKeyChangedException].
  final PeerTrust trust;

  /// Keys the signature was verified against.
  ///
  /// Non-null when produced by [PacketSecurity.admit]. They prove key
  /// ownership, not a person's real-world identity.
  final ChatPublicKeys? senderKeys;
}

/// Signs outbound packets and authenticates inbound ones.
///
/// Signature verification happens before anything else touches a packet:
/// deduplication, relaying, and display all run on packets whose sender has
/// been proven, so a forged packet cannot occupy a packet id or be forwarded.
class PacketSecurity {
  /// Creates a security layer for [identity].
  ///
  /// Uses an empty in-memory [TrustStore] when [trustStore] is omitted, so
  /// pins are lost unless the host persists them.
  PacketSecurity({
    required this.identity,
    TrustStore? trustStore,
    this.cipher = const SealedMessageCipher(),
  }) : trustStore = trustStore ?? TrustStore();

  /// This device's key pair; signs outbound packets and opens sealed ones.
  final ChatKeyPair identity;

  /// Pinned peer keys consulted and updated by [admit].
  final TrustStore trustStore;

  /// Cipher used for sealed direct payloads.
  final MessageCipher cipher;

  /// Suite identifier of [cipher].
  String get suiteId => cipher.suiteId;

  /// Seals [packet] for [recipient] when possible, then signs it.
  ///
  /// A direct message to a peer whose key we have never seen cannot be
  /// encrypted. Rather than silently downgrade to plaintext, this throws: a
  /// user who believes a conversation is private must not be wrong about it.
  Future<ChatPacket> protect(
    ChatPacket packet, {
    required bool encrypt,
    ChatPublicKeys? recipient,
  }) async {
    if (packet.senderId != identity.peerId) {
      throw const MessageSecurityException('sender does not match identity');
    }
    var prepared = packet.withSenderKeys(identity.publicKeys);
    if (encrypt) {
      if (recipient == null) {
        throw const MessageSecurityException('recipient key unknown');
      }
      final sealed = await cipher.encrypt(
        plaintext: packet.payload,
        recipient: recipient,
        associatedData: prepared.associatedData,
      );
      prepared = prepared.withSealedPayload(sealed);
    }
    final signature = await ed25519.sign(
      prepared.signingInput,
      keyPair: identity.signingKeyPair,
    );
    return prepared.withSignature(Uint8List.fromList(signature.bytes));
  }

  /// Verifies [packet], pins the sender's key on first contact, and opens a
  /// payload sealed for us.
  ///
  /// [announcedKeys] come from the peer announcement that introduced this
  /// sender; without them there is nothing to verify against.
  Future<VerifiedPacket> admit(
    ChatPacket packet, {
    ChatPublicKeys? announcedKeys,
  }) async {
    final keys =
        packet.senderKeys ??
        announcedKeys ??
        trustStore.keysFor(packet.senderId);
    if (announcedKeys != null &&
        packet.senderKeys != null &&
        announcedKeys != packet.senderKeys) {
      throw const MessageSecurityException('inconsistent origin keys');
    }
    if (keys == null) {
      throw const MessageSecurityException('unknown sender');
    }
    if (keys.peerId != packet.senderId) {
      // The id is a fingerprint of the key, so a mismatch means the sender id
      // was chosen rather than derived.
      throw const MessageSecurityException('sender id does not match key');
    }
    final signature = packet.signature;
    if (signature == null) {
      throw const MessageSecurityException('unsigned packet');
    }
    final valid = await ed25519.verify(
      packet.signingInput,
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(keys.signing, type: KeyPairType.ed25519),
      ),
    );
    if (!valid) throw const MessageSecurityException('bad signature');

    final trust = trustStore.observe(packet.senderId, keys);
    if (trust == PeerTrust.changed) {
      throw PeerKeyChangedException(packet.senderId, keys);
    }

    var opened = packet;
    if ((packet.type == ChatPacketType.message ||
            packet.type == ChatPacketType.groupKeyUpdate) &&
        packet.destination.startsWith('p:') &&
        !packet.isSealed) {
      throw const MessageSecurityException('unencrypted direct message');
    }
    if (packet.isSealed) {
      if (packet.destination != 'p:${identity.peerId}') {
        throw const MessageSecurityException('wrong recipient');
      }
      final clear = await cipher.decrypt(
        sealed: packet.payload,
        self: identity,
        associatedData: packet.associatedData,
      );
      opened = ChatPacket(
        type: packet.type,
        packetId: packet.packetId,
        senderId: packet.senderId,
        destination: packet.destination,
        ttl: packet.ttl,
        createdAt: packet.createdAt,
        expiresAt: packet.expiresAt,
        payload: clear,
        signature: packet.signature,
        senderKeys: packet.senderKeys,
        bridgeable: packet.bridgeable,
      );
    }
    return VerifiedPacket(packet: opened, trust: trust, senderKeys: keys);
  }

  /// Verifies a packet's signature without opening a sealed payload.
  ///
  /// This is what a relay runs: it proves the packet is authentic and
  /// unmodified so it can be forwarded, while the content stays unreadable.
  Future<bool> verifyForRelay(
    ChatPacket packet, {
    required ChatPublicKeys senderKeys,
  }) async {
    final signature = packet.signature;
    if (signature == null) return false;
    if (senderKeys.peerId != packet.senderId) return false;
    if (packet.senderKeys != null && packet.senderKeys != senderKeys) {
      return false;
    }
    return ed25519.verify(
      packet.signingInput,
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(
          senderKeys.signing,
          type: KeyPairType.ed25519,
        ),
      ),
    );
  }
}
