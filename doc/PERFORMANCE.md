# Performance

## Host baseline

Measured with `flutter test benchmark/chat_benchmark_test.dart` on an Apple
Silicon Mac (10 cores, macOS 15.7, Flutter 3.47, Dart 3.13). `flutter test`
runs in JIT mode on the host, so these numbers are a relative baseline, not
phone figures. Mid-range phones are typically 2–5× slower for the
cryptographic rows.

| Operation | Time |
| --- | --- |
| Codec encode, 1 KiB payload (1228 B on the wire) | 1.6 µs |
| Codec decode, 1 KiB payload | 2.0 µs |
| Fragment 4 KiB into 244 B frames (18 frames) | 1.3 µs |
| Reassemble 4 KiB from 244 B frames | 7.8 µs |
| Seal + sign a direct message (X25519, XChaCha20-Poly1305, Ed25519) | 2.5 ms |
| Verify + open a direct message | 2.0 ms |
| Relay verification only (Ed25519) | 1.5 ms |
| BIP-340 sign / verify (vendored, pure Dart) | 6.1 / 6.0 ms |
| Nostr envelope key generation | 3.0 ms |
| Safety number (5200 SHA-256 rounds per side) | 14.7 ms |
| Send → signed ACK, 1 / 3 / 5 hops in memory, p50 | 7.8 / 13.9 / 20.0 ms |
| Send → signed ACK, 1 / 3 / 5 hops in memory, p95 | 8.3 / 14.3 / 20.5 ms |
| Enqueue, in-memory store | 14 µs |
| Enqueue, file store (checksummed append, flushed) | 134 µs |
| File store growth per queued short message | 231 B |
| Close and reopen a file store holding 500 queued packets | 5.2 ms |

### What the numbers mean

- **Cryptography dominates.** Parsing and fragmentation are microseconds.
  Signing and verifying are milliseconds, because `package:cryptography`
  falls back to pure-Dart Ed25519 and X25519. Every relay verifies every
  packet before forwarding it, so on a phone a single relay can verify
  roughly 150–400 packets per second. That sits comfortably above the
  default per-route budget of 20 packets per second.
- **Hop latency** in memory is about 3 ms of CPU per hop, mostly signature
  checks. On radios, relay jitter (up to 250 ms by default) and BLE
  connection intervals dominate. Expect roughly 150–400 ms per hop, to be
  confirmed on devices.
- **The file store** appends and flushes each change. At about 7,000
  enqueues per second it is not a bottleneck, and the default quota of 1024
  queued packets bounds it to well under 1 MiB.
- **Nostr envelopes** cost about 9 ms each to create (key generation plus
  signing) and 6 ms each to verify inbound. A gateway at its default budget
  of 120 packets per minute spends under 2% of one core on this.

### Recommended optimisation

Adding `cryptography_flutter` to the host app makes `package:cryptography`
use the platform's native Ed25519, X25519, and ChaCha20 implementations on
Android and iOS. This is typically an order of magnitude faster and reduces
battery use on relays. It is not a plugin dependency, so hosts can opt in;
benchmark it before and after on target phones.

## Device measurements

Radio throughput, battery, and thermal behaviour cannot be measured on a
host. Use these recipes on real devices.

**BLE throughput.** Connect two phones with the example app. Send 100
messages of 4 KiB from A to B. Divide the bytes delivered by the time from
the first send until B displays the last message. Repeat for Android↔Android,
iPhone↔iPhone, and Android↔iPhone, and record the negotiated frame size shown
in Diagnostics.

**Delivery latency.** Record send-to-`delivered` for 50 direct messages over
one, two, and three BLE hops. Report p50 and p95, and repeat with each phone
backgrounded.

**Queue growth.** Queue 1,000 messages while offline. Record the store file
size (under the app's support directory) and the time to drain once a route
appears.

**Battery.** Charge to 100% and run a 3-phone relay for four hours with one
message every 30 seconds. Record the battery percentage every hour, with the
screen off, on each phone. Then repeat with one phone acting as a Nostr
gateway on cellular data.
