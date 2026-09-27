# Limitations

This page collects every known security, platform, and resource limitation
in one place. Read it before depending on `ble_mesh_chat`.

## Security

- **The cryptography is experimental and has not been externally
  reviewed.** The primitives are standard (Ed25519, X25519,
  XChaCha20-Poly1305, HKDF-SHA256), but the protocol that combines them is
  custom. Test vectors in `TEST_VECTORS.md` are self-generated. Do not rely
  on it to protect people at risk until a review completes. See `CRYPTO.md`.
- **No forward secrecy or post-compromise security.** A stolen agreement
  key decrypts past and future direct messages sent to it.
- **Trust on first use.** The first contact with a peer, or a contact code
  from an untrusted source, is not authenticated. Safety numbers exist, but
  the example does not enforce comparing them.
- **Metadata is visible.** Relays and BLE observers see sender and
  recipient peer ids, timing, and sizes. Payloads are not padded. Relays see
  client IP addresses, and gateways reveal which offline devices are nearby.
  See `CRYPTO.md`, `BRIDGE.md`, and `THREAT_MODEL.md`.
- **Channel (`#general`) messages are signed but readable** by anyone in
  range. Use an encrypted group or a direct message for confidential
  traffic.
- **The file identity fallback is plaintext.** It is used only where
  Android Keystore or the Apple Keychain is unavailable.
- **Presence.** The BLE service UUID is fixed per app, which lets observers
  detect and track that app's users.
- **Envelope signing is not constant-time.** BIP-340 runs in pure Dart and
  is used only with single-use envelope keys.
- **Message text is untrusted input.** Hidden characters are detectable
  (`UntrustedText`), but visible text can still contain instructions aimed
  at an LLM. Never pass message text to automation as instructions.

## Platform

| Platform | BLE mesh | Nostr | Notes |
| --- | --- | --- | --- |
| Android 7+ (API 24) | Yes | Yes | A foreground service keeps the mesh alive; OEM battery managers may still stop it. Nearby Devices permission required on 12+. |
| iOS | Yes | Yes | Two backgrounded iPhones usually cannot discover each other; at least one device must be foregrounded. Background sockets are suspended, so gateways and online delivery work in the foreground only. |
| macOS | Yes | Yes | Needs the Bluetooth and network-client entitlements. |
| Web, Windows, Linux | No (`BleUnsupportedPlatformException`, capabilities report unsupported) | Web: yes. Desktop: yes. | The core library avoids `dart:io`; `file_store.dart` does not. |

Other platform notes:

- Frame size depends on the negotiated MTU. The first message on a new link
  may be fragmented more than later ones.
- A simulator cannot validate the BLE mesh: it has no radio.
- The plugin cannot observe metered or roaming connections. The host must
  report them for gateway policies to take effect.

## Resource limits

Every bound below is enforced. Excess work is rejected or dropped, with a
typed error where the API has one, rather than growing without limit.

| Resource | Limit | Where | On excess |
| --- | --- | --- | --- |
| Simultaneous BLE links | 6 by default (`BleConfig.maxConcurrentLinks`); Android hardware is often ~7 | native | New links refused |
| Encoded packet (BLE) | 64 KiB | `ChatPacketCodec` | `ChatPacketFormatException` |
| Encoded packet (Nostr) | 32 KiB (`maximumPacketSize`) | `NostrChatTransport` | Not published; inbound rejected |
| Fragments per packet | 65,535 | `PacketFragmenter` | `FragmentFormatException` |
| Concurrent reassemblies | 32 per device, 20 s timeout | `PacketReassembler` | Oldest evicted |
| Packet TTL | 1–255 (default 5) | `ChatPacket` | `ArgumentError` |
| Packet lifetime from others | 24 h, with 10 min clock skew | `BleMeshChat` | Dropped |
| Pending inbound work | 256 packets | `BleMeshChat` | Dropped |
| Inbound per sender | burst 100, 2/s | `BleMeshChat` | Dropped; `InboundRateLimitedException` |
| Inbound per route | burst 400, 20/s | `BleMeshChat` | Dropped; `InboundRateLimitedException` |
| Relay cache for new peers | 256 packets | `BleMeshChat` | Oldest evicted |
| Queued outbound packets | 1,024 | message stores | `MessageStoreFullException` |
| Retained messages | 4,096 | message stores | Oldest evicted |
| Replay-protection ids | 65,536 unexpired | message stores | `SeenPacketQuotaException` |
| Groups / members per group | 256 / 64 | `BleMeshChat` | `StateError` / `ArgumentError` |
| Discovered remote peers | 256 | `BleChatTransport` | Ignored |
| Relays | 16 | `NostrChatTransport` | `ArgumentError` |
| Relay subscription backfill | 2 h, 200 events per relay | `NostrChatTransport` | Older events not requested |
| Pending inbound relay events | 256 | `NostrChatTransport` | Dropped |
| Bridged packets | 120 per minute | `BridgePolicy` | Dropped; `InboundRateLimitedException` |
| Offline devices per gateway | 32 (hard cap 64) | `BridgePolicy` | Registration ignored |
