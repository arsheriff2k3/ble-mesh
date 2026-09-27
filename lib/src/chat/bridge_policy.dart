/// What a gateway device is willing to carry between BLE and Nostr.
///
/// Acting as a gateway spends this device's data and battery on other
/// people's traffic and publishes their packets (ciphertext plus routing
/// metadata) to internet relays. It is therefore off unless the host sets a
/// policy, which should follow an explicit choice by the device's user.
class BridgePolicy {
  /// Creates a policy. [maximumPacketsPerMinute] must be positive and
  /// [maximumRoutes] must not be negative.
  const BridgePolicy({
    this.bleToNostr = true,
    this.nostrToBle = true,
    this.allowMetered = false,
    this.allowRoaming = false,
    this.maximumPacketsPerMinute = 120,
    this.maximumRoutes = 32,
  }) : assert(maximumPacketsPerMinute > 0),
       assert(maximumRoutes >= 0);

  /// Publish nearby devices' packets to relays.
  final bool bleToNostr;

  /// Carry relay traffic for registered nearby devices onto BLE.
  final bool nostrToBle;

  /// Bridge while the connection is metered, such as cellular data.
  final bool allowMetered;

  /// Bridge while roaming.
  final bool allowRoaming;

  /// Packets bridged per minute in both directions combined.
  final int maximumPacketsPerMinute;

  /// Offline devices whose online traffic this gateway receives at once.
  /// Each one is a route key revealed to relays.
  final int maximumRoutes;
}

/// The current connection as reported by the host.
///
/// The plugin cannot observe metering or roaming itself; the host supplies
/// them, for example from a connectivity package. Until it does, a policy
/// that forbids metered or roaming use stays inactive.
class NetworkConditions {
  /// Creates conditions as reported by the host.
  const NetworkConditions({required this.metered, required this.roaming});

  /// Whether the connection is metered, such as cellular data.
  final bool metered;

  /// Whether the device is roaming.
  final bool roaming;
}

/// Why this device is not currently bridging.
enum BridgeInactiveReason {
  /// No [BridgePolicy] is set: the user has not chosen to be a gateway.
  disabled,

  /// Gateways must authenticate what they carry, which needs PacketSecurity.
  requiresSecurity,

  /// No NostrChatTransport, or one with no connected relay.
  relaysUnavailable,

  /// The policy restricts metered or roaming use and the host has not
  /// reported network conditions.
  networkConditionsUnknown,

  /// The connection is metered and the policy does not allow it.
  metered,

  /// The connection is roaming and the policy does not allow it.
  roaming,
}

/// Whether this device is currently acting as a gateway, and what it has
/// carried.
class BridgeStatus {
  /// Creates a status snapshot.
  const BridgeStatus({
    required this.active,
    this.reason,
    this.bridgedPeers = 0,
    this.bridgedPackets = 0,
  });

  /// Whether packets are currently bridged between BLE and Nostr.
  final bool active;

  /// Set when [active] is false.
  final BridgeInactiveReason? reason;

  /// Registered offline devices whose online traffic is being received.
  final int bridgedPeers;

  /// Packets carried across since this chat started.
  final int bridgedPackets;

  @override
  bool operator ==(Object other) =>
      other is BridgeStatus &&
      other.active == active &&
      other.reason == reason &&
      other.bridgedPeers == bridgedPeers &&
      other.bridgedPackets == bridgedPackets;

  @override
  int get hashCode => Object.hash(active, reason, bridgedPeers, bridgedPackets);

  @override
  String toString() => active
      ? 'BridgeStatus(active, peers: $bridgedPeers, packets: $bridgedPackets)'
      : 'BridgeStatus(inactive: ${reason?.name})';
}
