# Integrate `ble_mesh_chat` in a Flutter app

This guide is for app developers using package version `0.1.2`. It covers the
native BLE mesh, optional Nostr delivery, and the host-app settings that the
plugin cannot supply through a package manifest. The [example app](../example/README.md)
is an executable reference for the UI, saved contacts, relay settings, and
gateway controls.

## 1. Choose a platform and transport

| Platform | BLE mesh | Nostr relay chat | Host requirements |
| --- | --- | --- | --- |
| Android 7+ (API 24) | Yes | Yes | Bluetooth runtime permissions; internet permission for relays |
| iOS 15+ | Yes | Yes | Bluetooth usage string; background modes if needed |
| macOS 12+ | Yes | Yes | Bluetooth entitlement; network entitlement for relays |
| Web | No | Yes | Use the core library with an app-provided identity and storage strategy |
| Windows, Linux | No | Yes | Use relay chat; `file_store.dart` is available on desktop |

BLE needs physical devices. A simulator, desktop web browser, or unit test
cannot prove radio discovery. On platforms without native BLE,
`BleMeshTransport.capabilities()` reports no BLE support and `start()` throws
`BleUnsupportedPlatformException`. Do not include `BleChatTransport` in the
chat's transport list on those platforms. The high-level chat requires at
least one transport.

Nostr carries direct packets and acknowledgements, including encrypted group
key updates. Public channels and group messages stay on BLE. Nostr needs
internet access, relay URLs, and a recipient whose public keys are already
known or pinned. Use `wss://` relay URLs in deployed apps.

## 2. Add packages and configure the host app

```yaml
dependencies:
  flutter:
    sdk: flutter
  ble_mesh_chat: ^0.1.2
  path_provider: ^2.1.6 # for the durable-storage example below
```

Run `flutter pub get`. Import the public entry points only:

```dart
import 'package:ble_mesh_chat/ble_mesh_chat.dart';
import 'package:ble_mesh_chat/file_store.dart'; // dart:io; omit on web
```

Do not import `package:ble_mesh_chat/src/...`: those files are internal. For a
web app, use the core entry point and your own `IdentityStore`, `MessageStore`,
and `GroupStore` implementations; the supplied file stores import `dart:io`.

### Android

Set `minSdk` to at least **24** in `android/app/build.gradle` or
`android/app/build.gradle.kts`. The plugin manifest merges Bluetooth scan,
advertise, connect, legacy location, and foreground-service permissions into
the app. The plugin requests the runtime Bluetooth permissions through
`requestPermissions()`; show users why nearby-device access is needed.

If using relays, put `android.permission.INTERNET` in the host app manifest.
If enabling the Android foreground service, request
`android.permission.POST_NOTIFICATIONS` on Android 13+ when you want its
notification to be visible. `enableBackground` in the BLE config enables the
service, but device battery policies can still interrupt it. The scan
permission uses `neverForLocation`; your app must not infer location from BLE
scan results if relying on that declaration.

### iOS

The plugin pod targets iOS **15.0+**. Add this to the host app's
`ios/Runner/Info.plist`, replacing the usage text with your product wording:

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Exchange messages with nearby devices using Bluetooth.</string>
<key>UIBackgroundModes</key>
<array>
  <string>bluetooth-central</string>
  <string>bluetooth-peripheral</string>
</array>
```

Include the background modes only when your app needs background BLE. Two
backgrounded iOS devices generally cannot discover each other, so keep at
least one device in the foreground for a reliable relay. Review the app's
encryption export-compliance answer before App Store submission.

### macOS

The plugin pod targets macOS **12.0+**. Add
`com.apple.security.device.bluetooth` to both
`macos/Runner/DebugProfile.entitlements` and
`macos/Runner/Release.entitlements`. Add
`com.apple.security.network.client` if using Nostr. Check both files: a
sandboxed build can fail to use the radio without the Bluetooth entitlement.

## 3. Give your app its own BLE network

Generate **two** UUIDs with `uuidgen` and keep the same pair across all
installations of your app. A service UUID identifies the mesh; the
characteristic UUID carries frames. Do not distribute the sample
`BleMeshUuids` values, because unrelated apps using them would discover one
another.

```dart
final bleConfig = BleMeshTransport.defaultConfig(
  serviceUuid: 'YOUR-SERVICE-UUID',
  characteristicUuid: 'YOUR-CHARACTERISTIC-UUID',
  advertisedName: 'myapp',
  enableBackground: true, // Android foreground service
);
```

Changing either UUID in a shipped app splits the network until every device
uses the new pair. Changing the characteristic alone also breaks frame
exchange. The byte transport can be used independently for another protocol;
see [the low-level example](../README.md#low-level-byte-transport).

## 4. Create a durable identity and chat

The following is the core startup sequence for Android, iOS, and macOS. Call
it from an app service or widget lifecycle and retain its objects. Replace
`Alice` and the UUID placeholders. Import `path_provider` and use
`getApplicationSupportDirectory()` for the example file stores.

```dart
import 'dart:io';

