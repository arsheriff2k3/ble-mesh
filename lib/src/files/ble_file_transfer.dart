import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../chat/chat_models.dart';
import '../chat/chat_transport.dart';
import '../chat/crypto/packet_security.dart';
import '../chat/inbound_policy.dart';
import 'file_transfer_store.dart';

/// Encrypted, consent-based direct file sharing over a local packet transport.
///
/// Shares a transport/security instance with chat, but owns separate storage
/// and streams. The host starts/stops the transport, pins peer keys, renders
/// offers and calls [accept]. Use [resume] after reconnect or process restart.
/// No internet bridging or mesh forwarding is performed.
class BleFileTransfer {
  /// Creates a service. Defaults allow 5 MiB images/videos, 2 MiB documents and
  /// 16 MiB retained bytes.
  /// Only one outgoing transfer runs at a time per peer. Limits include source
  /// files and all retained incoming offers, so delete old records when needed.
  BleFileTransfer({
    required this.transport,
    required this.security,
    required this.store,
    this.namespace,
    this.maximumFileBytes = 2 * 1024 * 1024,
    this.maximumImageBytes = 5 * 1024 * 1024,
    this.maximumVideoBytes = 5 * 1024 * 1024,
    this.maximumStoredBytes = 16 * 1024 * 1024,
    this.maximumTransfers = 128,
    this.chunkBytes = 4096,
    this.checkpointBytes = 4096,
    this.responseTimeout = const Duration(seconds: 15),
    this.maximumRetries = 3,
  }) {
    if (transport is RelayChatTransport ||
        (namespace != null && (namespace!.isEmpty || namespace!.length > 64)) ||
        maximumFileBytes < 1 ||
        maximumImageBytes < 1 ||
        maximumVideoBytes < 1 ||
        maximumStoredBytes < maximumFileBytes ||
        maximumStoredBytes < maximumImageBytes ||
        maximumStoredBytes < maximumVideoBytes ||
        maximumTransfers < 1 ||
        chunkBytes < 1 ||
        chunkBytes > 8192 ||
        checkpointBytes < 1 ||
        checkpointBytes > 256 * 1024 ||
        maximumRetries < 0 ||
        responseTimeout <= Duration.zero) {
      throw ArgumentError('invalid local file transfer configuration');
    }
  }

  /// Local transport; never owned or stopped by this service.
  final ChatTransport transport;

  /// Shared identity and pinned peer keys. Unknown peers cannot offer files.
  final PacketSecurity security;

  /// Account-scoped source, destination and checkpoint storage.
  final FileTransferStore store;

  /// Optional application channel. Null preserves the original wire protocol.
  /// Separate channels can share one radio without mixing file offers.
  final String? namespace;

  /// Maximum size of a PDF or Word document.
  final int maximumFileBytes;

  /// Maximum size of a JPEG, PNG, HEIF or HEIC image.
  final int maximumImageBytes;

  /// Maximum size of an MP4, MOV or WebM video.
  final int maximumVideoBytes;

  /// Maximum declared bytes across retained transfers, including offers.
  final int maximumStoredBytes;

  /// Maximum retained transfer records.
  final int maximumTransfers;

  /// Preferred raw bytes per acknowledged chunk; at most 8192.
  /// The receiver advertises its limit; absent capability falls back to 4096.
  final int chunkBytes;

  /// Bytes between durable progress metadata writes. Data writes are still
  /// flushed before acknowledgement; restart may replay up to this many bytes.
  final int checkpointBytes;

  /// Time to await one response before retrying.
  final Duration responseTimeout;

  /// Additional attempts after the first send.
  final int maximumRetries;

  /// Supported still-image declarations, all using [maximumImageBytes].
  static const supportedImageMimeTypes = <String>{
    'image/jpeg',
    'image/png',
    'image/heif',
    'image/heic',
  };

  /// Supported declared types. Content remains untrusted; hosts must not
  /// execute attachments or treat this declaration as file-type detection.
  static const supportedMimeTypes = <String>{
    ...supportedImageMimeTypes,
    'video/mp4',
    'video/quicktime',
    'video/webm',
    'application/pdf',
    'application/msword',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  };

