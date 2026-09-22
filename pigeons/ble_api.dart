// Channel contract between Dart and the native BLE transports.
//
// This file is the single source of truth. Regenerate with:
//   dart run pigeon --input pigeons/ble_api.dart
//
// Design rule: the native layer is a dumb byte pipe. It knows about adapter
// state, links (physical connections), frames (byte arrays), and how big a
// frame may be. It knows nothing about peers, messages, TTL, or encryption —
// that all lives in Dart.

import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/ble_api.g.dart',
    dartOptions: DartOptions(),
    kotlinOut:
        'android/src/main/kotlin/dev/blemesh/ble_mesh/BleApi.g.kt',
    kotlinOptions: KotlinOptions(package: 'dev.blemesh.ble_mesh'),
    swiftOut: 'darwin/ble_mesh/Sources/ble_mesh/BleApi.g.swift',
    swiftOptions: SwiftOptions(),
    dartPackageName: 'ble_mesh',
  ),
)
/// Power/authorization state of the host Bluetooth adapter.
enum BleAdapterState {
  /// Not yet reported by the platform.
  unknown,

  /// No BLE radio, or the radio cannot do what the mesh needs.
  unsupported,

  /// The user denied Bluetooth permission, or it was never granted.
  unauthorized,

  /// Radio present but switched off.
  poweredOff,

  /// Ready to scan and advertise.
  poweredOn,
}

/// Which side of the connection we are on for a given link.
///
/// A peer can be reachable over two links at once (we connected out, they
/// connected in). Collapsing links into peers is protocol-layer work in Dart.
enum BleLinkRole {
  /// We are the GATT client; we connected to their advertisement.
  central,

  /// We are the GATT server; they connected to our advertisement.
  peripheral,
}

enum BlePermissionState {
  granted,
  denied,

  /// Denied with "don't ask again" / restricted by policy. Only a trip to
  /// system settings can change this, so the UI must say so.
  permanentlyDenied,

  /// The platform needs no runtime permission for this (e.g. macOS).
  notRequired,
}

enum BleErrorCode {
  bluetoothOff,
  permissionDenied,
  unsupported,
  advertisingFailed,
  scanFailed,
  connectionFailed,
  writeFailed,

  /// Not named `internal`: Pigeon would emit `case internal` in Swift, which
  /// is a reserved word there.
  internalError,
}

enum BleEventKind { adapterState, linkUp, linkDown, frame, error }

/// What this device's radio can actually do.
///
/// Plenty of budget Android hardware can scan but cannot advertise. Such a
/// device can still receive from the mesh but cannot be discovered, so the UI
/// must degrade honestly instead of pretending the mesh is healthy.
class BleCapabilities {
  BleCapabilities({
    required this.supportsCentral,
    required this.supportsPeripheral,
    required this.platformName,
  });

  bool supportsCentral;
  bool supportsPeripheral;
  String platformName;
}

class BleConfig {
  BleConfig({
    required this.serviceUuid,
    required this.characteristicUuid,
    required this.advertisedName,
    this.maxConcurrentLinks = 6,
    this.scanWindowMs = 10000,
    this.scanRestMs = 20000,
    this.connectionTimeoutMs = 15000,
    this.enableBackground = false,
    this.backgroundNotificationTitle = 'Mesh active',
    this.backgroundNotificationBody = 'Relaying messages to nearby devices.',
  });

  /// 128-bit service UUID the mesh advertises and scans for.
  String serviceUuid;

  /// Single read/write/notify characteristic that carries every frame.
  String characteristicUuid;

  /// Short advertised name. The advertisement budget is 31 bytes, so this goes
  /// in the scan response and should stay under ~12 characters.
  String advertisedName;

  /// Soft cap on simultaneous links. Android's hard limit is device-dependent
  /// (often 7) and exceeding it fails opaquely.
  int maxConcurrentLinks;

  /// Duty cycle for scanning. Android throttles apps to 5 `startScan` calls
  /// per 30s, so these values must stay well clear of that.
  int scanWindowMs;
  int scanRestMs;

  int connectionTimeoutMs;

  /// Android only: run inside a `connectedDevice` foreground service so the
  /// mesh survives backgrounding. iOS uses background modes instead.
  bool enableBackground;
  String backgroundNotificationTitle;
  String backgroundNotificationBody;
}

/// One physical connection. Not a peer identity.
class BleLink {
  BleLink({
    required this.linkId,
    required this.role,
    required this.remoteId,
    required this.maxFrameSize,
    required this.connectedAtMs,
    this.rssi,
  });

  /// Opaque, stable for the lifetime of this connection.
  String linkId;

  BleLinkRole role;

  /// Platform device handle (Android MAC or iOS/macOS CBPeripheral UUID).
  /// Not stable across reboots on iOS and randomized on Android — never treat
  /// it as an identity.
  String remoteId;

  /// Largest frame that may be handed to [BleMeshHostApi.send] on this
  /// link. Dart fragments to this; the native side never fragments.
  int maxFrameSize;

  int connectedAtMs;
  int? rssi;
}

/// One envelope for every event, carried on a single channel.
///
/// A single channel makes ordering structural rather than incidental: a frame
/// can never be delivered before the `linkUp` for its link.
class BleEvent {
  BleEvent({
    required this.kind,
    this.adapterState,
    this.link,
    this.linkId,
    this.frame,
    this.errorCode,
    this.message,
  });

  BleEventKind kind;

  /// Set when [kind] is [BleEventKind.adapterState].
  BleAdapterState? adapterState;

  /// Set when [kind] is [BleEventKind.linkUp].
  BleLink? link;

  /// Set for [BleEventKind.linkDown], [BleEventKind.frame], and for errors
  /// that are attributable to a specific link.
  String? linkId;

  /// Set when [kind] is [BleEventKind.frame].
  Uint8List? frame;

  /// Set when [kind] is [BleEventKind.error].
  BleErrorCode? errorCode;

  /// Human-readable detail for diagnostics. Never shown raw to end users.
  String? message;
}

@HostApi()
abstract class BleMeshHostApi {
  BleCapabilities capabilities();

  BleAdapterState adapterState();

  @async
  BlePermissionState requestPermissions();

  /// Starts advertising, the GATT server, and scanning. Idempotent.
  @async
  void start(BleConfig config);

  /// Stops everything and drops all links. Idempotent.
  @async
  void stop();

  /// Sends one frame on one link.
  ///
  /// Completes when the platform has actually transmitted it (write callback
  /// or notification-sent callback), which is what gives Dart real
  /// backpressure instead of a fire-and-forget hose.
  @async
  void send(String linkId, Uint8List frame);

  @async
  void disconnect(String linkId);

  List<BleLink> links();
}

@EventChannelApi()
abstract class BleMeshEventApi {
  BleEvent events();
}
