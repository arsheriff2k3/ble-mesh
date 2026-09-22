/// Dual-role (central + peripheral) BLE byte transport for building offline
/// mesh networks — chat, telemetry, anything that has to work with no
/// internet, no cell network, and no infrastructure.
///
/// The native layer is deliberately a dumb byte pipe: it knows about adapter
/// state, links, frames, and how big a frame may be, and nothing else. Peer
/// identity, routing, fragmentation, and encryption live in Dart so they exist
/// once instead of once per platform.
library;

export 'src/ble_api.g.dart'
    show
        BleAdapterState,
        BleCapabilities,
        BleConfig,
        BleErrorCode,
        BleLink,
        BleLinkRole,
        BlePermissionState;
export 'src/ble_mesh_transport.dart' show BleMeshTransport, BleMeshUuids;
export 'src/models.dart'
    show
        BleBroadcastReport,
        BleFrame,
        BleFrameTooLargeException,
        BleLinkDown,
        BleTransportError,
        BleUnknownLinkException,
        BleUnsupportedPlatformException;
export 'src/platform_api.dart' show BlePlatformApi, PigeonBlePlatformApi;