  final _changes = StreamController<FileTransfer>.broadcast();
  final _errors = StreamController<Object>.broadcast();
  final _records = <String, FileTransfer>{};
  final _durable = <String, FileTransfer>{};
  final _routes = <String, String>{};
  final _workers = <String, Future<void>>{};
  final _pending = <String, Completer<Map<String, dynamic>>>{};
  final _rate = TokenBuckets(
    const InboundRateLimit(burst: 128, perSecond: 64),
    maximumKeys: 1,
  );
  StreamSubscription<ReceivedChatPacket>? _subscription;
  Future<void> _inbound = Future<void>.value();
  Future<void> _mutations = Future<void>.value();
  int _queued = 0;
  bool _started = false;
  bool _disposed = false;

  /// Offers, durable progress, completion and terminal decisions.
  Stream<FileTransfer> get changes => _changes.stream;

  /// Rejected malformed packets and transport/storage errors.
  Stream<Object> get errors => _errors.stream;

  /// Current immutable checkpoints, including offers restored on [start].
  List<FileTransfer> get transfers => List.unmodifiable(_records.values);

  /// Restores checkpoints and subscribes. Does not start the shared transport.
  /// Interrupted transfers become paused; consent and durable offsets survive.
  Future<void> start() => _serial(() async {
    if (_disposed) throw StateError('service disposed');
    if (_started) return;
    for (final record in await store.list()) {
      _validate(record);
      _records[record.id] = record;
      _durable[record.id] = record;
    }
    _checkQuota();
    for (final record in _records.values.toList()) {
      if (record.state == FileTransferState.transferring) {
        await _save(record.checkpoint(FileTransferState.paused));
      }
    }
    _started = true;
    _subscription = transport.incoming.listen(_enqueue);
  });

  /// Persists a source and offers it. Sending starts only after acceptance.
  /// An unavailable radio leaves a paused offer for [resume].
  Future<FileTransfer> offer({
    required String peerId,
    required String fileName,
    required String mimeType,
    required Uint8List bytes,
    String? transferId,
    String? sourceId,
  }) async {
    _requireStarted();
    if (bytes.isEmpty || bytes.length > _byteLimit(mimeType)) {
      throw const FormatException('invalid file size');
    }
    final source = Uint8List.fromList(bytes);
    return _serial(() async {
      _requireStarted();
      if (security.trustStore.keysFor(peerId) == null ||
          peerId == security.identity.peerId) {
        throw ArgumentError('recipient must be a known remote peer');
      }
      final record = FileTransfer(
        id: transferId ?? _id(),
        sourceId: sourceId,
        peerId: peerId,
        fileName: fileName,
        mimeType: mimeType,
        byteLength: source.length,
        sha256: crypto.sha256.convert(source).toString(),
        outgoing: true,
        state: FileTransferState.offered,
      );
      _validate(record);
      final existing = _records[record.id];
      if (existing != null) {
        if (!existing.outgoing ||
            existing.peerId != peerId ||
            existing.sha256 != record.sha256 ||
            existing.byteLength != record.byteLength ||
            existing.mimeType != record.mimeType ||
            existing.fileName != record.fileName ||
            existing.sourceId != sourceId) {
          throw const FormatException(
            'transfer ID already belongs to another file',
          );
        }
        if (!existing.terminal) await _offer(existing);
        return _records[record.id]!;
      }
      _checkQuota(add: record);
      await store.write(record.id, 0, source);
      await _save(record);
      await _offer(record);
      return _records[record.id]!;
    });
  }

  /// Accepts an incoming offer; existing paused transfers keep their offset.
  Future<void> accept(String id) => _serial(() async {
    _requireStarted();
    final record = _record(id);
    if (record.outgoing || record.terminal) {
      throw StateError('not an incoming offer');
    }
    final accepted = record.checkpoint(FileTransferState.transferring);
    await _save(accepted);
    await _send(accepted.peerId, {
      'op': 'ready',
      'chunkBytes': chunkBytes,
      'id': id,
      'offset': accepted.offset,
    });
  });

