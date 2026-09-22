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
