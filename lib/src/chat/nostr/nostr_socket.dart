import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';

/// One client-to-relay text connection.
///
/// Abstracted so the transport can be exercised against an in-memory relay;
/// production code uses [connectWebSocket].
abstract interface class NostrSocket {
  /// Text frames from the relay. Completes when the connection closes.
  Stream<String> get messages;

  /// Sends one text frame, such as a serialized NIP-01 message.
  void send(String message);

  /// Closes the connection.
  Future<void> close();
}

/// Opens a connection to [relay], completing once it is usable.
typedef NostrSocketConnector = Future<NostrSocket> Function(Uri relay);

/// Default connector over `web_socket_channel`, which works on every Flutter
/// platform including web.
Future<NostrSocket> connectWebSocket(Uri relay) async {
  final channel = WebSocketChannel.connect(relay);
  await channel.ready;
  return _ChannelSocket(channel);
}

class _ChannelSocket implements NostrSocket {
  _ChannelSocket(this._channel);

  final WebSocketChannel _channel;

  @override
  Stream<String> get messages =>
      // NIP-01 is text only; a binary frame is not a relay message.
      _channel.stream.where((frame) => frame is String).cast<String>();

  @override
  void send(String message) => _channel.sink.add(message);

  @override
  Future<void> close() async {
    await _channel.sink.close();
  }
}