  /// Re-offers an outgoing transfer after reconnect/restart. A receiver sends
  /// its persisted offset, including a completion receipt if already complete.
  Future<void> resume(String id) => _serial(() async {
    _requireStarted();
    final record = _record(id);
    if (!record.outgoing || record.terminal) throw StateError('not resumable');
    await _offer(record);
  });

  /// Declines an incoming offer and tells its sender.
  Future<void> reject(String id) =>
      _decision(id, FileTransferState.rejected, 'reject');

  /// Cancels a transfer locally and best-effort notifies the other device.
  Future<void> cancel(String id) =>
      _decision(id, FileTransferState.cancelled, 'cancel');

  /// Returns verified incoming bytes only after full-file SHA-256 completion.
  Future<Uint8List> readReceived(String id) async {
    _requireStarted();
    final record = _record(id);
    if (record.outgoing || record.state != FileTransferState.completed) {
      throw StateError('file is not a verified incoming attachment');
    }
    final bytes = await store.read(id, 0, record.byteLength);
    if (bytes.length != record.byteLength ||
        crypto.sha256.convert(bytes).toString() != record.sha256) {
      throw StateError('stored attachment integrity failed');
    }
    return bytes;
  }

  /// Removes a retained terminal transfer and frees its storage quota.
  Future<void> delete(String id) => _serial(() async {
    _requireStarted();
    if (!_record(id).terminal || _workers.containsKey(id)) {
      throw StateError('transfer still active');
    }
    await store.delete(id);
    _records.remove(id);
    _durable.remove(id);
  });

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _mutations.then((_) => action());
    _mutations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> _decision(String id, FileTransferState state, String op) =>
      _serial(() async {
        _requireStarted();
        final record = _record(id);
        if (record.terminal) return;
        if (op == 'reject' && record.outgoing) {
          throw StateError('cannot reject outgoing transfer');
        }
        await _save(record.checkpoint(state));
        await _bestEffort(record.peerId, {'op': op, 'id': id});
      });

  void _enqueue(ReceivedChatPacket received) {
    final packet = received.packet;
    if (_disposed ||
        packet.type != ChatPacketType.fileTransfer ||
        _queued >= 32 ||
        received.transportId != transport.id ||
        packet.payload.length > 12288 ||
        !packet.isSealed ||
        packet.ttl != 1 ||
        packet.bridgeable ||
        packet.destination != 'p:${security.identity.peerId}' ||
        security.trustStore.keysFor(packet.senderId) == null) {
      return;
    }
    if (!_rate.take('files')) return;
    _queued++;
    _inbound = _inbound
        .then((_) => _serial(() => _receive(received)))
        .catchError((Object error) {
          if (!_errors.isClosed) _errors.add(error);
        })
        .whenComplete(() => _queued--);
  }

