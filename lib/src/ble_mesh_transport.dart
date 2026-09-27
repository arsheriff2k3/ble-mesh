import 'dart:async';

import 'package:flutter/services.dart';

import 'ble_api.g.dart';
import 'models.dart';
import 'platform_api.dart';

/// The package's sample mesh UUIDs.
///
/// **Generate your own before you ship.** The service UUID *is* the network:
/// every device advertising and scanning for the same one will link up, so two
/// unrelated apps left on these defaults would connect to each other and then
/// fail to parse each other's frames. Run `uuidgen` twice and pass the results
/// to [BleMeshTransport.defaultConfig] or build a [BleConfig] directly.
///
/// Pointing these at another implementation's UUIDs is also how you opt into
/// interoperating with an existing mesh — the transport does not care whose
/// network it joins.
class BleMeshUuids {
  const BleMeshUuids._();

  /// Sample service UUID. Fine for the example app and local testing; replace
  /// it in any app you distribute.
  static const service = '7A1F3C46-9E2B-4D58-8A61-5E0C2B7D4F19';

  /// Sample characteristic UUID. Every frame, in both directions, rides this
  /// one characteristic.
  static const characteristic = '7A1F3C47-9E2B-4D58-8A61-5E0C2B7D4F19';
}

/// Dual-role BLE byte transport.
///
/// Links, frames, and frame sizes — nothing else. No peer identity, no
/// message semantics, no fragmentation, no encryption: those live in the
/// protocol layer, which is pure Dart and testable without a radio.
///
/// Events arrive on one ordered channel, so a frame can never be delivered
/// before the [linkUp] for its own link.
class BleMeshTransport {
  /// Creates a transport and subscribes to platform events immediately.
  ///
  /// [api] defaults to the Pigeon platform channel; pass a fake in tests.
  /// Call [dispose] when done to release the subscription and streams.
  BleMeshTransport({BlePlatformApi? api})
    : _api = api ?? PigeonBlePlatformApi() {
    _events = _api.events().listen(_onEvent, onError: _onEventError);
  }

  final BlePlatformApi _api;
  late final StreamSubscription<BleEvent> _events;

  final _adapterState = StreamController<BleAdapterState>.broadcast();
  final _linkUp = StreamController<BleLink>.broadcast();
  final _linkDown = StreamController<BleLinkDown>.broadcast();
  final _frames = StreamController<BleFrame>.broadcast();
  final _errors = StreamController<BleTransportError>.broadcast();
  final _linksChanged = StreamController<List<BleLink>>.broadcast();

  final Map<String, BleLink> _links = {};

  BleAdapterState _lastAdapterState = BleAdapterState.unknown;
  bool _running = false;
  bool _disposed = false;

  /// Adapter states as the platform reports them. Broadcast.
  ///
  /// Emits [BleAdapterState.unsupported] once if the platform has no plugin.
  /// See [lastAdapterState] for the value before you subscribed.
  Stream<BleAdapterState> get adapterState => _adapterState.stream;

  /// Links as they come up, each already added to [links]. Broadcast.
  Stream<BleLink> get linkUp => _linkUp.stream;

  /// Links as they go down, each already removed from [links]. Broadcast.
  ///
  /// Not emitted for links cleared by [stop] or by the adapter powering off
  /// or losing authorization; watch [linksChanged] for those.
  Stream<BleLinkDown> get linkDown => _linkDown.stream;

  /// Frames received from peers, in arrival order. Broadcast.
  Stream<BleFrame> get frames => _frames.stream;

  /// Asynchronous platform errors and event channel failures. Broadcast.
  ///
  /// Errors from a call such as [send] are thrown by that call instead.
  Stream<BleTransportError> get errors => _errors.stream;

  /// Emitted whenever the live link set changes, for UI that shows neighbours.
  /// Broadcast; each event is the full list of live links.
  Stream<List<BleLink>> get linksChanged => _linksChanged.stream;

  /// Last adapter state the platform reported.
  BleAdapterState get lastAdapterState => _lastAdapterState;

  /// Whether [start] has succeeded and [stop] has not been called since.
  bool get isRunning => _running;

  /// Live links, keyed by link id. Snapshot; safe to hold.
  Map<String, BleLink> get links => Map.unmodifiable(_links);