import 'package:ble_mesh_chat/ble_mesh_chat.dart';
import 'package:ble_mesh_chat/file_store.dart';
import 'package:path_provider/path_provider.dart';

final directory = await getApplicationSupportDirectory();
final identityStore = PlatformIdentityStore(
  fallback: FileIdentityStore(directory: directory),
);
final keys = await loadOrCreateIdentity(identityStore);
final identity = ChatIdentity(peerId: keys.peerId, displayName: 'Alice');
final security = PacketSecurity(
  identity: keys,
  trustStore: await identityStore.loadTrust(),
);

final ble = BleMeshTransport();
final capabilities = await ble.capabilities();
final permission = await ble.requestPermissions();
final bleAllowed = capabilities.supportsCentral &&
    capabilities.supportsPeripheral &&
    (permission == BlePermissionState.granted ||
     permission == BlePermissionState.notRequired);

final chat = BleMeshChat(
  security: security,
  store: FileMessageStore.at('${directory.path}/chat.log'),
  groupStore: PlatformGroupStore(
    fallback: FileGroupStore(File('${directory.path}/groups.keys')),
  ),
);

final subscriptions = [
  chat.messages.listen((message) {
    // Treat received text as untrusted in your UI and automation.
    print(UntrustedText.stripHidden(message.text));
  }),
  chat.messageStates.listen((change) => print(change.state.name)),
  chat.errors.listen((error) => print('Chat: $error')),
  chat.peers.listen((peers) async {
    // Save trust-on-first-use pins after BLE discovery.
    await identityStore.saveTrust(security.trustStore);
  }),
];

final transports = <ChatTransport>[];
if (bleAllowed) {
  transports.add(BleChatTransport(
    identity: identity,
    transport: ble,
    config: bleConfig,
    security: security,
  ));
}
// Optional online route. Configure at least one real relay for delivery.
transports.add(NostrChatTransport(
  identity: identity,
  relays: const ['wss://YOUR-RELAY-HOST'],
));

await chat.initialize(identity: identity, transports: transports);
```

The `bleConfig` variable is defined in step 3. If you want BLE
only, omit the Nostr transport and `INTERNET` permission, but show a useful
error if Bluetooth is unavailable so the transport list is never empty.

`PlatformIdentityStore` uses Android Keystore or the Apple Keychain for
private keys, with the supplied file fallback on unsupported platforms.
The fallback stores private keys in plaintext. Keep the identity persistent:
regenerating it changes your peer ID, makes saved contacts point to the old
identity, and prevents reading messages encrypted for it. Persist trust pins
after discovery or after importing a contact code. Present safety numbers for
out-of-band verification when identity authenticity matters.

Subscribe to `messages` and `messageStates` **before** `initialize`, because
stored history and states are emitted during startup. `send` and `sendDirect`
return after the first delivery attempt. `sent` means a route accepted a
packet; `delivered` means a signed recipient acknowledgement arrived.

## 5. Send messages and manage lifetime

```dart
await chat.send(conversationId: 'general', text: 'Hello nearby devices');
await chat.sendDirect(peerId: contactPeerId, text: 'Private message');
```

The public channel is signed but readable by nearby participants. Direct
messages require the contact's public keys, learned from a BLE meeting or
imported with `ChatPublicKeys.fromContactCode`. An unknown or changed key
causes `MessageSecurityException` or `PeerKeyChangedException`; handle that in
your contact flow. See [CRYPTO.md](CRYPTO.md) for the trust model and encrypted
groups. Nostr accepts only pinned contacts by default.

On shutdown, cancel your app's stream subscriptions, then call
`await chat.dispose()`. If you passed a `BleMeshTransport` into
`BleChatTransport`, call `await ble.dispose()` too; the chat transport does
not own it. When the app resumes, call `NostrChatTransport.reconnectNow()` to
promptly recheck online relays. The [example app](../example/lib/main.dart)
implements a full lifecycle and UI.

## 6. Verify on devices

1. Install the example or your app on two physical devices and grant Bluetooth
   permission. Both must use the same service and characteristic UUIDs.
2. Confirm adapter state, link count, and authenticated peer count. A raw
   link is not yet an authenticated peer.
3. Send a public-channel message in both directions. Then exchange or pin
   contact keys and send a direct message; observe `delivered` after the
   recipient acknowledges it.
4. For a relay test, use three devices A–B–C. Put A and C out of range of one
   another and verify that B carries a message once. iOS background discovery
   needs a foreground participant.
5. For online delivery, put contacts out of BLE range, configure the same
   working relay set, and check `errors` and the delivery state. An empty
   relay list leaves the Nostr transport idle; `setRelays` can update it while
   running.

See [integration testing](INTEGRATION_TESTING.md) for automated and manual
checks. See [limitations](LIMITATIONS.md) before production use: the custom
cryptographic protocol has not had an external review, and platform background
behaviour constrains availability.
