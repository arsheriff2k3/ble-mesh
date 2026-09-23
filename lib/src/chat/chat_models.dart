import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'crypto/chat_keys.dart';
import 'crypto/trust_store.dart';

enum ChatPacketType {
  announce,
  message,
  acknowledgement,
  linkChallenge,
  peerAdvertisement,
  groupKeyUpdate,
  groupMessage,
}

/// A protocol packet shared by every chat transport.
class ChatPacket {
  ChatPacket({
    required this.type,
    required this.packetId,
    required this.senderId,
    required this.destination,
    required this.ttl,
    required this.createdAt,
    required this.expiresAt,
    required Uint8List payload,
    this.signature,
    this.senderKeys,
    this.isSealed = false,
  }) : payload = Uint8List.fromList(payload) {
    if (signature != null && signature!.length != 64) {
      throw ArgumentError.value(
        signature!.length,
        'signature',
        'must be 64 bytes',
      );
    }
    if (packetId.length != 16) {
      throw ArgumentError.value(
        packetId.length,
        'packetId',
        'must be 16 bytes',
      );
    }
    if (ttl < 1 || ttl > 255) {
      throw ArgumentError.value(ttl, 'ttl', 'must be between 1 and 255');
    }
  }

  final ChatPacketType type;
  final Uint8List packetId;
  final String senderId;
  final String destination;
  final int ttl;
  final DateTime createdAt;
  final DateTime expiresAt;
  final Uint8List payload;

  /// Ed25519 signature over [signingInput], or null on an unsigned packet.
  final Uint8List? signature;

  /// Signed origin keys allow verification across previously unknown relays.
  final ChatPublicKeys? senderKeys;

  /// Whether [payload] is a sealed blob rather than readable bytes.
  final bool isSealed;

  String get id => packetIdToHex(packetId);

  bool isExpired(DateTime now) => !expiresAt.isAfter(now);

  /// Canonical bytes covered by [signature].
  ///
  /// TTL is excluded on purpose: every relay decrements it, so including it
  /// would invalidate the signature at the first hop. Everything a relay must
  /// not be able to rewrite — sender, destination, expiry, payload — is in.
  Uint8List get signingInput {
    final builder = BytesBuilder()
      ..add(const [0x62, 0x6d, 0x70, 0x32]) // "bmp2"
      ..add([type.index, isSealed ? 1 : 0])
      ..add(packetId)
      ..add(_lengthPrefixed(senderKeys?.encode() ?? const []));
    final times = ByteData(16)
      ..setInt64(0, createdAt.millisecondsSinceEpoch)
      ..setInt64(8, expiresAt.millisecondsSinceEpoch);
    builder
      ..add(times.buffer.asUint8List())
      ..add(_lengthPrefixed(utf8.encode(senderId)))
      ..add(_lengthPrefixed(utf8.encode(destination)))
      ..add(_lengthPrefixed(payload));
    return builder.toBytes();
  }

  /// Metadata bound into the AEAD so a relay cannot rewrite the envelope
  /// around a payload it cannot read.
  Uint8List get associatedData {
    final builder = BytesBuilder()
      ..add(const [0x62, 0x6d, 0x61, 0x32]) // "bma2"
      ..add([type.index])
      ..add(packetId)
      ..add(_lengthPrefixed(senderKeys?.encode() ?? const []));
    final expiry = ByteData(8)..setInt64(0, expiresAt.millisecondsSinceEpoch);
    builder
      ..add(expiry.buffer.asUint8List())
      ..add(_lengthPrefixed(utf8.encode(senderId)))
      ..add(_lengthPrefixed(utf8.encode(destination)));
    return builder.toBytes();
  }

  ChatPacket withSenderKeys(ChatPublicKeys keys) => ChatPacket(
    type: type,
    packetId: packetId,
    senderId: senderId,
    destination: destination,
    ttl: ttl,
    createdAt: createdAt,
    expiresAt: expiresAt,
    payload: payload,
    signature: signature,
    senderKeys: keys,
    isSealed: isSealed,
  );

  ChatPacket withTtl(int value) => ChatPacket(
    type: type,
    packetId: packetId,
    senderId: senderId,
    destination: destination,
    ttl: value,
    createdAt: createdAt,
    expiresAt: expiresAt,
    payload: payload,
    signature: signature,
    senderKeys: senderKeys,
    isSealed: isSealed,
  );

  ChatPacket withSignature(Uint8List value) => ChatPacket(
    type: type,
    packetId: packetId,
    senderId: senderId,
    destination: destination,
    ttl: ttl,
    createdAt: createdAt,
    expiresAt: expiresAt,
    payload: payload,
    signature: value,
    senderKeys: senderKeys,
    isSealed: isSealed,
  );

  ChatPacket withSealedPayload(Uint8List value) => ChatPacket(
    type: type,
    packetId: packetId,
    senderId: senderId,
    destination: destination,
    ttl: ttl,
    createdAt: createdAt,
    expiresAt: expiresAt,
    payload: value,
    signature: signature,
    senderKeys: senderKeys,
    isSealed: true,
  );
}

Uint8List createPacketId([Random? random]) {
  final source = random ?? Random.secure();
  return Uint8List.fromList(List<int>.generate(16, (_) => source.nextInt(256)));
}

String packetIdToHex(Uint8List bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

enum MessageState { queued, sending, sent, delivered, failed }

class ChatIdentity {
  const ChatIdentity({required this.peerId, required this.displayName});

  final String peerId;
  final String displayName;
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.conversationId,
    required this.threadId,
    required this.isDirect,
    required this.senderId,
    required this.text,
    required this.createdAt,
    required this.isLocal,
  });

  final String id;

  /// The packet destination with its `c:`/`p:` prefix removed.
  ///
  /// For a channel this is the channel name, but for a direct message it is
  /// the *recipient*, which is the local peer on the receiving side. Group by
  /// [threadId] instead: `conversationId` does not identify both halves of a
  /// direct conversation.
  final String conversationId;

  /// Stable conversation key: the channel name, or for a direct message the
  /// remote participant regardless of direction.
  final String threadId;

  /// Whether this message was addressed to a single peer rather than a
  /// channel.
  final bool isDirect;

  final String senderId;
  final String text;
  final DateTime createdAt;
  final bool isLocal;
}

class MessageStateChange {
  const MessageStateChange({
    required this.messageId,
    required this.state,
    this.error,
  });

  final String messageId;
  final MessageState state;
  final Object? error;
}

class ChatPeer {
  const ChatPeer({
    required this.id,
    required this.displayName,
    required this.transportId,
    this.publicKeys,
    this.trust,
  });

  final String id;
  final String displayName;
  final String transportId;

  /// The peer's verified keys, or null on an unauthenticated transport.
  final ChatPublicKeys? publicKeys;

  /// How the peer's key compared with what was already pinned.
  final PeerTrust? trust;

  /// Whether we hold keys for this peer, which is what a direct message
  /// requires.
  bool get canReceiveDirect => publicKeys != null && trust != PeerTrust.changed;
}

Uint8List _lengthPrefixed(List<int> bytes) =>
    (BytesBuilder()
          ..add((ByteData(4)..setUint32(0, bytes.length)).buffer.asUint8List())
          ..add(bytes))
        .toBytes();
