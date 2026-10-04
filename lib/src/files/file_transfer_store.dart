import 'dart:typed_data';

/// Lifecycle of a direct file transfer. Completion requires a verified receipt.
enum FileTransferState {
  /// Waiting for recipient consent.
  offered,

  /// Moving verified chunks.
  transferring,

  /// Waiting for reconnect or an explicit resume.
  paused,

  /// Complete file hash verified by the recipient.
  completed,

  /// Recipient declined the offer.
  rejected,

  /// Either participant cancelled the transfer.
  cancelled,

  /// File integrity or protocol failure.
  failed,
}

/// Immutable metadata and durable checkpoint; file bytes live in the store.
class FileTransfer {
  /// Creates a checkpoint. IDs are random 32-character lowercase hex strings.
  const FileTransfer({
    required this.id,
    required this.peerId,
    required this.fileName,
    required this.mimeType,
    required this.byteLength,
    required this.sha256,
    required this.outgoing,
    required this.state,
    this.offset = 0,
    this.error,
    this.sourceId,
  });

  /// Transfer identifier, scoped to this store/account.
  final String id;

  /// Optional host-provided identity shared by another delivery route.
  final String? sourceId;

  /// Authorized remote peer.
  final String peerId;

  /// Display name only, never a filesystem path.
  final String fileName;

  /// Declared content type.
  final String mimeType;

  /// Expected complete file size.
  final int byteLength;

  /// Expected complete-file SHA-256 hex digest.
  final String sha256;

  /// Whether this device owns the source file.
  final bool outgoing;

  /// Current lifecycle.
  final FileTransferState state;

  /// Durable byte offset acknowledged by the recipient.
  final int offset;

  /// Last user-visible failure, if any.
  final String? error;

  /// Whether no further data should be sent or accepted.
  bool get terminal => const {
    FileTransferState.completed,
    FileTransferState.rejected,
    FileTransferState.cancelled,
    FileTransferState.failed,
  }.contains(state);

  /// Advances a checkpoint without changing the file identity.
  FileTransfer checkpoint(
    FileTransferState state, {
    int? offset,
    String? error,
  }) => FileTransfer(
    id: id,
    peerId: peerId,
    fileName: fileName,
    mimeType: mimeType,
    byteLength: byteLength,
    sha256: sha256,
    outgoing: outgoing,
    state: state,
    offset: offset ?? this.offset,
    error: error,
    sourceId: sourceId,
  );

  /// JSON metadata; never embeds file contents.
  Map<String, Object?> toJson() => {
    'id': id,
    'peerId': peerId,
    'fileName': fileName,
    'mimeType': mimeType,
    'byteLength': byteLength,
    'sha256': sha256,
    'outgoing': outgoing,
    'state': state.name,
    'offset': offset,
    'error': error,
    if (sourceId != null) 'sourceId': sourceId,
  };

  /// Restores trusted local metadata.
  factory FileTransfer.fromJson(Map<String, dynamic> json) => FileTransfer(
    id: json['id'] as String,
    peerId: json['peerId'] as String,
    fileName: json['fileName'] as String,
    mimeType: json['mimeType'] as String,
    byteLength: json['byteLength'] as int,
    sha256: json['sha256'] as String,
    outgoing: json['outgoing'] as bool,
    state: FileTransferState.values.byName(json['state'] as String),
    offset: json['offset'] as int,
    error: json['error'] as String?,
    sourceId: json['sourceId'] as String?,
  );
}

/// Host storage contract. Flush bytes before saving the new offset. Use an
/// account-specific store and retain it across service restarts for resume.
abstract interface class FileTransferStore {
  /// All retained checkpoints.
  Future<List<FileTransfer>> list();

  /// Checkpoint or null when unknown.
  Future<FileTransfer?> get(String id);

  /// Atomically saves metadata.
  Future<void> save(FileTransfer transfer);

  /// Writes bytes at an absolute offset, including overwrite on retry.
  Future<void> write(String id, int offset, Uint8List bytes);

  /// Reads bytes beginning at [offset], up to [length].
  Future<Uint8List> read(String id, int offset, int length);

  /// Removes metadata and bytes. Call only when the transfer is not running.
  Future<void> delete(String id);
}

/// In-memory implementation for tests and hosts that do not require restart
/// recovery. Use FileSystemFileTransferStore from file_store.dart for durable files.
class InMemoryFileTransferStore implements FileTransferStore {
  final _records = <String, FileTransfer>{};
  final _bytes = <String, Uint8List>{};
  @override
  Future<List<FileTransfer>> list() async => _records.values.toList();
  @override
  Future<FileTransfer?> get(String id) async => _records[id];
  @override
  Future<void> save(FileTransfer transfer) async {
    _records[transfer.id] = transfer;
  }

  @override
  Future<void> write(String id, int offset, Uint8List bytes) async {
    final old = _bytes[id] ?? Uint8List(0);
    final data = Uint8List(
      old.length > offset + bytes.length ? old.length : offset + bytes.length,
    );
    data.setRange(0, old.length, old);
    data.setRange(offset, offset + bytes.length, bytes);
    _bytes[id] = data;
  }

  @override
  Future<Uint8List> read(String id, int offset, int length) async {
    final data = _bytes[id] ?? Uint8List(0);
    if (offset < 0 || length < 0 || offset > data.length) {
      throw RangeError('file range');
    }
    return Uint8List.fromList(
      data.sublist(offset, (offset + length).clamp(0, data.length)),
    );
  }

  @override
  Future<void> delete(String id) async {
    _records.remove(id);
    _bytes.remove(id);
  }
}
