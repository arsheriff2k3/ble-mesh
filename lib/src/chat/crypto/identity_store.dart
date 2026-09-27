import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'chat_keys.dart';
import 'identity_store_base.dart';
import 'trust_store.dart';

export 'identity_store_base.dart';

/// Keeps private keys in the platform keystore.
///
/// Android wraps the seeds with a Keystore key; iOS/macOS store them in
/// Keychain. Falls back to [FileIdentityStore] on other platforms. Storage
/// errors on supported platforms propagate without replacing the identity.
class PlatformIdentityStore implements IdentityStore {
  /// Creates a store that uses [fallback] where no keystore is available.
  PlatformIdentityStore({required this.fallback});

  static const _channel = MethodChannel('dev.blemesh.ble_mesh/keys');
  static const _identityKey = 'ble_mesh.identity.v2';
  static const _signingKey = 'ble_mesh.identity.signing';
  static const _agreementKey = 'ble_mesh.identity.agreement';

  /// Used when the platform has no secure storage implementation.
  final FileIdentityStore fallback;

  bool? _platformAvailable;

  Future<bool> get _available async {
    final cached = _platformAvailable;
    if (cached != null) return cached;
    try {
      final result = await _channel.invokeMethod<bool>('isAvailable');
      return _platformAvailable = result ?? false;
    } on MissingPluginException {
      if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) rethrow;
      return _platformAvailable = false;
    }
  }

  @override
  Future<ChatKeyPair?> load() async {
    if (!await _available) return fallback.load();
    final bundle = await _channel.invokeMethod<Uint8List>('read', {
      'key': _identityKey,
    });
    if (bundle != null) {
      if (bundle.length != 64) {
        throw const FormatException('invalid stored identity');
      }
      return ChatKeyPair.fromPrivateBytes(
        signingSeed: bundle.sublist(0, 32),
        agreementSeed: bundle.sublist(32),
      );
    }
    // Migrate the original two-item identity without generating new keys.
    final signing = await _channel.invokeMethod<Uint8List>('read', {
      'key': _signingKey,
    });
    final agreement = await _channel.invokeMethod<Uint8List>('read', {
      'key': _agreementKey,
    });
    if (signing == null && agreement == null) return null;
    if (signing == null || agreement == null) {
      throw const FormatException('incomplete stored identity');
    }
    final keys = await ChatKeyPair.fromPrivateBytes(
      signingSeed: signing,
      agreementSeed: agreement,
    );
    await save(keys);
    return keys;
  }

  @override
  Future<void> save(ChatKeyPair keys) async {
    if (!await _available) return fallback.save(keys);
    final seeds = await keys.extractSeeds();
    await _channel.invokeMethod<void>('write', {
      'key': _identityKey,
      'value': Uint8List.fromList([...seeds.signing, ...seeds.agreement]),
    });
  }

  @override
  Future<void> erase() async {
    if (!await _available) return fallback.erase();
    await _channel.invokeMethod<void>('delete', {'key': _signingKey});
    await _channel.invokeMethod<void>('delete', {'key': _agreementKey});
    await _channel.invokeMethod<void>('delete', {'key': _identityKey});
  }

  // Pinned peer keys are public, so they do not need the keystore.
  @override
  Future<TrustStore> loadTrust() => fallback.loadTrust();

  @override
  Future<void> saveTrust(TrustStore store) => fallback.saveTrust(store);
}

/// Identity kept in ordinary files.
///
/// Honest about what it is: a rooted or jailbroken device can read these
/// bytes. It exists so desktop and test runs work, and as the fallback when a
/// platform offers no keystore.
class FileIdentityStore implements IdentityStore {
  /// Creates a store that writes into [directory], creating it on save.
  FileIdentityStore({required this.directory});

  /// Directory holding `identity.keys` (base64 private seeds in JSON) and
  /// `trusted.peers`. The seeds are not encrypted.
  final Directory directory;
  Future<void> _writes = Future<void>.value();

  Future<void> _atomicWrite(File target, String data) {
    final write = _writes.then((_) async {
      final temporary = File('${target.path}.pending');
      await temporary.writeAsString(data, flush: true);
      await temporary.rename(target.path);
    });
    _writes = write.catchError((Object _) {});
    return write;
  }

  File get _identityFile => File('${directory.path}/identity.keys');
  File get _trustFile => File('${directory.path}/trusted.peers');

  @override
  Future<ChatKeyPair?> load() async {
    if (!_identityFile.existsSync()) return null;
    try {
      final json = jsonDecode(
        await _identityFile.readAsString(),
      ) as Map<String, dynamic>;
      return await ChatKeyPair.fromPrivateBytes(
        signingSeed: base64Decode(json['signing'] as String),
        agreementSeed: base64Decode(json['agreement'] as String),
      );
    } on Object {
      rethrow;
    }
  }

  @override
  Future<void> save(ChatKeyPair keys) async {
    await directory.create(recursive: true);
    final seeds = await keys.extractSeeds();
    await _atomicWrite(
      _identityFile,
      jsonEncode({
        'signing': base64Encode(seeds.signing),
        'agreement': base64Encode(seeds.agreement),
      }),
    );
  }

  @override
  Future<void> erase() async {
    if (_identityFile.existsSync()) await _identityFile.delete();
  }

  @override
  Future<TrustStore> loadTrust() async {
    if (!_trustFile.existsSync()) return TrustStore();
    try {
      final json =
          jsonDecode(await _trustFile.readAsString()) as Map<String, dynamic>;
      return TrustStore(
        pinned: json.map(
          (peerId, encoded) => MapEntry(
            peerId,
            ChatPublicKeys.decode(base64Decode(encoded as String)),
          ),
        ),
      );
    } on Object {
      rethrow;
    }
  }

  @override
  Future<void> saveTrust(TrustStore store) async {
    await directory.create(recursive: true);
    await _atomicWrite(
      _trustFile,
      jsonEncode(
        store.pinned.map(
          (peerId, keys) => MapEntry(peerId, base64Encode(keys.encode())),
        ),
      ),
    );
  }
}
