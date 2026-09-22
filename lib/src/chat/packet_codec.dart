import 'dart:convert';
import 'dart:typed_data';

import 'chat_models.dart';

class ChatPacketFormatException implements FormatException {
  const ChatPacketFormatException(this.message, [this.source, this.offset]);

  @override
  final String message;
  @override
  final Object? source;
  @override
  final int? offset;

  @override
  String toString() => 'ChatPacketFormatException: $message';
}

/// Deterministic binary codec for mesh packets.
class ChatPacketCodec {
  const ChatPacketCodec({this.maxPacketSize = 64 * 1024});

  static const _magic = 0x424d;
  static const _version = 1;
  static const _fixedLength = 46;

  final int maxPacketSize;

  Uint8List encode(ChatPacket packet) {
    final sender = utf8.encode(packet.senderId);
    final destination = utf8.encode(packet.destination);
    if (sender.length > 0xffff || destination.length > 0xffff) {
      throw const ChatPacketFormatException(
        'sender or destination is too long',
      );
    }
    final size =
        _fixedLength +
        sender.length +
        destination.length +
        packet.payload.length;
    if (size > maxPacketSize) {
      throw ChatPacketFormatException('packet exceeds ${maxPacketSize}B limit');
    }

    final bytes = Uint8List(size);
    final data = ByteData.sublistView(bytes);
    var offset = 0;
    data.setUint16(offset, _magic);
    offset += 2;
    data.setUint8(offset++, _version);
    data.setUint8(offset++, packet.type.index);
    data.setUint8(offset++, packet.ttl);
    data.setUint8(offset++, 0); // Reserved flags.
    data.setInt64(offset, packet.createdAt.millisecondsSinceEpoch);
    offset += 8;
    data.setInt64(offset, packet.expiresAt.millisecondsSinceEpoch);
    offset += 8;
    bytes.setRange(offset, offset + 16, packet.packetId);
    offset += 16;
    data.setUint16(offset, sender.length);
    offset += 2;
    data.setUint16(offset, destination.length);
    offset += 2;
    data.setUint32(offset, packet.payload.length);
    offset += 4;
    bytes.setRange(offset, offset + sender.length, sender);
    offset += sender.length;
    bytes.setRange(offset, offset + destination.length, destination);
    offset += destination.length;
    bytes.setRange(offset, size, packet.payload);
    return bytes;
  }

  ChatPacket decode(Uint8List bytes) {
    if (bytes.length < _fixedLength) {
      throw const ChatPacketFormatException('truncated packet');
    }
    if (bytes.length > maxPacketSize) {
      throw ChatPacketFormatException('packet exceeds ${maxPacketSize}B limit');
    }
    final data = ByteData.sublistView(bytes);
    var offset = 0;
    if (data.getUint16(offset) != _magic) {
      throw const ChatPacketFormatException('invalid packet magic');
    }
    offset += 2;
    if (data.getUint8(offset++) != _version) {
      throw const ChatPacketFormatException('unsupported packet version');
    }
    final typeValue = data.getUint8(offset++);
    if (typeValue >= ChatPacketType.values.length) {
      throw const ChatPacketFormatException('unknown packet type');
    }
    final ttl = data.getUint8(offset++);
    if (ttl == 0) throw const ChatPacketFormatException('TTL must be positive');
    offset++; // Reserved flags.
    final createdAtMs = data.getInt64(offset);
    offset += 8;
    final expiresAtMs = data.getInt64(offset);
    offset += 8;
    const maximumDateMilliseconds = 8640000000000000;
    if (createdAtMs < -maximumDateMilliseconds ||
        createdAtMs > maximumDateMilliseconds ||
        expiresAtMs < -maximumDateMilliseconds ||
        expiresAtMs > maximumDateMilliseconds) {
      throw const ChatPacketFormatException(
        'timestamp is outside the supported range',
      );
    }
    final createdAt = DateTime.fromMillisecondsSinceEpoch(createdAtMs);
    final expiresAt = DateTime.fromMillisecondsSinceEpoch(expiresAtMs);
    final packetId = Uint8List.fromList(bytes.sublist(offset, offset + 16));
    offset += 16;
    final senderLength = data.getUint16(offset);
    offset += 2;
    final destinationLength = data.getUint16(offset);
    offset += 2;
    final payloadLength = data.getUint32(offset);
    offset += 4;
    final expected = offset + senderLength + destinationLength + payloadLength;
    if (expected != bytes.length) {
      throw const ChatPacketFormatException('invalid packet lengths');
    }
    try {
      final sender = utf8.decode(bytes.sublist(offset, offset + senderLength));
      offset += senderLength;
      final destination = utf8.decode(
        bytes.sublist(offset, offset + destinationLength),
      );
      offset += destinationLength;
      return ChatPacket(
        type: ChatPacketType.values[typeValue],
        packetId: packetId,
        senderId: sender,
        destination: destination,
        ttl: ttl,
        createdAt: createdAt,
        expiresAt: expiresAt,
        payload: Uint8List.fromList(bytes.sublist(offset)),
      );
    } on FormatException catch (error) {
      throw ChatPacketFormatException('invalid UTF-8 metadata: $error');
    }
  }
}
