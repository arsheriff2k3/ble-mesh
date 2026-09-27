# ble_mesh_chat

Flutter plugin for offline-first chat. Phones talk directly over a
Bluetooth Low Energy mesh when there is no network, reach contacts online
through Nostr relays when there is, and can bridge between the two through a
consenting gateway phone.

- **BLE mesh:** a dual-role (central and peripheral) transport, with TTL
  flooding, deduplication, fragmentation, and acknowledgements.
- **Security:** signed packets, key-derived peer ids, sealed direct
  messages, encrypted groups, trust on first use, and safety numbers. All of
  it is **experimental and not yet externally reviewed**; see
  [doc/LIMITATIONS.md](doc/LIMITATIONS.md).
- **Durability:** a crash-tolerant message store, retries until the
  recipient acknowledges, and replay protection that survives restarts.
- **Online delivery:** encrypted direct messages over one or more Nostr
  relays.
- **Bridging:** opt-in gateways that carry consenting traffic between BLE and
  Nostr.
- **Abuse resistance:** rate budgets, contacts-only online delivery, a
  hidden-text sanitizer, and fuzzed parsers.

Dual-role (central **and** peripheral) Bluetooth Low Energy byte transport for
Flutter.

Every device scans and connects out *while* advertising and serving a GATT
service that neighbours connect into. Both roles let nearby devices relay
messages through one another.

Use the included chat layer, or build your own protocol directly on
the byte transport for telemetry, signed reports, or other offline data.

Android, iOS, and macOS support BLE. Web, Windows, and Linux can use the Dart
chat and Nostr layers, but have no native BLE implementation; a direct BLE
`start()` call throws a typed unsupported-platform exception.

**Start here:** [Integration guide](doc/GETTING_STARTED.md) covers a complete
app setup, platform configuration, lifecycle, online-only fallback, and a
physical-device checklist. [Example app](example/README.md) shows a working
chat UI and diagnostics.

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
  ble_mesh_chat: ^0.1.2
  path_provider: ^2.1.6 # only if using the file-backed example below
```

## Usage

### Chat quick start

```dart
import 'package:ble_mesh_chat/ble_mesh_chat.dart';
import 'package:ble_mesh_chat/file_store.dart';
import 'package:path_provider/path_provider.dart';

final dir = await getApplicationSupportDirectory();

// A durable identity: private keys go to Android Keystore / Apple Keychain.
final identityStore = PlatformIdentityStore(
  fallback: FileIdentityStore(directory: dir),
);
final keys = await loadOrCreateIdentity(identityStore);
final security = PacketSecurity(
  identity: keys,
  trustStore: await identityStore.loadTrust(),
);
final me = ChatIdentity(peerId: keys.peerId, displayName: 'Alice');

final ble = BleMeshTransport();
await ble.requestPermissions();

// Generate these two UUIDs for your app, then use the same pair on every
// participant. The package defaults are for the example app only.
final bleConfig = BleMeshTransport.defaultConfig(
  serviceUuid: 'YOUR-SERVICE-UUID',
  characteristicUuid: 'YOUR-CHARACTERISTIC-UUID',
  advertisedName: 'myapp',
  enableBackground: true,
);

final chat = BleMeshChat(
  security: security,
  store: FileMessageStore.at('${dir.path}/chat.log'),
);
chat.messages.listen((message) {
  // Remote text is untrusted input; strip invisible characters for display.
  print(UntrustedText.stripHidden(message.text));
});
chat.messageStates.listen((change) => print(change.state.name));

await chat.initialize(
  identity: me,
  transports: [
    BleChatTransport(
      identity: me,
      transport: ble,
      config: bleConfig,
      security: security,
    ),
    // Optional: online delivery to contacts through Nostr relays.
    NostrChatTransport(identity: me, relays: const ['wss://relay.example.com']),
  ],
);

await chat.send(conversationId: 'general', text: 'Hello mesh!'); // signed, readable
await chat.sendDirect(peerId: bobPeerId, text: 'Private');      // sealed

// On app shutdown, cancel your stream subscriptions, then:
await chat.dispose();
await ble.dispose(); // externally supplied transport stays owned by the app
```

A few things to know:

- **Direct messages need the recipient's key.** It is learned from a BLE
  meeting, or pinned from a contact code (`ChatPublicKeys.toContactCode()`
  and `fromContactCode()`). Saving pinned keys with
  `identityStore.saveTrust` is the host's job; the example shows how.
- **Delivery states.** `sent` means a route accepted the packet;
  `delivered` means the recipient's signed acknowledgement arrived.
- **Online contacts only.** Nostr accepts messages from contacts only by
  default (`contactsOnlyTransports`).
- **Bridging** is off unless the sender sets `bridgeConsent` and a gateway
  sets a `BridgePolicy`. See [doc/BRIDGE.md](doc/BRIDGE.md).
- `example/` is a complete harness covering all of the above.

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
- `android.permission.INTERNET` if you use `NostrChatTransport`.
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

The chat layer uses encryption (Ed25519, X25519, XChaCha20-Poly1305), so
answer export compliance (`ITSAppUsesNonExemptEncryption`) accordingly at
submission.

### macOS

Add `com.apple.security.device.bluetooth` to both entitlements files. Without
it a sandboxed app fails silently, with no error and no radio. Nostr relays
also need `com.apple.security.network.client`.

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

## Documentation

| Document | Covers |
| --- | --- |
| [GETTING_STARTED.md](doc/GETTING_STARTED.md) | Step-by-step integration and platform setup |
| [LIMITATIONS.md](doc/LIMITATIONS.md) | Every known security, platform, and resource limit |
| [CRYPTO.md](doc/CRYPTO.md) | Cryptographic design, trust model, and Nostr metadata |
| [BRIDGE.md](doc/BRIDGE.md) | Gateways: consent, loops, metadata, data use, battery |
| [THREAT_MODEL.md](doc/THREAT_MODEL.md) | Floods, fuzzing, hidden-text injection, impersonation, and the defences against them |
| [API_STABILITY.md](doc/API_STABILITY.md) | Stability tiers, wire and storage compatibility, migration |
| [INTEGRATION_TESTING.md](doc/INTEGRATION_TESTING.md) | Testing recipes, from in-memory to on-device |
| [PERFORMANCE.md](doc/PERFORMANCE.md) | Measurements and device benchmark recipes |
| [TEST_VECTORS.md](doc/TEST_VECTORS.md) | Deterministic protocol vectors |

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
  ble_mesh_chat.dart      public exports
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
darwin/ble_mesh_chat/Sources/ble_mesh_chat/
  BleMeshPlugin.swift, BleController.swift,
  CentralController.swift, PeripheralController.swift,
  LinkRegistry.swift, BleEventBus.swift, BleTransportError.swift
  chat/                     packets, routing, stores, Nostr, bridging
    crypto/                 keys, sealing, trust, groups (experimental)
    nostr/                  NIP-01 events, sockets, vendored BIP-340
lib/file_store.dart       dart:io stores (message log, identity, groups)
benchmark/                performance measurements
example/                  mesh chat and diagnostics harness
example/integration_test/ on-device smoke suite
```

iOS and macOS share one Swift source tree via `sharedDarwinSource: true`.

## Status

Pre-release. The example builds for Android, iOS, and macOS, and the test
suite covers the protocol, storage, transports, abuse handling, and fuzzing.
Broader testing on physical devices is ongoing, and the cryptography has not
been externally reviewed. Read [doc/LIMITATIONS.md](doc/LIMITATIONS.md)
before depending on it.

## License

MIT — see [LICENSE](LICENSE). Use it, fork it, ship it.
