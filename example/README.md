# ble_mesh chat harness

Minimal Phase 1 group-chat and diagnostics harness. It uses the high-level
`BleMeshChat` API while showing adapter, link, peer, queue, and delivery state.

```bash
flutter run     # install on three physical devices for the relay test
```

1. Tap **Start** on all devices and grant permissions.
2. The link and discovered-peer counts should increase within a few seconds.
3. Send a line in `#general`; it should show up on every reachable device.
4. Walk one device out of range and back: the link should drop and re-form.

For multi-hop, place A and C out of range of each other with B in the middle.
Messages between A and C must arrive once through B. The automated suite models
this topology, but only this physical test validates the radios.

The harness uses the sample UUIDs from `BleMeshUuids`, so every copy of it on
the same site joins the same network. Your own app should generate its own —
see the plugin README.