  Future<void> _receive(ReceivedChatPacket received) async {
    if (_disposed) return;
    final wire = received.packet;
    final now = DateTime.now();
    if (wire.expiresAt.isBefore(now) ||
        wire.createdAt.isAfter(now.add(const Duration(minutes: 1))) ||
        wire.expiresAt.difference(wire.createdAt) >
            const Duration(minutes: 5)) {
      return;
    }
    final verified = await security.admit(
      wire,
      announcedKeys: received.senderKeys,
    );
    final frame =
        jsonDecode(utf8.decode(verified.packet.payload))
            as Map<String, dynamic>;
    if (frame['namespace'] != namespace) return;
    final id = frame['id'];
    if (frame['v'] != 1 ||
        id is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(id)) {
      throw const FormatException('invalid file frame');
    }
    final peer = wire.senderId;
    _routes[peer] = received.routeId;
    final op = frame['op'];
    if (op == 'offer') {
      final incoming = FileTransfer(
        id: id,
        peerId: peer,
        fileName: frame['name'] as String,
        mimeType: frame['mime'] as String,
        sourceId: frame['sourceId'] as String?,
        byteLength: frame['size'] as int,
        sha256: frame['hash'] as String,
        outgoing: false,
        state: FileTransferState.offered,
      );
      _validate(incoming);
      final existing = _records[id];
      if (existing != null) {
        if (existing.outgoing ||
            existing.peerId != peer ||
            existing.fileName != incoming.fileName ||
            existing.mimeType != incoming.mimeType ||
            existing.sourceId != incoming.sourceId ||
            existing.byteLength != incoming.byteLength ||
            existing.sha256 != incoming.sha256) {
          throw const FormatException('conflicting offer');
        }
        if (existing.state == FileTransferState.completed) {
          await _send(peer, {
            'op': 'complete',
            'id': id,
            'offset': existing.offset,
          });
        } else if (existing.state == FileTransferState.transferring ||
            existing.state == FileTransferState.paused) {
          await _save(existing.checkpoint(FileTransferState.transferring));
          await _send(peer, {
            'op': 'ready',
            'chunkBytes': chunkBytes,
            'id': id,
            'offset': existing.offset,
          });
        } else if (existing.terminal) {
          await _send(peer, {'op': 'reject', 'id': id});
        }
      } else {
        _checkQuota(add: incoming);
        if (_records.values
                .where(
                  (r) => !r.outgoing && r.state == FileTransferState.offered,
                )
                .length >=
            8) {
          await _send(peer, {'op': 'reject', 'id': id});
          return;
        }
        await _save(incoming);
      }
      return;
    }
    final record = _records[id];
    if (record == null || record.peerId != peer) return;
    if (op == 'cancel' || op == 'reject') {
      if (!record.terminal && (op == 'cancel' || record.outgoing)) {
        await _save(
          record.checkpoint(
            op == 'cancel'
                ? FileTransferState.cancelled
                : FileTransferState.rejected,
          ),
        );
      }
      return;
    }
    if (record.terminal) {
      if (!record.outgoing &&
          record.state == FileTransferState.completed &&
          op == 'finish') {
        await _reply(record, frame, 'complete', record.offset);
      }
      return;
    }
    if (record.outgoing) {
      final offset = frame['offset'];
      if (offset is! int || offset < 0 || offset > record.byteLength) {
        throw const FormatException('invalid offset');
      }
      if (op == 'ready') {
        if (!_workers.containsKey(id) &&
            !_workers.keys.any((key) => _records[key]?.peerId == peer)) {
          final advertised = frame['chunkBytes'];
          if (advertised != null &&
              (advertised is! int || advertised < 1 || advertised > 8192)) {
            throw const FormatException('invalid receiver chunk capability');
          }
          final supported = advertised is int ? advertised : 4096;
          final work = _run(
            record,
            offset,
            chunkBytes < supported ? chunkBytes : supported,
          );
          _workers[id] = work;
          unawaited(work.whenComplete(() => _workers.remove(id)));
        }
      } else if (op == 'ack' || op == 'complete') {
        final request = frame['request'];
        if (request is String) {
          final waiter = _pending['$id:$request'];
          if (waiter != null && !waiter.isCompleted) waiter.complete(frame);
        } else if (op == 'complete' &&
            offset == record.byteLength &&
            !_workers.containsKey(id)) {
          await _save(
            record.checkpoint(FileTransferState.completed, offset: offset),
          );
        }
      }
      return;
    }
    if (record.state != FileTransferState.transferring) return;
    if (op == 'chunk') {
      final offset = frame['offset'];
      final encoded = frame['data'];
      if (offset is! int ||
          offset < 0 ||
          encoded is! String ||
          encoded.length > ((chunkBytes + 2) ~/ 3) * 4) {
        throw const FormatException('invalid chunk');
      }
      final bytes = base64Decode(encoded);
      if (bytes.isEmpty ||
          bytes.length > chunkBytes ||
          offset + bytes.length > record.byteLength) {
        throw const FormatException('invalid chunk range');
      }
      var checkpoint = record;
      if (offset == record.offset) {
        await store.write(id, offset, bytes);
        checkpoint = record.checkpoint(
          FileTransferState.transferring,
          offset: offset + bytes.length,
        );
        await _save(checkpoint);
      }
      await _reply(checkpoint, frame, 'ack', checkpoint.offset);
    } else if (op == 'finish') {
      if (record.offset != record.byteLength) {
        await _reply(record, frame, 'ack', record.offset);
        return;
      }
      final bytes = await store.read(id, 0, record.byteLength);
      if (bytes.length != record.byteLength ||
          crypto.sha256.convert(bytes).toString() != record.sha256) {
        await _save(
          record.checkpoint(
            FileTransferState.failed,
            error: 'checksum mismatch',
          ),
        );
        await _send(peer, {'op': 'reject', 'id': id});
        return;
      }
      await _save(record.checkpoint(FileTransferState.completed));
      await _reply(record, frame, 'complete', record.offset);
    }
  }

