import 'dart:typed_data';

import 'ble_api.g.dart' as pigeon;

/// The seam between the facade and the generated channel code.
///
/// Pigeon generates a concrete class, which cannot be faked in tests. This
/// interface exists so [BleMeshTransport] can be driven by a scripted fake on
/// the Dart VM, with no platform channel and no radio.
abstract interface class BlePlatformApi {
  /// What this device's radio can do.
  Future<pigeon.BleCapabilities> capabilities();

  /// Current power and authorization state of the Bluetooth adapter.
  Future<pigeon.BleAdapterState> adapterState();

  /// Asks the user for the runtime Bluetooth permissions the mesh needs.
  Future<pigeon.BlePermissionState> requestPermissions();

  /// Starts advertising, the GATT server, and scanning. Idempotent.
  Future<void> start(pigeon.BleConfig config);

  /// Stops everything and drops all links. Idempotent.
  Future<void> stop();

  /// Sends one [frame] on [linkId], completing once the platform has
  /// transmitted it.
  Future<void> send(String linkId, Uint8List frame);

  /// Drops the link [linkId].
  Future<void> disconnect(String linkId);

  /// Links the platform currently holds.
  Future<List<pigeon.BleLink>> links();

  /// Adapter, link, frame, and error events from the platform.
  ///
  /// Call once and share the returned broadcast stream: in
  /// [PigeonBlePlatformApi] every call opens a new event channel.
  Stream<pigeon.BleEvent> events();
}

/// The real implementation, backed by the generated Pigeon channel.
class PigeonBlePlatformApi implements BlePlatformApi {
  /// Creates the implementation over [host], or over a default
  /// [pigeon.BleMeshHostApi] when null.
  PigeonBlePlatformApi({pigeon.BleMeshHostApi? host})
    : _host = host ?? pigeon.BleMeshHostApi();

  final pigeon.BleMeshHostApi _host;

  @override
  Future<pigeon.BleCapabilities> capabilities() => _host.capabilities();

  @override
  Future<pigeon.BleAdapterState> adapterState() => _host.adapterState();

  @override
  Future<pigeon.BlePermissionState> requestPermissions() =>
      _host.requestPermissions();

  @override
  Future<void> start(pigeon.BleConfig config) => _host.start(config);

  @override
  Future<void> stop() => _host.stop();

  @override
  Future<void> send(String linkId, Uint8List frame) =>
      _host.send(linkId, frame);

  @override
  Future<void> disconnect(String linkId) => _host.disconnect(linkId);

  @override
  Future<List<pigeon.BleLink>> links() => _host.links();

  @override
  Stream<pigeon.BleEvent> events() => pigeon.events();
}
