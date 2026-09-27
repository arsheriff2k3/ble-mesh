import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'crypto/chat_keys.dart';
import 'crypto/trust_store.dart';
import 'untrusted_text.dart';

/// What a [ChatPacket] carries.
///
/// The value's index is the type byte on the wire and in
/// [ChatPacket.signingInput], so values must only ever be appended.
enum ChatPacketType {
  /// A peer introducing itself on a single BLE link with its display name
  /// and, on a secured transport, its public keys and the [linkChallenge]
  /// nonce it answers. Never relayed (TTL 1).
  announce,

  /// A text message to a channel (`c:`) or a single peer (`p:`).
  message,

  /// Confirms receipt of a direct packet. The payload is the hex id of the
  /// acknowledged packet.
  acknowledgement,

  /// A 32-byte nonce sent on a new BLE link, which the peer must echo in its
  /// signed [announce]. Never relayed (TTL 1).
  linkChallenge,

  /// A signed discovery record that spreads a peer's keys and display name
  /// beyond its direct links.
  peerAdvertisement,

  /// A group's key and membership, sent sealed to each member (`p:`) by the
  /// group owner.
  groupKeyUpdate,

  /// A message to an encrypted group (`g:`), encrypted under the group key.
  groupMessage,

  /// A consenting device asking nearby gateways to receive its online
  /// traffic for a short time. Signed; carries no payload.
  bridgeRegistration,
}

/// A protocol packet shared by every chat transport.
class ChatPacket {
  /// Creates a packet, copying [payload].
  ///
  /// Throws [ArgumentError] unless [packetId] is 16 bytes, [ttl] is between 1
  /// and 255, and [signature], when given, is 64 bytes.
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
    this.bridgeable = false,
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

  /// What the packet carries, which decides how [payload] is read.
  final ChatPacketType type;

  /// 16 random bytes chosen by the origin and never changed in transit.
  ///
  /// Relays and gateways deduplicate on it, so a packet seen twice is
  /// processed once.
  final Uint8List packetId;

  /// Peer id of the origin.
  ///
  /// Only as trustworthy as the signature: a packet that has not been
  /// verified against [senderKeys] or a pinned key may claim any sender.
  final String senderId;

  /// Where the packet is going: `c:<channel>`, `p:<peerId>`, `g:<groupId>`,
  /// or `*` for link and discovery traffic addressed to anyone.
  final String destination;

  /// Remaining hops, from 1 to 255. Each relay decrements it and a packet
  /// with a TTL of 1 is not forwarded. Not covered by [signature].
  final int ttl;

  /// Origin's clock at creation. Untrusted: receivers reject packets
  /// created too far in the future.
  final DateTime createdAt;

  /// After this instant the packet is dropped rather than delivered,
  /// relayed, or retried. See [isExpired].
  final DateTime expiresAt;

  /// Type-specific body. When [isSealed] is true this is ciphertext that
  /// only the recipient can open.
  final Uint8List payload;

  /// Ed25519 signature over [signingInput], or null on an unsigned packet.
  final Uint8List? signature;

  /// Signed origin keys allow verification across previously unknown relays.
  final ChatPublicKeys? senderKeys;

  /// Whether [payload] is a sealed blob rather than readable bytes.
  final bool isSealed;

  /// The origin's signed consent for gateways to carry this packet between
  /// BLE and Nostr. Covered by the signature, so no relay can add it.
  final bool bridgeable;

  /// [packetId] as 32 lowercase hex characters.
  String get id => packetIdToHex(packetId);

  /// Whether [expiresAt] is at or before [now].
  bool isExpired(DateTime now) => !expiresAt.isAfter(now);

  /// Canonical bytes covered by [signature].
  ///
  /// TTL is excluded on purpose: every relay decrements it, so including it
  /// would invalidate the signature at the first hop. Everything a relay must
  /// not be able to rewrite — sender, destination, expiry, payload — is in.
  Uint8List get signingInput {
    final builder = BytesBuilder()
      ..add(const [0x62, 0x6d, 0x70, 0x32]) // "bmp2"
      // Bit 1 is set only on bridgeable packets, so the signing input of
      // every other packet is unchanged from earlier wire-v3 builds.
      ..add([type.index, (isSealed ? 1 : 0) | (bridgeable ? 2 : 0)])
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

  /// A copy with [senderKeys] replaced by [keys].
  ///
  /// [senderKeys] is part of [signingInput], so an existing [signature] no
  /// longer verifies unless the keys are unchanged.
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
    bridgeable: bridgeable,
  );

