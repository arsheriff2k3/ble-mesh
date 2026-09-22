# ble_mesh_example

Two-device echo harness for the `ble_mesh` plugin — the smallest possible thing
between you and the radio.

It is not a chat app. It starts the transport, lists live links with their
negotiated frame size, and echoes whatever you type to every neighbour. When
something goes wrong on real hardware, debug it here first.

```bash
flutter run     # install on at least two devices, or it proves nothing
```

1. Tap **Start** on both devices and grant permissions.
2. A link should appear within a few seconds, with `maxFrame` well above 20
   bytes (MTU negotiation worked).
3. Send a line from either side; it should show up on the other.
4. Walk one device out of range and back: the link should drop and re-form.

For multi-hop you need three devices, with A and C out of range of each other
and B in the middle. Two devices cannot show you routing.

The harness uses the sample UUIDs from `BleMeshUuids`, so every copy of it on
the same site joins the same network. Your own app should generate its own —
see the plugin README.