  Future<void> _run(
    FileTransfer source,
    int offset,
    int negotiatedChunkBytes,
  ) async {
    try {
      await _serial(() async {
        if (!_record(source.id).terminal) {
          await _save(
            source.checkpoint(FileTransferState.transferring, offset: offset),
          );
        }
      });
      while (!_disposed &&
          !_record(source.id).terminal &&
          offset < source.byteLength) {
        final bytes = await store.read(source.id, offset, negotiatedChunkBytes);
        if (bytes.isEmpty) throw StateError('source bytes missing');
        final response = await _request(source, {
          'op': 'chunk',
          'offset': offset,
          'data': base64Encode(bytes),
        });
        final next = response['offset'];
        if (response['op'] != 'ack' || next != offset + bytes.length) {
          throw StateError('unexpected chunk acknowledgement');
        }
        offset = next as int;
        await _serial(() async {
          if (!_record(source.id).terminal) {
            await _save(
              _record(
                source.id,
              ).checkpoint(FileTransferState.transferring, offset: offset),
            );
          }
        });
      }
      if (_disposed || _record(source.id).terminal) return;
      final receipt = await _request(source, {'op': 'finish'});
      if (receipt['op'] != 'complete' ||
          receipt['offset'] != source.byteLength) {
        throw StateError('missing verified receipt');
      }
      await _serial(() async {
        if (!_record(source.id).terminal) {
          await _save(
            _record(source.id).checkpoint(
              FileTransferState.completed,
              offset: source.byteLength,
            ),
          );
        }
      });
    } catch (error) {
      if (!_disposed) {
        await _serial(() async {
          final current = _record(source.id);
          if (!current.terminal) {
            await _save(
              current.checkpoint(
                FileTransferState.paused,
                error: error.toString(),
              ),
            );
          }
        });
      }
    }
  }

  Future<Map<String, dynamic>> _request(
    FileTransfer record,
    Map<String, Object?> frame,
  ) async {
    final request = _id();
    final key = '${record.id}:$request';
    final completer = Completer<Map<String, dynamic>>();
    _pending[key] = completer;
    try {
      for (var attempt = 0; attempt <= maximumRetries; attempt++) {
        if (_disposed || _record(record.id).terminal) {
          throw StateError('transfer stopped');
        }
        await _send(record.peerId, {
          ...frame,
          'id': record.id,
          'request': request,
        });
        try {
          return await completer.future.timeout(responseTimeout);
        } on TimeoutException {
          if (attempt == maximumRetries) rethrow;
        }
      }
      throw StateError('retry exhausted');
    } finally {
      _pending.remove(key);
    }
  }

  Future<void> _offer(FileTransfer record) async {
    try {
      await _send(record.peerId, {
        'op': 'offer',
        'id': record.id,
        'name': record.fileName,
        'mime': record.mimeType,
        if (record.sourceId != null) 'sourceId': record.sourceId,
        'size': record.byteLength,
        'hash': record.sha256,
      });
    } catch (error) {
      await _save(
        record.checkpoint(FileTransferState.paused, error: error.toString()),
      );
    }
  }

  Future<void> _reply(
    FileTransfer record,
    Map<String, dynamic> frame,
    String op,
    int offset,
  ) => _send(record.peerId, {
    'op': op,
    'id': record.id,
    'request': frame['request'],
    'offset': offset,
  });

