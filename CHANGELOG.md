# Changelog

## 0.1.2

- Added an end-to-end integration guide with per-platform setup, persistent
  identity, app-owned UUIDs, lifecycle, and online-only fallback.
- Corrected the README install version and chat setup example; clarified the
  BLE support matrix and public API boundaries.

**Upgrade notes:** No Dart API, wire format, storage format, or platform
configuration changes. Existing `0.1.1` integrations need no code changes.

## 0.1.1

- Relays can be changed while running with `NostrChatTransport.setRelays`,
  and an empty relay list is allowed (the transport stays idle until relays
  are added).
- Relay connections are checked with a keep-alive probe
  (`keepAliveInterval`, `keepAliveTimeout`). A connection that silently
  stops delivering, for example behind a mobile hotspot, is detected and
  reconnected, and missed events are fetched again.
- `maximumReconnectDelay` now defaults to 30 seconds instead of 5 minutes.
- BLE links that disappear when Bluetooth is switched off are forgotten
  immediately, and a new connection that reuses a link id must identify
  itself again.
- The BLE radio starts automatically once Bluetooth becomes available, even
  if `start` ran while it was off (`radioRecoveryInterval`).
- When a peer reconnects, its fresh link is kept over a stale one
  (`staleLinkAge`), and a link whose writes fail is dropped.
- Direct messages fall back to other transports within the same attempt when
  the transport listing the recipient reaches no one.
- Documentation cleanup.

## 0.1.0

First public release.

- **BLE transport:** dual-role (central and peripheral) Bluetooth Low Energy
  on Android, iOS, and macOS, with an ordered event channel, per-link frame
  sizes, and broadcast. Unsupported platforms degrade without crashing.
- **Mesh chat:** `BleMeshChat` with a bounded binary packet codec,
  fragmentation and reassembly, TTL flooding with jitter, deduplication, and
  acknowledgements. `sent` means a route accepted a message; `delivered`
  means the recipient confirmed it.
- **Durable storage:** `FileMessageStore` keeps the outbound queue, history,
  message state, and replay protection across restarts, with quotas and
  crash-tolerant writes.
- **Security (experimental, not externally reviewed):** Ed25519 packet
  signatures, peer ids derived from signing keys, sealed direct messages
  (X25519, HKDF-SHA256, XChaCha20-Poly1305), encrypted groups with key
  rotation, trust on first use, contact codes, safety numbers, and private
  keys in Android Keystore or the Apple Keychain.
- **Online delivery:** `NostrChatTransport` carries encrypted direct messages
  through Nostr relays, with per-packet envelope keys, reconnection, and
  backfill for offline recipients.
- **Bridging:** opt-in gateways carry consenting traffic between BLE and
  Nostr, with loop prevention and metered and roaming policies.
- **Abuse resistance:** per-sender and per-route rate limits, packet lifetime
  caps, contacts-only online delivery by default, a hidden-character
  sanitizer for message text, and fuzz-tested parsers.
- An example app covering all of the above.
