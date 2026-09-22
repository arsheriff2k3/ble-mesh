import 'chat_models.dart';

abstract interface class MessageStore {
  Future<void> enqueue(ChatPacket packet);
  Future<void> remove(String packetId);
  Future<List<ChatPacket>> queued();
}

class InMemoryMessageStore implements MessageStore {
  final Map<String, ChatPacket> _packets = {};

  @override
  Future<void> enqueue(ChatPacket packet) async {
    _packets[packet.id] = packet;
  }

  @override
  Future<void> remove(String packetId) async {
    _packets.remove(packetId);
  }

  @override
  Future<List<ChatPacket>> queued() async => List.unmodifiable(_packets.values);
}

class DedupeCache {
  DedupeCache({this.maximumEntries = 4096, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final int maximumEntries;
  final DateTime Function() _clock;
  final Map<String, DateTime> _entries = {};

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
