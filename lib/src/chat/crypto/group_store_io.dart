import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'group_crypto.dart';

/// Group keys use the same native vault as the identity on Android and Apple.
class PlatformGroupStore implements GroupStore {
  /// Creates a store that uses [fallback] only off Android, iOS, and macOS.
  ///
  /// On those platforms a missing or unavailable vault throws instead of
  /// falling back to plaintext.
  PlatformGroupStore({required this.fallback});

  static const _channel = MethodChannel('dev.blemesh.ble_mesh/keys');
  static const _storageKey = 'ble_mesh.groups.v1';

  /// Plaintext store used on platforms without the native vault.
  final FileGroupStore fallback;

  @override
  Future<Map<String, ChatGroup>> load() async {
    try {
      final available = await _channel.invokeMethod<bool>('isAvailable');
      if (available != true) {
        if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
          throw StateError('secure group storage unavailable');
        }
        return await fallback.load();
      }
      final data = await _channel.invokeMethod<Uint8List>('read', {
        'key': _storageKey,
      });
      if (data == null) return {};
      final decoded = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
      if (decoded.length > 256) throw const FormatException('too many groups');
      return decoded.map(
        (id, item) => MapEntry(
          id,
          ChatGroup.fromJson((item as Map).cast<String, dynamic>()),
        ),
      );
    } on MissingPluginException {
      if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) rethrow;
      return await fallback.load();
    }
  }

  @override
  Future<void> save(Map<String, ChatGroup> groups) async {
    final data = Uint8List.fromList(
      utf8.encode(
        jsonEncode(groups.map((id, group) => MapEntry(id, group.toJson()))),
      ),
    );
    try {
      final available = await _channel.invokeMethod<bool>('isAvailable');
      if (available != true) {
        if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
          throw StateError('secure group storage unavailable');
        }
        return await fallback.save(groups);
      }
      await _channel.invokeMethod<void>('write', {
        'key': _storageKey,
        'value': data,
      });
    } on MissingPluginException {
      if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) rethrow;
      await fallback.save(groups);
    }
  }
}

/// Explicit plaintext fallback for unsupported platforms and local development.
class FileGroupStore implements GroupStore {
  /// Creates a store backed by [file].
  FileGroupStore(this.file);

  /// JSON file holding group keys in plaintext. Writes go through a
  /// temporary file and rename.
  final File file;
  Future<void> _writes = Future<void>.value();

  @override
  Future<Map<String, ChatGroup>> load() async {
    if (!await file.exists()) return {};
    final decoded =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if (decoded.length > 256) throw const FormatException('too many groups');
    return decoded.map(
      (id, item) => MapEntry(
        id,
        ChatGroup.fromJson((item as Map).cast<String, dynamic>()),
      ),
    );
  }

  @override
  Future<void> save(Map<String, ChatGroup> groups) {
    if (groups.length > 256) throw const FormatException('too many groups');
    final write = _writes.then((_) async {
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.pending');
      await temporary.writeAsString(
        jsonEncode(groups.map((id, group) => MapEntry(id, group.toJson()))),
        flush: true,
      );
      await temporary.rename(file.path);
    });
    _writes = write.catchError((Object _) {});
    return write;
  }
}
