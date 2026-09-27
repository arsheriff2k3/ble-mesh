# Integration test recipes

Most behaviour can be tested without radios or the internet. Physical tests
are still required before release.

## 1. Topologies in memory

`BleMeshChat` accepts any `ChatTransport`, so a test can wire up devices in
any shape. `test/test_chat_transport.dart` in this repository is a complete
in-memory transport. Copy it into your app's tests.

```dart
final a = TestChatTransport('a'), b = TestChatTransport('b'),
    c = TestChatTransport('c');
a.connect(b);
b.connect(c); // A <-> B <-> C, so A and C are out of range of each other.

final keysA = await ChatKeyPair.generate();
final keysC = await ChatKeyPair.generate();
final chatA = BleMeshChat(
  security: PacketSecurity(identity: keysA),
  maximumRelayJitter: Duration.zero, // deterministic tests
  minimumRelaySpacing: Duration.zero,
);
// ...create B and C the same way, pin each other's keys, initialize...
await chatA.sendDirect(peerId: keysC.peerId, text: 'through B');
```

Keep in mind:

- Set `maximumRelayJitter` and `minimumRelaySpacing` to zero. Both use real
  timers that `pumpEventQueue` does not advance.
- `FileMessageStore` does real disk I/O. Wait for a condition, not a fixed
  number of event-queue turns.
- `test/ble_mesh_chat_test.dart`, `test/durable_chat_test.dart`, and
  `test/encrypted_chat_test.dart` are worked examples.

## 2. Nostr without the internet

`NostrChatTransport` takes a `connector`. `test/fake_nostr_relay.dart` is an
in-memory NIP-01 relay that validates signatures, answers `OK`, serves
backfill, and can go offline or inject hostile events.

```dart
final network = FakeRelayNetwork()..add('wss://one.example');
final nostr = NostrChatTransport(
  identity: identity,
  relays: const ['wss://one.example'],
  connector: network.connect,
  minimumReconnectDelay: const Duration(milliseconds: 10),
);
```

See `test/nostr_chat_transport_test.dart` and `test/bridge_test.dart`.

## 3. A real relay on your machine

To exercise real WebSockets, run a local relay, for example
[`strfry`](https://github.com/hoytech/strfry) or
[`nostr-rs-relay`](https://github.com/scsibug/nostr-rs-relay) in Docker.
Point two instances of the example app at it:

```dart
NostrChatTransport(
  identity: identity,
  relays: const ['ws://localhost:7777'],
  allowInsecureRelays: true, // only for a local test relay
);
```

On an Android emulator the host machine is `ws://10.0.2.2:7777`. Confirm the
relay accepts kind 30078 and NIP-40 expiration tags.

## 4. On-device smoke suite

`example/integration_test/plugin_smoke_test.dart` runs on a real device or
desktop. It checks that the native plugin registers and reports
capabilities, that secure key storage round-trips, and that a relay chain
delivers an encrypted message on the device's own CPU.

```sh
cd example
flutter test integration_test -d <device-id>   # e.g. macos, an Android serial
```

Run it on every supported platform and OS version before a release. On an
unsupported platform, capabilities must report no BLE support without
crashing.

## 5. Checks before a release

```sh
flutter analyze                     # includes public_member_api_docs
flutter test                        # unit, protocol, abuse, and fuzz tests
flutter test benchmark/chat_benchmark_test.dart   # compare with doc/PERFORMANCE.md
(cd example && flutter build apk --debug && flutter build ios --simulator \
    && flutter build macos)
```

Then test the affected flows on physical devices.
