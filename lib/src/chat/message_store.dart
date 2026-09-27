import 'chat_models.dart';

/// Thrown when the outbound queue is full and the caller's packet was not
/// accepted.
///
/// Rejecting is deliberate: silently dropping an older message to make room
/// would let a burst erase history the user believes is still pending.
class MessageStoreFullException implements Exception {
  /// Creates an exception reporting the queue size against its quota.
  const MessageStoreFullException({
    required this.queuedPackets,
    required this.maximumQueuedPackets,
  });

  /// Packets held in the queue when the packet was rejected, including
  /// expired ones not yet removed.
  final int queuedPackets;

  /// The store's quota of unexpired queued packets.
  final int maximumQueuedPackets;

  @override
  String toString() =>
      'MessageStoreFullException: $queuedPackets of $maximumQueuedPackets '
      'queued packets';
}

/// Thrown rather than forgetting an unexpired packet id and admitting replay.
class SeenPacketQuotaException implements Exception {
  /// Creates an exception for a store whose seen-id quota is
  /// [maximumSeenPackets].
  const SeenPacketQuotaException(this.maximumSeenPackets);

  /// The store's quota of unexpired packet ids.
  final int maximumSeenPackets;

  @override
  String toString() =>
      'SeenPacketQuotaException: $maximumSeenPackets unexpired packet ids';
}

/// Thrown when a store's on-disk format is newer than this build understands.
class MessageStoreVersionException implements Exception {
  /// Creates an exception for a store at version [found].
  const MessageStoreVersionException({
    required this.found,
    required this.supported,
  });

  /// Format version recorded in the store.
  final int found;

  /// Newest format version this build can read.
  final int supported;

  @override
  String toString() =>
      'MessageStoreVersionException: store version $found, this build '
      'supports up to $supported';
}

/// Durable home for the outbound queue, conversations, and message state.
///
/// Implementations must tolerate being reopened after an abrupt termination:
/// a half-written record is expected, not exceptional.
abstract interface class MessageStore {
  /// Loads existing state. Must be called before any other method and must be
  /// safe to call more than once.
  Future<void> open();

  /// Adds a packet awaiting delivery.
  ///
  /// Throws [MessageStoreFullException] when the queue is at quota.
  Future<void> enqueue(ChatPacket packet);

  /// Drops a packet that no longer needs delivery.
  Future<void> remove(String packetId);

  /// Packets still awaiting delivery, oldest first, excluding expired ones.
  Future<List<ChatPacket>> queued();

  /// Expired pending packets, retained until the facade marks them failed.
  Future<List<ChatPacket>> expiredQueued();

  /// Records a message for conversation history.
  Future<void> saveMessage(ChatMessage message);

  /// Every retained message, oldest first.
  Future<List<ChatMessage>> messages();

  /// Records the latest delivery state for a message.
  Future<void> saveState(String messageId, MessageState state);

  /// Latest delivery state per message id.
  Future<Map<String, MessageState>> states();

  /// Remembers a packet id so a replay after restart is still a duplicate.
  Future<void> rememberSeen(String packetId, DateTime expiresAt);

  /// Packet ids seen and not yet expired.
  Future<Map<String, DateTime>> seen();

  /// Checks replay state without copying the whole retained-id index.
  Future<bool> hasSeen(String packetId);

  /// Releases resources. The store must be reopenable afterwards.
  Future<void> close();
}

