import 'chat_models.dart';

/// Thrown when the outbound queue is full and the caller's packet was not
/// accepted.
///
/// Rejecting is deliberate: silently dropping an older message to make room
/// would let a burst erase history the user believes is still pending.
class MessageStoreFullException implements Exception {
  const MessageStoreFullException({
    required this.queuedPackets,
    required this.maximumQueuedPackets,
  });

  final int queuedPackets;
  final int maximumQueuedPackets;

  @override
  String toString() =>
      'MessageStoreFullException: $queuedPackets of $maximumQueuedPackets '
      'queued packets';
}

/// Thrown rather than forgetting an unexpired packet id and admitting replay.
class SeenPacketQuotaException implements Exception {
  const SeenPacketQuotaException(this.maximumSeenPackets);

  final int maximumSeenPackets;

  @override
  String toString() =>
      'SeenPacketQuotaException: $maximumSeenPackets unexpired packet ids';
}

/// Thrown when a store's on-disk format is newer than this build understands.
class MessageStoreVersionException implements Exception {
  const MessageStoreVersionException({
    required this.found,
    required this.supported,
  });

  final int found;
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
  InMemoryMessageStore({
    this.maximumQueuedPackets = 1024,
    this.maximumMessages = 4096,
    this.maximumSeenPackets = 65536,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final int maximumQueuedPackets;
  final int maximumMessages;
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

class DedupeCache {
  DedupeCache({this.maximumEntries = 4096, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

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
