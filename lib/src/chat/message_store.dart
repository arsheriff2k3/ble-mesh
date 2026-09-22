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

  /// Releases resources. The store must be reopenable afterwards.
  Future<void> close();
}

/// Volatile store. Everything is lost when the process exits, which makes it
/// the right default for tests and for hosts that do not want history on disk.
class InMemoryMessageStore implements MessageStore {
  InMemoryMessageStore({
    this.maximumQueuedPackets = 1024,
    this.maximumMessages = 4096,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final int maximumQueuedPackets;
  final int maximumMessages;
  final DateTime Function() _clock;

  final Map<String, ChatPacket> _packets = {};
  final Map<String, ChatMessage> _messages = {};
  final Map<String, MessageState> _states = {};
  final Map<String, DateTime> _seen = {};

  @override
  Future<void> open() async {}

  @override
  Future<void> enqueue(ChatPacket packet) async {
    _purgeExpired();
    if (!_packets.containsKey(packet.id) &&
        _packets.length >= maximumQueuedPackets) {
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
    _purgeExpired();
    return List.unmodifiable(_packets.values);
  }

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
    _purgeExpired();
    _seen[packetId] = expiresAt;
  }

  @override
  Future<Map<String, DateTime>> seen() async {
    _purgeExpired();
    return Map.unmodifiable(_seen);
  }

  @override
  Future<void> close() async {}

  void _purgeExpired() {
    final now = _clock();
    _packets.removeWhere((_, packet) => packet.isExpired(now));
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
      if (entry.value.isAfter(now)) _entries[entry.key] = entry.value;
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
