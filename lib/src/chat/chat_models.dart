import 'dart:math';
import 'dart:typed_data';

enum ChatPacketType { announce, message, acknowledgement }

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
  }) : payload = Uint8List.fromList(payload) {
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

  String get id => packetIdToHex(packetId);

  bool isExpired(DateTime now) => !expiresAt.isAfter(now);

  ChatPacket withTtl(int value) => ChatPacket(
    type: type,
    packetId: packetId,
    senderId: senderId,
    destination: destination,
    ttl: value,
    createdAt: createdAt,
    expiresAt: expiresAt,
    payload: payload,
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
    required this.senderId,
    required this.text,
    required this.createdAt,
    required this.isLocal,
  });

  final String id;
  final String conversationId;
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
  });

  final String id;
  final String displayName;
  final String transportId;
}
