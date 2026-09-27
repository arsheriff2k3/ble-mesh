import 'chat_models.dart';
import 'crypto/chat_keys.dart';

/// A packet as a transport received it, tagged with where it came from.
class ReceivedChatPacket {
  /// Creates a received packet.
  const ReceivedChatPacket({
    required this.packet,
    required this.transportId,
    required this.routeId,
    this.senderKeys,
  });

  /// The decoded packet, not yet authenticated by the facade.
  final ChatPacket packet;

  /// [ChatTransport.id] of the transport it arrived on.
  final String transportId;

  /// The route within that transport it arrived on: the BLE link id, or the
  /// relay URL for Nostr. Passed back to [ChatTransport.send] to reply on
  /// the same route or to avoid echoing a relayed packet back.
  final String routeId;

  /// Keys from the announcement that introduced this sender, when the
  /// transport authenticates its peers.
  final ChatPublicKeys? senderKeys;
}

/// How many routes one [ChatTransport.send] tried and how many took the
/// packet.
class ChatTransportSendResult {
  /// Creates a send result.
  const ChatTransportSendResult({
    required this.attemptedRoutes,
    required this.deliveredRoutes,
  });

  /// Routes the packet was offered to: BLE links, or connected relays.
  final int attemptedRoutes;

  /// Routes that accepted the packet: a BLE link that took every fragment,
  /// or a relay that confirmed the event.
  ///
  /// Acceptance by a route is not receipt by the recipient; only an
  /// acknowledgement proves that.
  final int deliveredRoutes;

  /// Whether at least one route accepted the packet.
  bool get sent => deliveredRoutes > 0;
}

/// One way of moving [ChatPacket]s between devices, such as BLE or Nostr.
///
/// The facade authenticates packets, deduplicates, relays, and retries; a
/// transport moves encoded packets and reports which peers it can reach.
abstract interface class ChatTransport {
  /// Stable name of the transport, such as `ble` or `nostr`, used as
  /// [ReceivedChatPacket.transportId] and [ChatPeer.transportId].
  String get id;

  /// Whether the transport has at least one route to send on right now.
  ///
  /// The facade flushes its retry queue when this becomes true.
  bool get available;

  /// Emits [available] when it changes.
  Stream<bool> get availabilityChanges;

  /// Packets received from other devices.
  Stream<ReceivedChatPacket> get incoming;

  /// The full list of peers reachable on this transport, re-emitted on every
  /// change.
  Stream<List<ChatPeer>> get peers;

  /// Begins sending and receiving.
  Future<void> start();

  /// Stops sending and receiving.
  Future<void> stop();

  /// Offers [packet] to this transport's routes.
  ///
  /// With [routeId], only that route is used. Otherwise every route except
  /// [excludeRouteId] is used. A transport whose routes are not paths to a
  /// peer, such as Nostr, may ignore both.
  Future<ChatTransportSendResult> send(
    ChatPacket packet, {
    String? routeId,
    String? excludeRouteId,
  });
}

/// A transport that reaches peers through internet relays rather than
/// through nearby radios.
///
/// The facade treats relay transports differently from local ones: it never
/// floods their traffic back out, sends bridge registrations only over
/// local transports, and uses [bridge] and [setBridgedPeers] when this
/// device is a gateway. `NostrChatTransport` is the built-in implementation.
abstract interface class RelayChatTransport implements ChatTransport {
  /// Publishes another device's packet whose origin consented to bridging.
  Future<ChatTransportSendResult> bridge(ChatPacket packet);

  /// Replaces the offline peers whose relay traffic this device receives.
  void setBridgedPeers(Set<String> peerIds);

  /// Releases connections and closes streams. Called by the facade's
  /// `dispose`.
  Future<void> dispose();
}
