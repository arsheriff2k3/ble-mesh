import 'dart:async';
import 'dart:typed_data';

import 'package:ble_mesh_chat/ble_mesh_chat.dart';
import 'package:ble_mesh_chat/src/ble_api.g.dart';

/// A scripted stand-in for the platform channel.
///
/// Lets the facade's link bookkeeping, size checks, and broadcast fan-out be
/// tested on the Dart VM with no radio and no device.
class FakeBlePlatformApi implements BlePlatformApi {
  final _events = StreamController<BleEvent>.broadcast();

  final List<({String linkId, Uint8List frame})> sent = [];
  final List<String> disconnected = [];

  int startCalls = 0;
  int stopCalls = 0;
  BleConfig? lastConfig;

  /// When set, every call throws this instead of succeeding — used to model an
  /// absent plugin on web/desktop.
  Object? throwOnEveryCall;

  /// Per-link send failures, keyed by link id.
  final Map<String, Object> sendFailures = {};

  List<BleLink> platformLinks = const [];

  /// Reported by [adapterState].
  BleAdapterState adapter = BleAdapterState.poweredOn;

  /// When set, [start] throws this, as the platform does with the radio off.
  Object? startFailure;

  void emit(BleEvent event) => _events.add(event);

  void emitLinkUp(
    String linkId, {
    int maxFrameSize = 244,
    BleLinkRole role = BleLinkRole.central,
  }) => emit(
    BleEvent(
      kind: BleEventKind.linkUp,
      link: BleLink(
        linkId: linkId,
        role: role,
        remoteId: 'remote-$linkId',
        maxFrameSize: maxFrameSize,
        connectedAtMs: 0,
      ),
    ),
  );

  void emitLinkDown(String linkId, {String? reason}) =>
      emit(BleEvent(kind: BleEventKind.linkDown, linkId: linkId, message: reason));

  void emitFrame(String linkId, List<int> bytes) => emit(
    BleEvent(
      kind: BleEventKind.frame,
      linkId: linkId,
      frame: Uint8List.fromList(bytes),
    ),
  );

  void emitAdapterState(BleAdapterState state) =>
      emit(BleEvent(kind: BleEventKind.adapterState, adapterState: state));

  void emitError(BleErrorCode code, String message, {String? linkId}) => emit(
    BleEvent(
      kind: BleEventKind.error,
      errorCode: code,
      message: message,
      linkId: linkId,
    ),
  );

  Future<void> close() => _events.close();

  void _maybeThrow() {
    final error = throwOnEveryCall;
    if (error != null) throw error;
  }

  @override
  Stream<BleEvent> events() => _events.stream;

  @override
  Future<BleCapabilities> capabilities() async {
    _maybeThrow();
    return BleCapabilities(
      supportsCentral: true,
      supportsPeripheral: true,
      platformName: 'fake',
    );
  }

  @override
  Future<BleAdapterState> adapterState() async {
    _maybeThrow();
    return adapter;
  }

  @override
  Future<BlePermissionState> requestPermissions() async {
    _maybeThrow();
    return BlePermissionState.granted;
  }

  @override
  Future<void> start(BleConfig config) async {
    _maybeThrow();
    startCalls++;
    final failure = startFailure;
    if (failure != null) throw failure;
    lastConfig = config;
  }

  @override
  Future<void> stop() async {
    _maybeThrow();
    stopCalls++;
  }

  @override
  Future<void> send(String linkId, Uint8List frame) async {
    _maybeThrow();
    final failure = sendFailures[linkId];
    if (failure != null) throw failure;
    sent.add((linkId: linkId, frame: frame));
  }

  @override
  Future<void> disconnect(String linkId) async {
    _maybeThrow();
    disconnected.add(linkId);
  }

  @override
  Future<List<BleLink>> links() async {
    _maybeThrow();
    return platformLinks;
  }
}
