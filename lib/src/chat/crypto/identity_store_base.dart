import 'chat_keys.dart';
import 'trust_store.dart';

/// Where a device's long-term private keys live.
abstract interface class IdentityStore {
  /// Loads the stored identity, or null on a device that has never had one.
  Future<ChatKeyPair?> load();

  /// Persists [keys] and returns them.
  Future<void> save(ChatKeyPair keys);

  /// Destroys the identity. The next [load] returns null.
  Future<void> erase();

  /// Loads and persists pinned peer keys.
  Future<TrustStore> loadTrust();

  /// Persists the pinned peer keys in [store].
  Future<void> saveTrust(TrustStore store);
}

/// Loads the stored identity or creates and persists a new one.
Future<ChatKeyPair> loadOrCreateIdentity(IdentityStore store) async {
  final existing = await store.load();
  if (existing != null) return existing;
  final created = await ChatKeyPair.generate();
  await store.save(created);
  return created;
}
