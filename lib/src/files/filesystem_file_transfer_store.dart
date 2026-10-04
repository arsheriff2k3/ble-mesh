import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'file_transfer_store.dart';

/// Durable file transfer storage. Use one private directory per account. File
/// names are random IDs, never sender-supplied names. Metadata is atomically
/// replaced only after the corresponding data write has been flushed.
class FileSystemFileTransferStore implements FileTransferStore {
  /// Creates a store; directory creation is lazy.
  FileSystemFileTransferStore({required this.directory});

  /// Private account-scoped directory, not public/download storage.
  final Directory directory;
  File _file(String id, String extension) {
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(id)) {
      throw ArgumentError('invalid transfer id');
    }
    return File('${directory.path}/$id.$extension');
  }

  @override
  Future<List<FileTransfer>> list() async {
    if (!await directory.exists()) return [];
    final result = <FileTransfer>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File && entity.path.endsWith('.json')) {
        final json =
            jsonDecode(await entity.readAsString()) as Map<String, dynamic>;
        final record = FileTransfer.fromJson(json);
        if (_file(record.id, 'json').path != entity.path) {
          throw const FormatException('mismatched file id');
        }
        result.add(record);
      }
    }
    return result;
  }

  @override
  Future<FileTransfer?> get(String id) async {
    final file = _file(id, 'json');
    if (!await file.exists()) return null;
    final record = FileTransfer.fromJson(
      jsonDecode(await file.readAsString()) as Map<String, dynamic>,
    );
    if (record.id != id) throw const FormatException('mismatched file id');
    return record;
  }

  @override
  Future<void> save(FileTransfer transfer) async {
    await directory.create(recursive: true);
    final target = _file(transfer.id, 'json');
    final temporary = _file(transfer.id, 'tmp');
    await temporary.writeAsString(jsonEncode(transfer.toJson()), flush: true);
    await temporary.rename(target.path);
  }

  @override
  Future<void> write(String id, int offset, Uint8List bytes) async {
    if (offset < 0) throw RangeError('negative offset');
    await directory.create(recursive: true);
    final file = _file(id, 'bin');
    if (!await file.exists()) await file.create();
    final handle = await file.open(mode: FileMode.writeOnlyAppend);
    try {
      await handle.setPosition(offset);
      await handle.writeFrom(bytes);
      await handle.flush();
    } finally {
      await handle.close();
    }
  }

  @override
  Future<Uint8List> read(String id, int offset, int length) async {
    if (offset < 0 || length < 0) throw RangeError('invalid range');
    final file = _file(id, 'bin');
    if (!await file.exists()) return Uint8List(0);
    final handle = await file.open();
    try {
      await handle.setPosition(offset);
      return await handle.read(length);
    } finally {
      await handle.close();
    }
  }

  @override
  Future<void> delete(String id) async {
    for (final ext in ['json', 'bin', 'tmp']) {
      final file = _file(id, ext);
      if (await file.exists()) await file.delete();
    }
  }
}