/// Volatile store. Everything is lost when the process exits, which makes it
/// the right default for tests and for hosts that do not want history on disk.
class InMemoryMessageStore implements MessageStore {
  /// Creates an empty store. [clock] defaults to [DateTime.now] and decides
  /// expiry; it exists for tests.
  InMemoryMessageStore({
    this.maximumQueuedPackets = 1024,
    this.maximumMessages = 4096,
    this.maximumSeenPackets = 65536,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Most unexpired packets [enqueue] accepts before throwing
  /// [MessageStoreFullException]. Defaults to 1024.
  final int maximumQueuedPackets;

  /// Most messages retained; saving beyond this evicts the oldest. Defaults
  /// to 4096.
  final int maximumMessages;

  /// Most unexpired packet ids [rememberSeen] retains before throwing
  /// [SeenPacketQuotaException]. Defaults to 65536.
  final int maximumSeenPackets;
  final DateTime Function() _clock;

  final Map<String, ChatPacket> _packets = {};
  final Map<String, ChatMessage> _messages = {};
  final Map<String, MessageState> _states = {};
  final Map<String, DateTime> _seen = {};

  @override
  Future<void> open() async {}

  @override
  Future<void> enqueue(ChatPacket packet) async {
    _purgeExpiredSeen();
    if (!_packets.containsKey(packet.id) &&
        _packets.values.where((item) => !item.isExpired(_clock())).length >=
            maximumQueuedPackets) {
      throw MessageStoreFullException(
        queuedPackets: _packets.length,
        maximumQueuedPackets: maximumQueuedPackets,
      );
    }
    _packets[packet.id] = packet;
  }

  @override
  Future<void> remove(String packetId) async {
    _packets.remove(packetId);
  }

  @override
  Future<List<ChatPacket>> queued() async {
    _purgeExpiredSeen();
    return List.unmodifiable(
      _packets.values.where((item) => !item.isExpired(_clock())),
    );
  }

  @override
  Future<List<ChatPacket>> expiredQueued() async => List.unmodifiable(
    _packets.values.where((item) => item.isExpired(_clock())),
  );

  @override
  Future<void> saveMessage(ChatMessage message) async {
    _messages[message.id] = message;
    while (_messages.length > maximumMessages) {
      _messages.remove(_messages.keys.first);
    }
  }

  @override
  Future<List<ChatMessage>> messages() async =>
      List.unmodifiable(_messages.values);

  @override
  Future<void> saveState(String messageId, MessageState state) async {
    _states[messageId] = state;
  }

  @override
  Future<Map<String, MessageState>> states() async => Map.unmodifiable(_states);

  @override
  Future<void> rememberSeen(String packetId, DateTime expiresAt) async {
    _purgeExpiredSeen();
    if (!_seen.containsKey(packetId) && _seen.length >= maximumSeenPackets) {
      throw SeenPacketQuotaException(maximumSeenPackets);
    }
    _seen[packetId] = expiresAt;
  }

  @override
  Future<Map<String, DateTime>> seen() async {
    _purgeExpiredSeen();
    return Map.unmodifiable(_seen);
  }

  @override
  Future<bool> hasSeen(String packetId) async {
    _purgeExpiredSeen();
    return _seen.containsKey(packetId);
  }

  @override
  Future<void> close() async {}

  void _purgeExpiredSeen() {
    final now = _clock();
    _seen.removeWhere((_, expiry) => !expiry.isAfter(now));
  }
}

/// Bounded in-memory set of recently seen packet ids, each kept until it
/// expires.
///
/// Unlike [MessageStore.rememberSeen], a full cache evicts its oldest entry
/// instead of refusing, so it is a fast first filter rather than the durable
/// replay record.
class DedupeCache {
  /// Creates an empty cache. [clock] defaults to [DateTime.now] and decides
  /// expiry; it exists for tests.
  DedupeCache({this.maximumEntries = 4096, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  /// Most ids held at once. Defaults to 4096.
  final int maximumEntries;
  final DateTime Function() _clock;
  final Map<String, DateTime> _entries = {};

  /// Seeds the cache from durable state so a replay survives a restart.
  void restore(Map<String, DateTime> entries) {
    final now = _clock();
    for (final entry in entries.entries) {
      if (entry.value.isAfter(now)) remember(entry.key, entry.value);
    }
  }

  /// Records [packetId] until [expiresAt] and returns true, or returns false
  /// when it is already held and unexpired.
  ///
  /// Expired entries are purged first; when the cache is still full the
  /// oldest entries are evicted to make room.
  bool remember(String packetId, DateTime expiresAt) {
    final now = _clock();
    _entries.removeWhere((_, expiry) => !expiry.isAfter(now));
    if (_entries.containsKey(packetId)) return false;
    while (_entries.length >= maximumEntries && _entries.isNotEmpty) {
      _entries.remove(_entries.keys.first);
    }
    _entries[packetId] = expiresAt;
    return true;
  }
}
