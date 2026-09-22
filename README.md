# ble_mesh

Flutter plugin for transport-agnostic, offline-first mesh chat. The current
`0.1.0` preview provides the dual-role BLE byte transport plus a Dart chat
layer with packet routing, fragmentation, deduplication, acknowledgements, and
an in-memory retry queue. Durable storage, encryption, and Nostr come later.

See the [chat plugin implementation plan](docs/CHAT_PLUGIN_PLAN.md) for the
target API, architecture, delivery phases, and physical-device acceptance
criteria.

Dual-role (central **and** peripheral) Bluetooth Low Energy byte transport for
Flutter — the missing layer under a BLE mesh.

Every device scans and connects out *while* advertising and serving a GATT
service that neighbours connect into. No published Flutter BLE package does
both at once, which is why this plugin exists: `flutter_blue_plus` and
`flutter_reactive_ble` are central-only, `flutter_ble_peripheral` advertises but
cannot carry data both ways. Without the dual role there is no mesh, only a
star.

Use the included Phase 1 chat protocol, or build your own protocol directly on
the byte transport for telemetry, signed reports, or other offline data.

Android, iOS, and macOS. Web, Windows, and Linux degrade to a documented no-op
rather than crashing.

## Native scope: a dumb byte pipe

The native layer knows about four things:

| Concept | Meaning |
|---|---|
| adapter state | is the radio there, on, and permitted |
| link | one physical connection, identified by an opaque `linkId` |
| frame | one byte array in or out on a link |
| `maxFrameSize` | the largest frame this link will carry |

It knows nothing about peers, messages, TTL, fragmentation, or encryption.
Those live in Dart so they exist once instead of once per platform, and so they
can be unit-tested with no radio and no device.

A `linkId` is **not a peer identity**. The same device often holds two links at
once — you connected out, they connected in. Collapsing links into peers is
your protocol layer's job, because only it has seen the peer's announce.

## Install

```yaml
dependencies:
  ble_mesh: ^0.1.0
```

## Usage

### Phase 1 chat API

```dart
final identity = ChatIdentity(peerId: 'device-a', displayName: 'Alice');
final chat = BleMeshChat();

await chat.initialize(
  identity: identity,
  transports: [BleChatTransport(identity: identity)],
);

chat.messages.listen((message) => print('${message.senderId}: ${message.text}'));
chat.messageStates.listen((change) => print(change.state.name));

await chat.send(conversationId: 'general', text: 'Hello mesh!');
await chat.sendDirect(peerId: 'device-b', text: 'Private delivery');
```

The Phase 1 protocol provides bounded binary packets, fragmentation, controlled
TTL flooding, duplicate suppression, acknowledgements, and an in-memory retry
queue. It is **not encrypted yet**. Do not use it for sensitive messages;
reviewed identity and encryption are Phase 3.

### Low-level byte transport

```dart
final transport = BleMeshTransport();

transport.adapterState.listen((state) => print('adapter: ${state.name}'));
transport.linkUp.listen((link) => print('${link.linkId} @ ${link.maxFrameSize}B'));
transport.frames.listen((frame) => protocol.ingest(frame.linkId, frame.data));

final permission = await transport.requestPermissions();
if (permission == BlePermissionState.granted) {
  await transport.start(
    config: BleMeshTransport.defaultConfig(
      // Generate your own. See "Pick your own UUIDs" below.
      serviceUuid: '…',
      characteristicUuid: '…',
      advertisedName: 'myapp',
      enableBackground: true, // Android foreground service
    ),
  );
}

// One link, with real backpressure: completes when the platform transmitted it.
await transport.send(linkId, frame);

// Or every link. Per-link failures are reported, not thrown: peers walking out
// of range mid-send is the normal case in a mesh.
final report = await transport.broadcast(frame, exceptLinkId: arrivedOn);
```

### Pick your own UUIDs

**The service UUID is the network.** Every device advertising and scanning for
the same one will link up, so two unrelated apps left on this package's sample
UUIDs would connect to each other and then fail to parse each other's frames.
Run `uuidgen` twice, keep the values in your app, and pass them to
`defaultConfig`. `BleMeshUuids.service` and `.characteristic` exist for the
example harness and local testing.

The flip side: pointing these at an existing mesh's UUIDs is how you join it.
The transport does not care whose network it carries.

### Frame sizes

Frames larger than a link's `maxFrameSize` are rejected with
`BleFrameTooLargeException`. The transport never fragments — splitting a packet
means fragment headers, reassembly timeouts, and ordering, all of which are
protocol decisions you should be making, not inheriting. Use
`transport.minFrameSize` to pick a fragment size every current neighbour can
carry.

### Unsupported platforms

On web, Windows, and Linux there is no implementation: `capabilities()` reports
`supportsCentral: false`, and `start()` throws
`BleUnsupportedPlatformException` so the host app can fall back to an online
transport instead of crashing.

## Host app setup

### Android

Permissions and the foreground service are declared in the plugin's manifest
and merge automatically. The host app still needs:

- `minSdk 24` or higher.
- On Android 13+, `POST_NOTIFICATIONS` if you want the mesh's foreground-service
  notification to actually appear. The service runs either way, but a mesh that
  runs invisibly is not something to ship.

`BLUETOOTH_SCAN` is declared with `neverForLocation`, which is what lets your
app avoid a location prompt entirely. That is a promise: nothing in this plugin
may derive location from scan results.

### iOS

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>… why your app needs Bluetooth, in plain language …</string>
<key>UIBackgroundModes</key>
<array>
  <string>bluetooth-central</string>
  <string>bluetooth-peripheral</string>
