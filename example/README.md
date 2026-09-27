# ble_mesh_chat example

A chat and diagnostics app for `ble_mesh_chat`. It uses the high-level
`BleMeshChat` API and shows adapter, link, peer, relay, and delivery state.

```bash
flutter run     # install on two or more physical devices
```

1. Tap **Start** on every device and grant the Bluetooth permission.
2. Link and peer counts rise within a few seconds.
3. Send a message in `#general`; it shows up on every reachable device.
4. Select a peer to send an encrypted direct message. It moves from `sent`
   to `delivered` when the recipient acknowledges it.
5. For multi-hop delivery, put A and C out of range of each other with B in
   between. Messages between A and C arrive once, through B.

Optional features, all in the top bar:

- **Contacts:** share or paste a contact code to add someone you have not
  met over Bluetooth.
- **Online relays:** add `wss://` Nostr relays for delivery over the
  internet. Changes apply immediately.
- **Gateway and bridging:** let gateways carry your messages, or act as a
  gateway for nearby offline devices.

Diagnostics are shown in the app and mirrored to `adb logcat -s flutter`.

The app uses the sample UUIDs from `BleMeshUuids`, so every copy of it
nearby joins the same network. Your own app should generate its own; see the
plugin README.