  /// The most restrictive frame size across live links, or null with no links.
  ///
  /// The protocol layer needs this to pick a fragment size that every
  /// neighbour can carry, so one MTU-starved peer does not force a re-fragment
  /// of everything.
  int? get minFrameSize => _links.values.isEmpty
      ? null
      : _links.values
            .map((link) => link.maxFrameSize)
            .reduce((a, b) => a < b ? a : b);

  /// Reports which BLE roles this device supports.
  ///
  /// On a platform without the plugin, completes with both roles unsupported
  /// and `platformName` `'unsupported'` rather than throwing.
  Future<BleCapabilities> capabilities() => _guard(
    () => _api.capabilities(),
    onUnsupported: () => BleCapabilities(
      supportsCentral: false,
      supportsPeripheral: false,
      platformName: 'unsupported',
    ),
  );

  /// Queries the adapter state now, and completes with
  /// [BleAdapterState.unsupported] on a platform without the plugin.
  Future<BleAdapterState> currentAdapterState() => _guard(
    () => _api.adapterState(),
    onUnsupported: () => BleAdapterState.unsupported,
  );

  /// Requests the runtime permissions the transport needs and completes with
  /// the outcome.
  ///
  /// Completes with [BlePermissionState.notRequired] on a platform without
  /// the plugin.
  Future<BlePermissionState> requestPermissions() => _guard(
    () => _api.requestPermissions(),
    onUnsupported: () => BlePermissionState.notRequired,
  );

  /// Starts advertising, the GATT server, and scanning.
  ///
  /// Idempotent. Throws [BleUnsupportedPlatformException] where there is no
  /// BLE transport at all, so callers can fall back to an online transport
  /// instead of treating it as a crash.
  Future<void> start({BleConfig? config}) async {
    _assertUsable();
    await _guard(() async {
      await _api.start(config ?? defaultConfig());
      _running = true;
    }, onUnsupported: () => throw const BleUnsupportedPlatformException(
      'this platform has no BLE mesh transport',
    ));
  }

  /// Stops advertising, the GATT server, and scanning, and forgets all links.
  ///
  /// Emits an empty [linksChanged] list when links were live. Does nothing on
  /// a platform without the plugin. Throws [StateError] after [dispose].
  Future<void> stop() async {
    _assertUsable();
    await _guard(() async {
      await _api.stop();
      _running = false;
      if (_links.isNotEmpty) {
        _links.clear();
        _linksChanged.add(const []);
      }
    }, onUnsupported: () {});
  }

  /// Sends one frame on one link.
  ///
  /// Completes only when the platform has actually transmitted it, which is
  /// what makes this usable as backpressure rather than a fire-and-forget
  /// hose. Frames larger than the link's `maxFrameSize` are rejected rather
  /// than split: fragmentation is a protocol decision.
  Future<void> send(String linkId, Uint8List frame) async {
    _assertUsable();
    final link = _links[linkId];
    if (link == null) throw BleUnknownLinkException(linkId);
    if (frame.length > link.maxFrameSize) {
      throw BleFrameTooLargeException(
        linkId: linkId,
        frameSize: frame.length,
        maxFrameSize: link.maxFrameSize,
      );
    }
    await _api.send(linkId, frame);
  }

  /// Sends one frame to every live link.
  ///
  /// Never throws for a per-link failure: peers walking out of range mid-send
  /// is the normal case in a mesh, and the caller needs to know which links
  /// took the frame so it can decide about store-and-forward.
  Future<BleBroadcastReport> broadcast(
    Uint8List frame, {
    String? exceptLinkId,
  }) async {
    _assertUsable();
    final targets = _links.keys
        .where((linkId) => linkId != exceptLinkId)
        .toList(growable: false);

    final delivered = <String>[];
    final failed = <String, Object>{};

    await Future.wait(
      targets.map((linkId) async {
        try {
          await send(linkId, frame);
          delivered.add(linkId);
        } catch (error) {
          failed[linkId] = error;
        }
      }),
    );
    return BleBroadcastReport(delivered: delivered, failed: failed);
  }

  /// Asks the platform to drop [linkId].
  ///
  /// The link leaves [links] when the platform reports it on [linkDown].
  /// Does nothing on a platform without the plugin. Throws [StateError] after
  /// [dispose].
  Future<void> disconnect(String linkId) async {
    _assertUsable();
    await _guard(() => _api.disconnect(linkId), onUnsupported: () {});
  }