  Future<void> _send(String peer, Map<String, Object?> frame) async {
    if (_disposed || !transport.available) {
      throw StateError('local transport unavailable');
    }
    final now = DateTime.now();
    final packet = await security.protect(
      ChatPacket(
        type: ChatPacketType.fileTransfer,
        packetId: createPacketId(),
        senderId: security.identity.peerId,
        destination: 'p:$peer',
        ttl: 1,
        createdAt: now,
        expiresAt: now.add(const Duration(minutes: 2)),
        payload: Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'v': 1,
              if (namespace != null) 'namespace': namespace,
              ...frame,
            }),
          ),
        ),
      ),
      encrypt: true,
      recipient: security.trustStore.keysFor(peer),
    );
    var result = await transport.send(packet, routeId: _routes[peer]);
    if (!result.sent && _routes.remove(peer) != null) {
      // Reconnects may replace opaque link IDs. Let the local adapter find
      // the peer's new authenticated link instead of retrying the stale one.
      result = await transport.send(packet);
    }
    if (!result.sent) throw StateError('peer route unavailable');
  }

  Future<void> _bestEffort(String peer, Map<String, Object?> frame) async {
    try {
      await _send(peer, frame);
    } catch (error) {
      if (!_errors.isClosed) _errors.add(error);
    }
  }

  Future<void> _save(FileTransfer record) async {
    final durable = _durable[record.id];
    if (durable == null ||
        record.state != durable.state ||
        record.terminal ||
        record.offset == record.byteLength ||
        record.offset < durable.offset ||
        record.offset - durable.offset >= checkpointBytes) {
      await store.save(record);
      _durable[record.id] = record;
    }
    _records[record.id] = record;
    if (record.terminal) {
      for (final entry in _pending.entries) {
        if (entry.key.startsWith('${record.id}:') && !entry.value.isCompleted) {
          entry.value.complete({'op': 'stopped'});
        }
      }
    }
    if (!_changes.isClosed) _changes.add(record);
  }

  void _validate(FileTransfer record) {
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(record.id) ||
        (record.sourceId != null &&
            !RegExp(r'^[a-f0-9]{32}$').hasMatch(record.sourceId!)) ||
        record.peerId.isEmpty ||
        record.fileName.trim().isEmpty ||
        record.fileName.length > 180 ||
        RegExp(r'[/\\\x00-\x1f\x7f]').hasMatch(record.fileName) ||
        !supportedMimeTypes.contains(record.mimeType) ||
        record.byteLength < 1 ||
        record.byteLength > _byteLimit(record.mimeType) ||
        record.offset < 0 ||
        record.offset > record.byteLength ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(record.sha256)) {
      throw const FormatException('invalid file manifest');
    }
  }

  int _byteLimit(String mimeType) => supportedImageMimeTypes.contains(mimeType)
      ? maximumImageBytes
      : mimeType == 'video/mp4' ||
            mimeType == 'video/quicktime' ||
            mimeType == 'video/webm'
      ? maximumVideoBytes
      : maximumFileBytes;

  void _checkQuota({FileTransfer? add}) {
    final records = [..._records.values, ?add];
    if (records.length > maximumTransfers ||
        records.fold<int>(0, (sum, r) => sum + r.byteLength) >
            maximumStoredBytes) {
      throw StateError('file storage quota reached');
    }
  }

  FileTransfer _record(String id) =>
      _records[id] ?? (throw ArgumentError('unknown transfer'));
  String _id() => packetIdToHex(createPacketId());
  void _requireStarted() {
    if (!_started || _disposed) throw StateError('start file service first');
  }

  /// Stops service work, preserving checkpoints. Does not stop the transport.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _subscription?.cancel();
    for (final waiter in _pending.values) {
      if (!waiter.isCompleted) waiter.complete({'op': 'stopped'});
    }
    await _inbound;
    await Future.wait(_workers.values.toList());
    await _mutations;
    for (final record in _records.values) {
      if (_durable[record.id]?.offset != record.offset) {
        await store.save(record);
      }
    }
    await _changes.close();
    await _errors.close();
  }
}
