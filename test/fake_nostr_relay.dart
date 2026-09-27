import 'dart:async';
import 'dart:convert';

import 'package:ble_mesh_chat/ble_mesh_chat.dart';

/// A minimal in-memory NIP-01 relay: stores events, validates signatures,
/// answers `OK`, serves `REQ` backfill, and pushes live matches.
class FakeNostrRelay {
  FakeNostrRelay(this.url);

  final String url;
  bool online = true;

  /// When false, well-formed events are refused with `OK false`.
  bool acceptEvents = true;
  final List<NostrEvent> stored = [];
  final Set<FakeRelayConnection> _connections = {};
  int connectionCount = 0;

  Future<NostrSocket> connect() async {
    if (!online) throw StateError('relay $url is offline');
    final connection = FakeRelayConnection._(this);
    _connections.add(connection);
    connectionCount++;
    return connection;
  }

  /// Drops every open connection and refuses new ones.
  void goOffline() {
    online = false;
    for (final connection in _connections.toList()) {
      connection._serverClose();
    }
  }

  void goOnline() => online = true;

  /// Makes every open connection a black hole that swallows traffic in both
  /// directions without closing, like a NAT that dropped an idle mapping.
  /// New connections work normally.
  void stallOpenConnections() {
    for (final connection in _connections) {
      connection._stalled = true;
    }
  }

  /// Sends [event] to every open subscription, bypassing filters and checks,
  /// the way a hostile or buggy relay could.
  void injectEvent(Object? event) {
    for (final connection in _connections.toList()) {
      for (final subscriptionId in connection._filters.keys.toList()) {
        connection._deliver(jsonEncode(['EVENT', subscriptionId, event]));
      }
    }
  }

  /// Sends an arbitrary text frame to every connection.
  void injectRaw(String message) {
    for (final connection in _connections.toList()) {
      connection._deliver(message);
    }
  }

  void _handle(FakeRelayConnection connection, String text) {
    final message = jsonDecode(text) as List<dynamic>;
    switch (message.first) {
      case 'EVENT':
        final NostrEvent event;
        try {
          event = NostrEvent.fromJson(message[1]);
        } on FormatException {
          connection._deliver(jsonEncode(['NOTICE', 'invalid: malformed']));
          return;
        }
        if (!event.verify()) {
          connection._deliver(
            jsonEncode(['OK', event.id, false, 'invalid: bad signature']),
          );
          return;
        }
        if (stored.any((item) => item.id == event.id)) {
          connection._deliver(
            jsonEncode(['OK', event.id, true, 'duplicate: already have it']),
          );
          return;
        }
        if (!acceptEvents) {
          connection._deliver(
            jsonEncode(['OK', event.id, false, 'blocked: not accepting']),
          );
          return;
        }
        stored.add(event);
        connection._deliver(jsonEncode(['OK', event.id, true, '']));
        for (final other in _connections.toList()) {
          for (final entry in other._filters.entries.toList()) {
            if (_matches(entry.value, event)) {
              other._deliver(jsonEncode(['EVENT', entry.key, event.toJson()]));
            }
          }
        }
      case 'REQ':
        final subscriptionId = message[1] as String;
        final filter = message[2] as Map<String, dynamic>;
        connection._filters[subscriptionId] = filter;
        final limit = filter['limit'] as int? ?? stored.length;
        final matches = stored
            .where((event) => _matches(filter, event))
            .toList()
            .reversed
            .take(limit);
        for (final event in matches) {
          connection._deliver(
            jsonEncode(['EVENT', subscriptionId, event.toJson()]),
          );
        }
        connection._deliver(jsonEncode(['EOSE', subscriptionId]));
      case 'CLOSE':
        connection._filters.remove(message[1]);
    }
  }

  static bool _matches(Map<String, dynamic> filter, NostrEvent event) {
    final ids = filter['ids'] as List<dynamic>?;
    if (ids != null && !ids.contains(event.id)) return false;
    final kinds = filter['kinds'] as List<dynamic>?;
    if (kinds != null && !kinds.contains(event.kind)) return false;
    final since = filter['since'] as int?;
    if (since != null && event.createdAt < since) return false;
    for (final entry in filter.entries) {
      if (!entry.key.startsWith('#')) continue;
      final name = entry.key.substring(1);
      final wanted = entry.value as List<dynamic>;
      if (!wanted.contains(event.tag(name))) return false;
    }
    return true;
  }
}

class FakeRelayConnection implements NostrSocket {
  FakeRelayConnection._(this._relay);

  final FakeNostrRelay _relay;
  final _controller = StreamController<String>();
  final Map<String, Map<String, dynamic>> _filters = {};
  bool _closed = false;
  bool _stalled = false;

  @override
  Stream<String> get messages => _controller.stream;

  @override
  void send(String message) {
    if (_closed) throw StateError('connection closed');
    if (_stalled) return;
    scheduleMicrotask(() {
      if (!_closed) _relay._handle(this, message);
    });
  }

  @override
  Future<void> close() async => _serverClose();

  void _deliver(String message) {
    if (!_closed && !_stalled) _controller.add(message);
  }

  void _serverClose() {
    if (_closed) return;
    _closed = true;
    _relay._connections.remove(this);
    unawaited(_controller.close());
  }
}

/// Routes relay URLs to fake relays.
class FakeRelayNetwork {
  final Map<String, FakeNostrRelay> relays = {};

  FakeNostrRelay add(String url) => relays[url] = FakeNostrRelay(url);

  Future<NostrSocket> connect(Uri uri) {
    final relay = relays[uri.toString()];
    if (relay == null) throw StateError('no relay at $uri');
    return relay.connect();
  }
}
