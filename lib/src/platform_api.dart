import 'dart:typed_data';

import 'ble_api.g.dart' as pigeon;

/// The seam between the facade and the generated channel code.
///
/// Pigeon generates a concrete class, which cannot be faked in tests. This
/// interface exists so [BleMeshTransport] can be driven by a scripted fake on
/// the Dart VM, with no platform channel and no radio.
abstract interface class BlePlatformApi {
  Future<pigeon.BleCapabilities> capabilities();

  Future<pigeon.BleAdapterState> adapterState();

  Future<pigeon.BlePermissionState> requestPermissions();

  Future<void> start(pigeon.BleConfig config);

  Future<void> stop();

  Future<void> send(String linkId, Uint8List frame);

  Future<void> disconnect(String linkId);

  Future<List<pigeon.BleLink>> links();

  Stream<pigeon.BleEvent> events();
}

/// The real implementation, backed by the generated Pigeon channel.
class PigeonBlePlatformApi implements BlePlatformApi {
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
