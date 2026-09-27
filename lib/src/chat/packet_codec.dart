import 'dart:convert';
import 'dart:typed_data';

import 'chat_models.dart';
import 'crypto/chat_keys.dart';

/// Thrown when a [ChatPacket] cannot be encoded, or bytes do not decode to a
/// valid packet.
class ChatPacketFormatException implements FormatException {
  /// Creates an exception describing the fault in [message], optionally with
  /// the offending [source] and the [offset] within it.
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
  /// Creates a codec that refuses packets larger than [maxPacketSize].
  const ChatPacketCodec({this.maxPacketSize = 64 * 1024});

  static const _magic = 0x424d;
  static const _version = 3;
  static const _fixedLength = 46;
  static const _signatureLength = 128; // public keys (64) + signature (64)

  /// Bit 0 marks a signed packet, bit 1 a sealed payload.
  static const _flagSigned = 0x01;
  static const _flagSealed = 0x02;

  /// Bit 2 marks the origin's consent to cross gateways.
  static const _flagBridgeable = 0x04;

  /// Largest encoded packet accepted by [encode] and [decode], in bytes.
  /// Defaults to 64 KiB.
  final int maxPacketSize;

  /// Encodes [packet] in the version 3 wire format.
  ///
  /// Throws [ChatPacketFormatException] when the UTF-8 sender or destination
  /// exceeds 65535 bytes, when [ChatPacket.signature] is set without
  /// [ChatPacket.senderKeys], or when the result would exceed
  /// [maxPacketSize].
  Uint8List encode(ChatPacket packet) {
    final sender = utf8.encode(packet.senderId);
    final destination = utf8.encode(packet.destination);
    if (sender.length > 0xffff || destination.length > 0xffff) {
      throw const ChatPacketFormatException(
        'sender or destination is too long',
      );
    }
    final signature = packet.signature;
    if (signature != null && packet.senderKeys == null) {
      throw const ChatPacketFormatException(
        'signed packet requires origin keys',
      );
    }
    final size =
        _fixedLength +
        (signature == null ? 0 : _signatureLength) +
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
    data.setUint8(
      offset++,
      (signature == null ? 0 : _flagSigned) |
          (packet.isSealed ? _flagSealed : 0) |
          (packet.bridgeable ? _flagBridgeable : 0),
    );
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
    if (signature != null) {
      bytes.setRange(offset, offset + 64, packet.senderKeys!.encode());
      bytes.setRange(offset + 64, offset + _signatureLength, signature);
      offset += _signatureLength;
    }
    bytes.setRange(offset, offset + sender.length, sender);
    offset += sender.length;
    bytes.setRange(offset, offset + destination.length, destination);
    offset += destination.length;
    bytes.setRange(offset, size, packet.payload);
    return bytes;
  }

  /// Decodes a packet produced by [encode].
  ///
  /// Validates structure only; signatures are not verified here. Throws
  /// [ChatPacketFormatException] for truncated or oversized input, a wrong
  /// magic or version, an unknown type or flag, a zero TTL, a timestamp
  /// outside the [DateTime] range, inconsistent lengths, or invalid UTF-8 in
  /// the sender or destination.
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
    final flags = data.getUint8(offset++);
    final signed = flags & _flagSigned != 0;
    final sealed = flags & _flagSealed != 0;
    final bridgeable = flags & _flagBridgeable != 0;
    if (flags & ~(_flagSigned | _flagSealed | _flagBridgeable) != 0) {
      throw const ChatPacketFormatException('unknown packet flags');
    }
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
    final expected =
        offset +
        (signed ? _signatureLength : 0) +
        senderLength +
        destinationLength +
        payloadLength;
    if (expected != bytes.length) {
      throw const ChatPacketFormatException('invalid packet lengths');
    }
    Uint8List? signature;
    ChatPublicKeys? senderKeys;
    if (signed) {
      senderKeys = ChatPublicKeys.decode(
        Uint8List.sublistView(bytes, offset, offset + 64),
      );
      signature = Uint8List.fromList(
        bytes.sublist(offset + 64, offset + _signatureLength),
      );
      offset += _signatureLength;
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
        signature: signature,
        senderKeys: senderKeys,
        isSealed: sealed,
        bridgeable: bridgeable,
      );
    } on FormatException catch (error) {
      throw ChatPacketFormatException('invalid UTF-8 metadata: $error');
    }
  }
}