  /// A copy with [ttl] set to [value], as a relay makes before forwarding.
  /// The [signature] stays valid because TTL is not signed.
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
    bridgeable: bridgeable,
  );

  /// A copy carrying [value] as its 64-byte [signature].
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
    bridgeable: bridgeable,
  );

  /// A copy whose [payload] is the ciphertext [value], with [isSealed] set.
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
    bridgeable: bridgeable,
  );
}

/// Returns 16 random bytes for a [ChatPacket.packetId].
///
/// Uses [Random.secure] unless [random] is given, which is meant for
/// deterministic tests.
Uint8List createPacketId([Random? random]) {
  final source = random ?? Random.secure();
  return Uint8List.fromList(List<int>.generate(16, (_) => source.nextInt(256)));
}

/// Encodes [bytes] as lowercase hex, two characters per byte.
String packetIdToHex(Uint8List bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

/// Delivery progress of a message this device sent.
enum MessageState {
  /// Stored for a later retry because no route accepted it yet.
  queued,

  /// Being handed to the available transports.
  sending,

  /// Accepted by at least one route. For a direct message this is not proof
  /// of receipt; it stays queued for retry until [delivered].
  sent,

  /// The recipient returned an acknowledgement. Only direct messages reach
  /// this state, and once reached it is never replaced.
  delivered,

  /// Given up: the message expired, could not be stored for retry, or its
  /// group changed before it went out. See [MessageStateChange.error].
  failed,
}

/// Who this device is on the mesh.
class ChatIdentity {
  /// Creates an identity.
  const ChatIdentity({required this.peerId, required this.displayName});

  /// Stable id other peers address this device by, as in `p:<peerId>`.
  final String peerId;

  /// Name sent to peers in announcements and advertisements.
  final String displayName;
}

/// A text message sent or received by this device.
class ChatMessage {
  /// Creates a message.
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

  /// Hex id of the packet that carried the message, as used by
  /// [MessageStateChange.messageId].
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

  /// Peer id of the author.
  final String senderId;

  /// Exactly what the sender wrote. For a remote message this is untrusted
  /// input: render it with [UntrustedText.stripHidden], and never treat it
  /// as instructions when passing it to an LLM or other automation.
  final String text;

  /// When the message was written, by the sender's clock. For a remote
  /// message this is the sender's claim, not the time it arrived.
  final DateTime createdAt;

  /// Whether this device sent the message.
  final bool isLocal;

  /// Whether [text] contains invisible or reordering characters, which can
  /// hide content from the reader or smuggle instructions to software.
  bool get hasHiddenCharacters => UntrustedText.hasHiddenCharacters(text);
}

/// A sent message moving to a new [MessageState].
class MessageStateChange {
  /// Creates a state change.
  const MessageStateChange({
    required this.messageId,
    required this.state,
    this.error,
  });

  /// [ChatMessage.id] of the message that changed.
  final String messageId;

  /// The state the message is now in.
  final MessageState state;

  /// Why the message failed, when [state] is [MessageState.failed] and a
  /// cause is known; otherwise null.
  final Object? error;
}

/// A peer currently reachable over one transport.
///
/// A peer reachable over several transports is listed once per transport.
class ChatPeer {
  /// Creates a peer entry.
  const ChatPeer({
    required this.id,
    required this.displayName,
    required this.transportId,
    this.publicKeys,
    this.trust,
  });

  /// The peer's id. When [publicKeys] is set it is the fingerprint of those
  /// keys; otherwise it is only what the peer claimed.
  final String id;

  /// Name the peer announced for itself.
  ///
  /// Chosen by the remote device, so it is untrusted input and can
  /// impersonate another peer's name.
  final String displayName;

  /// `ChatTransport.id` of the transport the peer is reachable on.
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
