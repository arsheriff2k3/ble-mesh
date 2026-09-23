# Changelog

## 0.1.0 (unreleased)

First cut of the transport. Android, iOS, and macOS build and link, and the
example harness runs on an iOS simulator with the plugin registered. Not yet
verified on radio hardware — the simulator has no Bluetooth (see
`../README.md`).

- Pigeon channel contract with a single ordered event channel, so a frame can
  never be delivered before the `linkUp` for its own link.
- Android: dual-role transport — duty-cycled filtered scanning, GATT client
  with MTU negotiation and CCCD subscription, advertiser plus GATT server,
  per-connection operation queue, exponential connect backoff, adapter-state
  recovery, and a `connectedDevice` foreground service.
- iOS/macOS: dual-role transport over CoreBluetooth with write-without-response
  backpressure, notification queueing, and basic state restoration. iOS and
  macOS share one Swift source tree.
- Dart facade with live link bookkeeping, `minFrameSize`, broadcast fan-out
  that reports per-link outcomes, typed exceptions, and graceful degradation on
  platforms with no BLE implementation.
- Phase 1 chat preview: deterministic bounded packet codec, BLE fragmentation
  and reassembly, peer announcements with duplicate-link suppression, TTL
  flooding, deduplication, randomized relay jitter, direct-message
  acknowledgements, in-memory offline queue, and the high-level `BleMeshChat`
  API.
- Three-node in-memory relay coverage and a physical-device chat/diagnostics
  harness. Encryption is not part of this preview.
- `ChatMessage.threadId` and `ChatMessage.isDirect`. `conversationId` is the
  raw packet destination, which names the recipient and so differs between the
  two ends of a direct conversation; `threadId` is the stable key to group by.
- A link that disappears between the send decision and the platform write no
  longer reaches `BleChatTransport.errors`. It was already reported through
  `deliveredRoutes`, and the router queues or retries on the remaining links.
- The example harness can hold direct conversations: a thread selector for
  `#general` and each peer, per-thread history and unread badges, and
  per-message delivery state.
- Phase 2 durable chat: `FileMessageStore`, an append-only checksummed log
  that keeps the outbound queue, conversations, message state, and seen packet
  ids across process restarts. Exposed from `package:ble_mesh/file_store.dart`
  rather than the main library so the core stays free of `dart:io`.
- `MessageStore` gained message, state, and seen-id persistence alongside the
  outbound queue, plus `open`/`close`. `InMemoryMessageStore` implements the
  same contract and stays the default.
- Queue quotas with an explicit `MessageStoreFullException` instead of silent
  eviction, packet expiry enforced on read and on reopen, and log compaction
  through an atomic rename.
- Queued sends retry on a capped exponential backoff, and draining a backlog
  is spaced by `retrySpacing` so a reconnect is not a broadcast burst.
- Phase 3 (in progress) cryptography, **experimental and unreviewed**: the
  `x25519-xchacha20poly1305-v1` suite, Ed25519 packet signatures, key-derived
  peer ids, and trust-on-first-use key pinning. Documented in `docs/CRYPTO.md`.
- Packet format version 2 carries an optional Ed25519 signature and a sealed
  payload flag. The signed input excludes TTL so relays can still decrement it.
- `PacketSecurity.verifyForRelay` lets a relay authenticate a packet it cannot
  read, so forged packets are dropped before they occupy a packet id.
- Signed peer announcements carrying public keys, so a peer arrives verifiable
  and addressable in one frame. An announcement that fails verification is
  dropped rather than admitted as an unauthenticated peer.
- Direct messages are sealed end to end and acknowledgements are signed, so
  `delivered` means the recipient confirmed it rather than a device on the
  path having claimed so.
- Private keys live in Android Keystore (AES-GCM wrapped) and the iOS/macOS
  Keychain, through the new `dev.blemesh.ble_mesh/keys` channel, with a plain
  file fallback where neither exists.
- Peer ids are now the fingerprint of the signing key rather than a chosen
  label. **This invalidates identities and history from earlier builds.**

- Phase 3 review fixes: wire v3 uses length-prefixed signature/AAD fields and
  carries origin public keys. Reject forged packets before deduplication and
  require acknowledgements from the original recipient, including after restart.
- Authenticate each BLE link with a fresh challenge; discover remote peers with
  bounded signed advertisements. Chat traffic uses authenticated links only.
- Preserve secure-storage errors, migrate private seeds to one atomic record,
  and serialize file identity/trust writes. Add agreement-key rotation and an
  approval prompt in the example. Encryption remains experimental.
- Wire v1/v2 queues are marked failed on upgrade without discarding history.
  Upgrade all participating devices together and resend failed old messages.

- Encrypted groups: durable secure group keys, owner-controlled membership,
  encrypted per-member key updates, epoch rotation after member removal,
  signed group traffic, and example controls for manual acceptance.
- Direct packets now remain queued until an authenticated recipient
  acknowledgement, including offline group key updates. Added deterministic
  packet/signature/direct/group vectors in `docs/TEST_VECTORS.md`.
- Add Android, iOS, and macOS example build jobs for CI. Bound inbound and relay
  work, space backlog sends by default, and retry cached relays after peer
  topology changes. Recipients re-acknowledge direct retries when needed.
- Keep expired queued packets until their failed state is persisted. Serialize
  file-store writes and compaction during long sessions, preserve live state
  after write failures, and cap retained replay IDs without admitting replays.
- Forward authenticated encrypted group traffic through nonmember relays.
