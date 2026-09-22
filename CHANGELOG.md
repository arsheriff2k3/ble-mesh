# Changelog

## 0.1.0 (unreleased)

First cut of the transport. Not yet verified on hardware; the Darwin sources
have not been compiled (see `../README.md`).

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