</array>
```

If your protocol layer adds its own encryption, answer export compliance
(`ITSAppUsesNonExemptEncryption`) accordingly at submission.

### macOS

Add `com.apple.security.device.bluetooth` to both entitlements files. Without
it a sandboxed app fails silently, with no error and no radio.

## Platform behaviour worth knowing

| Behaviour | Android | iOS / macOS |
|---|---|---|
| Frame size | `MTU - 3`, MTU requested at 517 | `maximumWriteValueLength(.withoutResponse)` / `maximumUpdateValueLength` |
| Write completion | `onCharacteristicWrite` / `onNotificationSent` | write accepted by the stack (`canSendWriteWithoutResponse`) — iOS gives no per-write callback |
| Operation ordering | one GATT op per connection, enforced by `GattQueue`; a second concurrent op is silently dropped by the platform | serialized by a FIFO per role |
| `start()` with the radio off | throws `bluetooth_off` | throws only if the state is already known to be off; otherwise reports `poweredOff` on the event stream |
| Cannot advertise | real: many budget chipsets. `capabilities().supportsPeripheral` is false and an error event explains it | not a thing; all Apple BLE devices can advertise |
| Backgrounded discovery | foreground service keeps it alive; OEM battery managers still interfere | backgrounded advertising moves to the overflow area, so two backgrounded iOS devices effectively cannot find each other |

That last row is a product constraint, not a bug: a cluster needs at least one
foregrounded device. Your UI must say so rather than implying a mesh that is
not there.

## Chat protocol implementation

The transport gives you links and frames. The Phase 1 Dart chat layer now adds:

1. **A packet codec** — a bounded binary header with version, type, packet ID,
   TTL, sender, destination, timestamps, and payload length.
2. **Flood routing** with TTL decay, a dedupe cache keyed on the random 128-bit
   packet ID, and jittered rebroadcast. Without dedupe the mesh melts into a
   broadcast storm.
3. **Fragmentation** to `minFrameSize`, with reassembly timeouts and a size cap.
4. **Duplicate-link suppression** — two devices usually connect to each other
   twice. Once announces have identified the peers, the lower peer ID keeps its
   outbound link and the higher one drops its own.
5. **Peer announcements and acknowledgements** — enough to collapse duplicate
   links and distinguish `sent` from destination-confirmed `delivered`.

Identity authentication and payload encryption intentionally remain Phase 3.
They must use a reviewed protocol with published test vectors.

These layers are part of the high-level `ble_mesh` Flutter plugin API, not
application-specific code. The existing byte API remains available for
advanced consumers. See the
[chat plugin implementation plan](docs/CHAT_PLUGIN_PLAN.md).

## Development

```bash
dart run pigeon --input pigeons/ble_api.dart   # after changing the contract
flutter analyze
flutter test
cd example && flutter run                      # three devices prove mesh relay
```

`pigeons/ble_api.dart` is the single source of truth for the channel. Never edit
`lib/src/ble_api.g.dart`, `BleApi.g.kt`, or `BleApi.g.swift` by hand.

### Type-checking the Swift

```bash
tool/typecheck_darwin.sh
```

Type-checks every Swift source against the real `Flutter`/`FlutterMacOS`
modules for all three Darwin targets — macOS, iOS device, iOS simulator — at the
podspec's deployment targets. Targets whose SDK is missing are reported as
skipped rather than silently passing, so it still does useful work on a machine
with only the Command Line Tools (macOS only) or without the iOS platform
bundle installed.

It does **not** link, run `pod lib lint`, or touch a radio. It is a fast
pre-flight, not a substitute for `flutter build`.

One gotcha for future contract changes: Pigeon emits Swift enum cases verbatim,
so an enum value named `internal` (or any other Swift keyword) generates code
that does not compile. `BleErrorCode.internalError` is named the way it is for
exactly that reason.

## Layout

```
pigeons/ble_api.dart      channel contract (source of truth)
lib/
  ble_mesh.dart           public exports
  src/
    ble_mesh_transport.dart   the facade: streams, link bookkeeping, broadcast
    platform_api.dart         seam that makes the facade testable
    models.dart               frames, errors, exceptions
    ble_api.g.dart            generated
android/src/main/kotlin/dev/blemesh/ble_mesh/
  BleMeshPlugin.kt          entry point, permissions
  BleController.kt          orchestration, adapter lifecycle
  CentralController.kt      scanning + GATT client
  PeripheralController.kt   advertising + GATT server
  GattQueue.kt              one operation in flight per connection
  LinkRegistry.kt           live links
  BleEventBus.kt            the single ordered event channel
  MeshForegroundService.kt  keeps the process alive with the mesh on
darwin/ble_mesh/Sources/ble_mesh/
  BleMeshPlugin.swift, BleController.swift,
  CentralController.swift, PeripheralController.swift,
  LinkRegistry.swift, BleEventBus.swift, BleTransportError.swift
example/                  two-device echo harness
```

iOS and macOS share one Swift source tree via `sharedDarwinSource: true`.

## Status

Android, iOS, and macOS all build and link; the harness runs on an iOS
simulator with the plugin registered and answering; the Dart side is unit
tested. But **nothing here has moved a byte over a real radio yet** — and the
iOS simulator has no Bluetooth radio, so it cannot test the mesh at all. See
the implementation plan for the physical-device gates that must pass before
you depend on it.

## License

MIT — see [LICENSE](LICENSE). Use it, fork it, ship it.