  /// Re-reads the link set from the platform.
  ///
  /// Normally unnecessary — the event stream is authoritative — but useful
  /// after a hot restart, when Dart state is gone and the radios are not.
  Future<List<BleLink>> refreshLinks() async {
    final platformLinks = await _guard(
      () => _api.links(),
      onUnsupported: () => const <BleLink>[],
    );
    _links
      ..clear()
      ..addEntries(platformLinks.map((link) => MapEntry(link.linkId, link)));
    _linksChanged.add(_links.values.toList(growable: false));
    return platformLinks;
  }

  /// Cancels the platform subscription and closes every stream.
  ///
  /// Safe to call more than once. Does not stop the radios; call [stop]
  /// first. Afterwards, [start], [stop], [send], [broadcast], and
  /// [disconnect] throw [StateError].
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _events.cancel();
    await _adapterState.close();
    await _linkUp.close();
    await _linkDown.close();
    await _frames.close();
    await _errors.close();
    await _linksChanged.close();
  }

  /// A config with sensible defaults for every knob you probably do not care
  /// about.
  ///
  /// Pass your own [serviceUuid] and [characteristicUuid]: the defaults are
  /// this package's sample UUIDs, and shipping on them means sharing a network
  /// with every other app that did the same. See [BleMeshUuids].
  static BleConfig defaultConfig({
    String serviceUuid = BleMeshUuids.service,
    String characteristicUuid = BleMeshUuids.characteristic,
    String advertisedName = 'blemesh',
    int maxConcurrentLinks = 6,
    bool enableBackground = false,
    String backgroundNotificationTitle = 'Mesh active',
    String backgroundNotificationBody = 'Relaying messages to nearby devices.',
  }) => BleConfig(
    serviceUuid: serviceUuid,
    characteristicUuid: characteristicUuid,
    advertisedName: advertisedName,
    maxConcurrentLinks: maxConcurrentLinks,
    enableBackground: enableBackground,
    backgroundNotificationTitle: backgroundNotificationTitle,
    backgroundNotificationBody: backgroundNotificationBody,
  );

  // ----------------------------------------------------------------- internals

  void _onEvent(BleEvent event) {
    switch (event.kind) {
      case BleEventKind.adapterState:
        final state = event.adapterState ?? BleAdapterState.unknown;
        _lastAdapterState = state;
        if (state == BleAdapterState.poweredOff ||
            state == BleAdapterState.unauthorized) {
          // The platform drops the links itself; mirroring that here keeps the
          // snapshot honest even if a linkDown is lost with the radio.
          _links.clear();
          _linksChanged.add(const []);
        }
        _adapterState.add(state);

      case BleEventKind.linkUp:
        final link = event.link;
        if (link == null) return;
        _links[link.linkId] = link;
        _linkUp.add(link);
        _linksChanged.add(_links.values.toList(growable: false));

      case BleEventKind.linkDown:
        final linkId = event.linkId;
        if (linkId == null) return;
        _links.remove(linkId);
        _linkDown.add(BleLinkDown(linkId: linkId, reason: event.message));
        _linksChanged.add(_links.values.toList(growable: false));

      case BleEventKind.frame:
        final linkId = event.linkId;
        final frame = event.frame;
        if (linkId == null || frame == null) return;
        _frames.add(BleFrame(linkId: linkId, data: frame));

      case BleEventKind.error:
        _errors.add(
          BleTransportError(
            code: event.errorCode ?? BleErrorCode.internalError,
            message: event.message ?? 'unspecified platform error',
            linkId: event.linkId,
          ),
        );
    }
  }

  void _onEventError(Object error, StackTrace stackTrace) {
    if (_errors.isClosed) return;
    if (error is MissingPluginException) {
      _lastAdapterState = BleAdapterState.unsupported;
      if (!_adapterState.isClosed) {
        _adapterState.add(BleAdapterState.unsupported);
      }
      return;
    }
    _errors.add(
      BleTransportError(
        code: BleErrorCode.internalError,
        message: 'event channel error: $error',
      ),
    );
  }

  /// Turns "there is no plugin on this platform" into a first-class answer.
  ///
  /// Web and desktop Linux/Windows builds of the host app must keep working;
  /// they just have no mesh.
  Future<T> _guard<T>(
    Future<T> Function() body, {
    required T Function() onUnsupported,
  }) async {
    try {
      return await body();
    } on MissingPluginException {
      return onUnsupported();
    } on UnimplementedError {
      return onUnsupported();
    }
  }

  void _assertUsable() {
    if (_disposed) {
      throw StateError('BleMeshTransport was disposed');
    }
  }
}
