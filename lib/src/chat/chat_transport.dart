import 'chat_models.dart';
import 'crypto/chat_keys.dart';

class ReceivedChatPacket {
  const ReceivedChatPacket({
    required this.packet,
    required this.transportId,
    required this.routeId,
    this.senderKeys,
  });

  final ChatPacket packet;
  final String transportId;
  final String routeId;

  /// Keys from the announcement that introduced this sender, when the
  /// transport authenticates its peers.
  final ChatPublicKeys? senderKeys;
}

class ChatTransportSendResult {
  const ChatTransportSendResult({
    required this.attemptedRoutes,
    required this.deliveredRoutes,
  });

  final int attemptedRoutes;
  final int deliveredRoutes;
  bool get sent => deliveredRoutes > 0;
}

abstract interface class ChatTransport {
  String get id;
  bool get available;
  Stream<bool> get availabilityChanges;
  Stream<ReceivedChatPacket> get incoming;
  Stream<List<ChatPeer>> get peers;

  Future<void> start();
  Future<void> stop();
  Future<ChatTransportSendResult> send(
    ChatPacket packet, {
    String? routeId,
    String? excludeRouteId,
  });
}
