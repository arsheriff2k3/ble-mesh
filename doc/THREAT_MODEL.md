# Threat model: automated attacks

AI tooling makes some attacks on a chat plugin much cheaper. Machine-generated
malformed input finds parser bugs, bots run thousands of fresh identities,
invisible text carries instructions to LLMs, and synthesized voices and faces
make impersonation convincing. This document maps each of these to what the
plugin does and what remains the host's job.

The cryptography itself is covered in [CRYPTO.md](CRYPTO.md) and is still
**experimental and unreviewed**.

## Summary

| Attack | Plugin defence | Residual risk |
| --- | --- | --- |
| Fuzzing parsers for crashes | Typed errors from every parser; fuzz suite | Native BLE code is not fuzzed |
| Replay-store exhaustion via far-future expiry | Lifetime and clock-skew caps | None known |
| Floods from one identity | Per-sender token bucket | — |
| Swarms of fresh identities | Per-route token bucket; contacts-only on Nostr | Many routes can still evict history |
| Hidden-text prompt injection | `UntrustedText`, `ChatMessage.hasHiddenCharacters` | Visible injected text |
| Deepfake impersonation around key changes | Safety numbers; in-person comparison prompt | Users who approve without checking |
| Traffic analysis | Per-packet Nostr keys, hashed routes | Sizes, timing, BLE presence |
| Malicious dependency updates | Exact pin on `bip340`; lockfile | Transitive dependencies |

## Fuzzing

Every parser that sees untrusted bytes can fail only with its typed format
error: the packet codec, fragment reassembly, Nostr event JSON, relay
messages, and contact codes. The streams they feed keep working afterwards.
`test/fuzz_test.dart` checks this with fixed seeds. It covers random and
mutated inputs at the codec, router, BLE transport, and Nostr transport
layers. Anything that decodes must re-encode to identical bytes. A deeper
run of 40,000+ cases per target found no failures.

The Kotlin and Swift BLE code is not covered. It only moves frames, but it
should get platform fuzzing before a stable release.

## Floods and fake identities

A signature proves who sent a packet, not that the sender is scarce, and
generating an identity costs milliseconds. `BleMeshChat` therefore limits
work without trusting identity:

- **Lifetime caps.** Packets whose `expiresAt − createdAt` exceeds
  `maximumPacketLifetime` (24 h), or whose `createdAt` is more than
  `maximumClockSkew` (10 min) in the future, are dropped before any other
  processing. Without this, signed packets that "expire" in 2100
  permanently filled the replay-protection store (65,536 ids by default),
  and every later packet, including honest ones, was refused.
- **Per-route budget** (default burst 400, 20/s) per BLE link or relay. It
  is spent before signature verification, so a neighbour cannot make the
  device burn CPU faster than it may send, and it bounds swarms of fresh
  identities arriving over one route.
- **Per-sender budget** (default burst 100, 2/s), charged after
  authentication so it cannot be spent in someone else's name. It is
  charged before the packet id is reserved, so a dropped packet is still
  accepted when its sender retries. Over-budget packets are not relayed,
  so a flood stops at the first hop instead of crossing the mesh.
- **Contacts-only transports.** `contactsOnlyTransports` defaults to
  `{'nostr'}`: online, only senders whose key is already pinned are
  accepted. This covers keys pinned from a BLE meeting or a contact code.
  Strangers get no ACK and are not pinned by trying.
- Drops are reported as `InboundRateLimitedException` or
  `UnknownSenderException`, at most once a minute per key.

Residual: a sybil swarm spread across many routes can still push old
messages out of the bounded history store, and nearby BLE strangers are
accepted by default. Hosts in hostile environments can add `'ble'` to
`contactsOnlyTransports`. Nostr proof-of-work (NIP-13) is not implemented.

## Hidden-text prompt injection

Message text is attacker-controlled. Tag characters (U+E0000–U+E007F), runs
of variation selectors, bidirectional overrides, and zero-width characters
can hide text from a person while an LLM that summarizes or answers messages
still reads it. `UntrustedText.stripHidden` removes them and keeps legitimate
emoji ZWJ sequences, single variation selectors, subdivision flags, ZWNJ,
and LRM/RLM. `ChatMessage.hasHiddenCharacters` flags affected messages, and
the example shows sanitized text with a warning.

Stripping protects what a person sees. It cannot make message text safe as
instructions. Hosts that pass messages to an LLM or other automation must:

- present them as quoted, untrusted data, never as system or developer
  instructions;
- keep tools that send, delete, pay, or reveal data behind explicit user
  confirmation;
- never let message content choose a recipient, URL, or command.

## Impersonation and synthetic media

Trust on first use stops a stranger from silently replacing a known contact,
but a key-change prompt is only as good as the person approving it. A caller
with a cloned voice can talk a user through "accept the new key".
`ChatPublicKeys.safetyNumber` gives both sides the same 60 digits covering
both parties' signing and agreement keys. They are stretched with 5200 hash
rounds so that grinding a key to match the first groups is costly. The
example shows it in the key-change prompt and after adding a contact, and
says to compare it in person because calls can be faked. Contact codes carry
the same warning: whoever supplies the code decides whom you trust.

## Traffic analysis

Machine-learning classifiers infer a great deal from sizes and timing.
Nostr envelopes use a fresh key per packet, and recipient routes are
hashed, but the following are not hidden:

- **Message length.** Sealed payloads are not padded. Padding to fixed
  buckets needs a wire-format change and is the recommended next step.
- **Timing and ACK pairing.** Relays and BLE observers can link a message
  to its acknowledgement.
- **Presence.** The BLE service UUID is fixed per app (`BleConfig.serviceUuid`,
  with a plugin default), so nearby receivers can tell a user of that app is
  present and can track a device over time.

## Supply chain

`bip340` is pinned to the exact reviewed version (`0.3.1`) because it is a
small single-maintainer package on the signing path. Review its source diff
before bumping it. Other dependencies use caret ranges resolved through the
committed example lockfile. Recommended CI additions: OSV-Scanner over
`pubspec.lock`, and a check that new dependencies come from verified
publishers. Do not add packages suggested by an AI assistant
without confirming they exist and are the intended package.
