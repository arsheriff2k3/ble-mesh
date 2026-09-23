import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'chat_models.dart';
import 'message_store.dart';
import 'packet_codec.dart';

/// Durable [MessageStore] backed by a single append-only log file.
///
/// An append-only log is chosen over a database because the queue is already
/// a log: every operation is "this packet is pending" or "this packet is no
/// longer pending". Appending keeps writes cheap and, more importantly, keeps
/// a crash during a write from corrupting records that were already durable —
/// the torn record is always the last one.
///
/// Layout:
///
/// ```text
/// magic "BLEMESH1" | format version u16
/// record: type u8 | payload length u32 | payload | CRC-32 of payload u32
/// ```
///
/// Reading stops at the first record that is truncated or fails its checksum,
/// and the file is trimmed back to the last good record on the next write.
/// Everything before the tear survives.
class FileMessageStore implements MessageStore {
  FileMessageStore({
    required this.file,
    this.maximumQueuedPackets = 1024,
    this.maximumMessages = 4096,
    this.maximumSeenPackets = 65536,
    this.compactionThresholdBytes = 512 * 1024,
    this.codec = const ChatPacketCodec(),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Opens a store at [path], creating parent directories as needed.
  ///
  /// The host application chooses the location: a plugin has no business
  /// deciding whether chat history belongs in cache, documents, or support
  /// storage, and taking a path keeps `path_provider` out of the dependency
  /// list.
  factory FileMessageStore.at(
    String path, {
    int maximumQueuedPackets = 1024,
    int maximumMessages = 4096,
    int maximumSeenPackets = 65536,
    DateTime Function()? clock,
  }) => FileMessageStore(
    file: File(path),
    maximumQueuedPackets: maximumQueuedPackets,
    maximumMessages: maximumMessages,
    maximumSeenPackets: maximumSeenPackets,
    clock: clock,
  );

  static const _magic = 'BLEMESH1';
  static const _version = 1;

  static const _recordEnqueue = 0x01;
  static const _recordRemove = 0x02;
  static const _recordMessage = 0x03;
  static const _recordState = 0x04;
  static const _recordSeen = 0x05;

  final File file;
  final int maximumQueuedPackets;
  final int maximumMessages;
  final int maximumSeenPackets;
  final int compactionThresholdBytes;
  final ChatPacketCodec codec;
  final DateTime Function() _clock;

  final Map<String, ChatPacket> _packets = {};
  final Map<String, ChatMessage> _messages = {};
  final Map<String, int> _messageBytes = {};
  final Map<String, MessageState> _states = {};
  final Map<String, DateTime> _seen = {};
  final Set<String> _incompatiblePackets = {};

  RandomAccessFile? _handle;
  Future<void> _writes = Future<void>.value();
  Future<void> _operations = Future<void>.value();
  bool _writeFailed = false;
  bool _open = false;

  /// Bytes of log that no longer describe live state, used to decide when
  /// rewriting the file is cheaper than continuing to append.
  int _deadBytes = 0;

  @override
  Future<void> open() async {
    if (_open) return;
    await file.parent.create(recursive: true);
    if (!file.existsSync()) {
      await file.writeAsBytes(_header(), flush: true);
    }
    await _load();
    _handle = await file.open(mode: FileMode.append);
    _open = true;
    // Expiry is enforced on read, but compacting here keeps a store that sat
    // unopened for a long time from replaying a large dead log every launch.
    if (_shouldCompact || file.lengthSync() > compactionThresholdBytes * 4) {
      await _compact();
    }
  }

  @override
  Future<void> enqueue(ChatPacket packet) => _mutate(() async {
    _requireOpen();
    _purgeExpiredSeen();
    if (!_packets.containsKey(packet.id) &&
        _packets.values.where((item) => !item.isExpired(_clock())).length >=
            maximumQueuedPackets) {
      throw MessageStoreFullException(
        queuedPackets: _packets.length,
        maximumQueuedPackets: maximumQueuedPackets,
      );
    }
    final encoded = codec.encode(packet);
    await _append(_recordEnqueue, encoded);
    final old = _packets[packet.id];
    if (old != null) _deadBytes += codec.encode(old).length;
    _packets[packet.id] = packet;
  });

  @override
  Future<void> remove(String packetId) => _mutate(() async {
    _requireOpen();
    final removed = _packets[packetId];
    if (removed == null) return;
    await _append(_recordRemove, utf8.encode(packetId));
    _packets.remove(packetId);
    _deadBytes += codec.encode(removed).length;
  });

  @override
  Future<List<ChatPacket>> queued() async {
    _requireOpen();
    _purgeExpiredSeen();
    return List.unmodifiable(
      _packets.values.where((item) => !item.isExpired(_clock())),
    );
  }

  @override
  Future<List<ChatPacket>> expiredQueued() async {
    _requireOpen();
    return List.unmodifiable(
      _packets.values.where((item) => item.isExpired(_clock())),
    );
  }

  @override
  Future<void> saveMessage(ChatMessage message) => _mutate(() async {
    _requireOpen();
    if (_messages.containsKey(message.id)) return;
    final payload = utf8.encode(jsonEncode(_encodeMessage(message)));
    await _append(_recordMessage, payload);
    _messages[message.id] = message;
    _messageBytes[message.id] = payload.length;
    while (_messages.length > maximumMessages) {
      final oldest = _messages.keys.first;
      _messages.remove(oldest);
      _states.remove(oldest);
      _deadBytes += _messageBytes.remove(oldest) ?? 0;
    }
  });

  @override
  Future<List<ChatMessage>> messages() async {
    _requireOpen();
    return List.unmodifiable(_messages.values);
  }

  @override
  Future<void> saveState(String messageId, MessageState state) =>
      _mutate(() async {
        _requireOpen();
        if (_states[messageId] == state) return;
        await _append(
          _recordState,
          utf8.encode(jsonEncode({'id': messageId, 'state': state.name})),
        );
        if (_states.containsKey(messageId)) _deadBytes += 48;
        _states[messageId] = state;
      });

  @override
  Future<Map<String, MessageState>> states() async {
    _requireOpen();
    return Map.unmodifiable(_states);
  }

  @override
  Future<void> rememberSeen(String packetId, DateTime expiresAt) =>
      _mutate(() async {
        _requireOpen();
        _purgeExpiredSeen();
        if (_seen.containsKey(packetId)) return;
        if (_seen.length >= maximumSeenPackets) {
          throw SeenPacketQuotaException(maximumSeenPackets);
        }
        await _append(
          _recordSeen,
          utf8.encode(
            jsonEncode({
              'id': packetId,
              'expiresAt': expiresAt.toUtc().millisecondsSinceEpoch,
            }),
          ),
        );
        _seen[packetId] = expiresAt;
      });

  @override
  Future<Map<String, DateTime>> seen() async {
    _requireOpen();
    _purgeExpiredSeen();
    return Map.unmodifiable(_seen);
  }

  @override
  Future<bool> hasSeen(String packetId) async {
    _requireOpen();
    _purgeExpiredSeen();
    return _seen.containsKey(packetId);
  }

  @override
  Future<void> close() async {
    if (!_open) return;
    await _operations;
    _open = false;
    await _writes;
    try {
      if (!_writeFailed) await _handle?.flush();
    } finally {
      await _handle?.close();
      _handle = null;
      _packets.clear();
      _messages.clear();
      _messageBytes.clear();
      _states.clear();
      _seen.clear();
      _incompatiblePackets.clear();
      _deadBytes = 0;
      _writeFailed = false;
    }
  }

  bool get _shouldCompact =>
      _deadBytes > compactionThresholdBytes &&
      _deadBytes * 3 >= file.lengthSync();

  /// Keeps disk writes, in-memory state, and compaction in the same order.
  Future<void> _mutate(Future<void> Function() operation) {
    final result = _operations.then((_) async {
      await operation();
      if (_shouldCompact) await _compact();
    });
    _operations = result.catchError((Object _) {});
    return result;
  }

  void _requireOpen() {
    if (!_open) throw StateError('FileMessageStore.open() has not completed');
  }

  void _purgeExpiredSeen() {
    final now = _clock();
    _seen.removeWhere((_, expiry) {
      if (expiry.isAfter(now)) return false;
      _deadBytes += 64;
      return true;
    });
  }

  /// Serializes appends so two concurrent callers cannot interleave a record.
  Future<void> _append(int type, List<int> payload) {
    final record = _frame(type, payload);
    final write = _writes.then((_) async {
      if (_writeFailed) {
        throw StateError('store write failed; close and reopen before writing');
      }
      final handle = _handle;
      if (handle == null) throw StateError('message store is closed');
      try {
        await handle.writeFrom(record);
        await handle.flush();
      } on Object {
        // A partial append can leave a torn record. Reopening trims it before
        // any later append, so no record is hidden behind the torn tail.
        _writeFailed = true;
        rethrow;
      }
    });
    _writes = write.catchError((Object _) {});
    return write;
  }

  Uint8List _header() {
    final bytes = BytesBuilder()..add(utf8.encode(_magic));
    final version = ByteData(2)..setUint16(0, _version);
    bytes.add(version.buffer.asUint8List());
    return bytes.toBytes();
  }

  Uint8List _frame(int type, List<int> payload) {
    final header = ByteData(5)
      ..setUint8(0, type)
      ..setUint32(1, payload.length);
    final checksum = ByteData(4)..setUint32(0, _crc32(payload));
    return (BytesBuilder()
          ..add(header.buffer.asUint8List())
          ..add(payload)
          ..add(checksum.buffer.asUint8List()))
        .toBytes();
  }

  Future<void> _load() async {
    final bytes = await file.readAsBytes();
    final magic = utf8.encode(_magic);
    if (bytes.length < magic.length + 2) {
      // Header never made it to disk. Start over rather than fail: there can
      // be no records behind a header this short.
      await file.writeAsBytes(_header(), flush: true);
      return;
    }
    for (var index = 0; index < magic.length; index++) {
      if (bytes[index] != magic[index]) {
        throw const FormatException('not a ble_mesh message store');
      }
    }
    final view = ByteData.sublistView(bytes);
    final version = view.getUint16(magic.length);
    if (version > _version) {
      throw MessageStoreVersionException(found: version, supported: _version);
    }

    var offset = magic.length + 2;
    var lastGood = offset;
    while (offset + 5 <= bytes.length) {
      final type = view.getUint8(offset);
      final length = view.getUint32(offset + 1);
      final payloadStart = offset + 5;
      final payloadEnd = payloadStart + length;
      if (payloadEnd + 4 > bytes.length) break;
      final payload = Uint8List.sublistView(bytes, payloadStart, payloadEnd);
      if (view.getUint32(payloadEnd) != _crc32(payload)) break;
      if (!_apply(type, payload)) break;
      offset = payloadEnd + 4;
      lastGood = offset;
    }

    for (final id in _incompatiblePackets) {
      if (_states[id] != MessageState.delivered) {
        _states[id] = MessageState.failed;
      }
    }
    if (lastGood != bytes.length) {
      // A torn tail from an abrupt exit. Everything up to lastGood is intact,
      // so trim rather than discard the file.
      final handle = await file.open(mode: FileMode.append);
      await handle.truncate(lastGood);
      await handle.close();
    }
  }

  /// Returns false when a record is structurally valid but undecodable, which
  /// is treated the same as a tear.
  bool _apply(int type, Uint8List payload) {
    try {
      switch (type) {
        case _recordEnqueue:
          // Older signatures use ambiguous field boundaries. Never resend
          // them, but preserve history and later records during an upgrade.
          if (payload.length >= 46 && payload[2] < 3) {
            _incompatiblePackets.add(
              packetIdToHex(Uint8List.sublistView(payload, 22, 38)),
            );
            return true;
          }
          final packet = codec.decode(payload);
          _packets[packet.id] = packet;
        case _recordRemove:
          _packets.remove(utf8.decode(payload));
        case _recordMessage:
          final message = _decodeMessage(
            jsonDecode(utf8.decode(payload)) as Map<String, dynamic>,
          );
          if (_messageBytes.containsKey(message.id)) {
            _deadBytes += _messageBytes[message.id]!;
          }
          _messages[message.id] = message;
          _messageBytes[message.id] = payload.length;
          while (_messages.length > maximumMessages) {
            final oldest = _messages.keys.first;
            _messages.remove(oldest);
            _states.remove(oldest);
            _deadBytes += _messageBytes.remove(oldest) ?? 0;
          }
        case _recordState:
          final json = jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;
          final name = json['state'] as String;
          _states[json['id'] as String] = MessageState.values.firstWhere(
            (value) => value.name == name,
          );
        case _recordSeen:
          final json = jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;
          _seen[json['id'] as String] = DateTime.fromMillisecondsSinceEpoch(
            json['expiresAt'] as int,
            isUtc: true,
          );
        default:
          // An unknown type from a newer minor build: skip it rather than
          // discard everything after it.
          return true;
      }
      return true;
    } on Object {
      return false;
    }
  }

  /// Rewrites the log as the shortest sequence describing current state.
  Future<void> _compact() async {
    _purgeExpiredSeen();
    await _writes;
    final builder = BytesBuilder()..add(_header());
    for (final packet in _packets.values) {
      builder.add(_frame(_recordEnqueue, codec.encode(packet)));
    }
    for (final message in _messages.values) {
      builder.add(
        _frame(
          _recordMessage,
          utf8.encode(jsonEncode(_encodeMessage(message))),
        ),
      );
    }
    for (final entry in _states.entries) {
      builder.add(
        _frame(
          _recordState,
          utf8.encode(jsonEncode({'id': entry.key, 'state': entry.value.name})),
        ),
      );
    }
    for (final entry in _seen.entries) {
      builder.add(
        _frame(
          _recordSeen,
          utf8.encode(
            jsonEncode({
              'id': entry.key,
              'expiresAt': entry.value.toUtc().millisecondsSinceEpoch,
            }),
          ),
        ),
      );
    }

    // Write beside the log and rename: a crash mid-compaction leaves the
    // original untouched, because rename is atomic within a filesystem.
    final temporary = File('${file.path}.compacting');
    await temporary.writeAsBytes(builder.toBytes(), flush: true);
    await _handle?.close();
    try {
      await temporary.rename(file.path);
    } finally {
      _handle = await file.open(mode: FileMode.append);
    }
    _deadBytes = 0;
  }

  Map<String, Object?> _encodeMessage(ChatMessage message) => {
    'id': message.id,
    'conversationId': message.conversationId,
    'threadId': message.threadId,
    'isDirect': message.isDirect,
    'senderId': message.senderId,
    'text': message.text,
    'createdAt': message.createdAt.toUtc().millisecondsSinceEpoch,
    'isLocal': message.isLocal,
  };

  ChatMessage _decodeMessage(Map<String, dynamic> json) => ChatMessage(
    id: json['id'] as String,
    conversationId: json['conversationId'] as String,
    threadId: json['threadId'] as String,
    isDirect: json['isDirect'] as bool,
    senderId: json['senderId'] as String,
    text: json['text'] as String,
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      json['createdAt'] as int,
      isUtc: true,
    ),
    isLocal: json['isLocal'] as bool,
  );
}

int _crc32(List<int> bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}
