# `ble_mesh_chat` cryptography

> **Experimental.** This suite has not had an external review. Do not rely on
> it to protect anyone whose safety depends on the result. The API and the wire
> format may change without a compatibility shim until that review is done.

## What this protects

| Property | Status |
| --- | --- |
| A relay cannot read a direct message | yes |
| A relay cannot alter sender, destination, expiry, or content | yes |
| A stranger cannot impersonate an existing contact | yes, after first contact |
| A replayed packet is displayed once | yes |
| Encrypted group messages are confidential to current members | yes, under the current epoch key |
| Channel (`#general`) messages are confidential | **no** — signed, not encrypted |
| Forward secrecy if the sender's key leaks later | yes, per message |
| Forward secrecy if the *recipient's* key leaks later | **no** |
| Metadata (who talks to whom, when, how often) is hidden | **no** |

A mesh packet carries a readable destination for relays, so traffic analysis
is available to anyone in radio range. Public channels remain readable.
Encrypted groups use separate `g:` destinations and rotating shared keys.

## Suite

`x25519-xchacha20poly1305-v1`

| Purpose | Algorithm | Reference |
| --- | --- | --- |
| Identity and packet signatures | Ed25519 | RFC 8032 |
| Key agreement | X25519 | RFC 7748 |
| Key derivation | HKDF-SHA256 | RFC 5869 |
| Authenticated encryption | XChaCha20-Poly1305 | RFC 8439 + XChaCha draft |

All four have published test vectors and multiple independent
implementations. Nothing here is homemade; the composition is the part that
needs review, not the primitives.

### Why not a handshake protocol

Noise and the Double Ratchet both assume the two parties can complete a
handshake. In this network the recipient is regularly asleep, out of range, or
several hops away behind a relay that will deliver the packet hours later. A
sealed, self-contained packet is the shape the transport actually has.

The cost is that we get sender-ephemeral forward secrecy rather than
ratcheting: compromising the recipient's long-term key exposes past messages.
That is the main thing a reviewer should push back on.

## Identity

Each peer holds two keys:

- **Ed25519 signing key** — proves authorship
- **X25519 agreement key** — receives sealed messages

They are separate because reusing one key across signing and key agreement is
the classic way to turn reviewed primitives into an unreviewed protocol.

The peer id is derived, not chosen:

```text
peerId = "peer-" || hex(SHA-256(ed25519_public_key)[0..8])
```

This is what makes impersonation detectable. A device that copies a display
name and a peer id but lacks the private key produces packets whose signature
does not verify, and whose claimed id does not match the key that signed them.

## Packet authentication

Every packet is signed. The signed input is canonical and deliberately
excludes the TTL:

```text
signingInput =
  "bmp2" || type || sealedFlag || packetId || LP(originPublicKeys) ||
  createdAt || expiresAt || LP(senderId) || LP(destination) || LP(payload)
```

`LP(bytes)` is a big-endian uint32 byte length followed by those bytes. Text
is UTF-8. Timestamps are signed big-endian int64 milliseconds. Public keys
are Ed25519 (32 bytes) followed by X25519 (32 bytes). Length prefixes keep
embedded zero bytes from changing signed field boundaries.

TTL is excluded because every relay decrements it; including it would break
the signature at the first hop. Everything a relay must not be able to
rewrite — sender, destination, expiry, and content — is covered.

A relay verifies the signature before forwarding, so a forged packet cannot
occupy a packet id in the deduplication cache or be propagated.

## Direct message encryption

```text
ephemeral       = X25519.generate()
shared          = X25519(ephemeral.private, recipient.agreementPublic)
key             = HKDF-SHA256(shared, info = "ble_mesh/message/v1",
                              salt = ephemeral.public || recipient.agreementPublic)
sealed          = XChaCha20-Poly1305(key, nonce, plaintext, aad)
payload         = ephemeral.public || nonce || mac || len(ct) || ct
```

The AEAD's associated data binds the envelope:

```text
aad = "bma2" || type || packetId || LP(originPublicKeys) ||
      expiresAt || LP(senderId) || LP(destination)
```

Both public keys go into the KDF salt so a shared secret cannot be replayed
into a different pairing.

A new ephemeral key per message means two encryptions of identical text differ,
and a nonce is never reused under a given key.

## Trust model: trust on first use

`TrustStore` pins a peer's keys the first time they are seen.

| Verdict | Meaning | Behaviour |
| --- | --- | --- |
| `firstContact` | never seen before | pinned automatically |
| `known` | same key as before | accepted |
| `changed` | different key, same peer id | **rejected**, never adopted silently |

An agreement-key rotation retains the signing key and peer ID, and produces
`PeerKeyChangedException` with the proposed public keys. The example shows an
approval dialog. After comparing keys out of band, the host can call
`acceptRotation(peerId, keys)` and persist the trust store. Mismatched signing
fingerprints are never accepted under an existing peer ID.

`ChatKeyPair.rotateAgreementKey()` produces the replacement identity. Persist
it and restart the transport and facade with that identity; the example's key
button performs this flow and requires an app restart. Old queued ciphertext
for the replaced agreement key cannot be decrypted. Plaintext local history
remains readable.

Losing or rotating the signing key creates a **new peer ID**, not a `changed`
verdict under the old ID. Treat it as a new contact and verify it separately.
The example records the previous ID and logs a change if app data survives
key loss. A complete uninstall that erases app data has no previous local
identity to compare. There is no private-key backup/recovery service.

TOFU does not protect the very first contact. Two people who want certainty
must compare fingerprints out of band; that UI does not exist yet.

## Failure handling

`MessageSecurityException` carries a coarse reason and never the offending
bytes. Errors expose coarse categories rather than plaintext or private key material.
Changed peer keys carry only the public keys needed for an approval prompt.

A direct message to a peer whose key is unknown **throws** rather than sending
in the clear. Silently downgrading would leave a user wrong about whether a
conversation was private, which is worse than a failed send.

## Key storage

Private keys are held by the platform, through
`dev.blemesh.ble_mesh/keys`:

- **Android** — the seeds are sealed with AES-GCM under a non-exportable
  Android Keystore key. The wrapping key is non-exportable through the API;
  hardware backing depends on the device. This is not protection against a
  compromised running app or operating system. User authentication is deliberately *not* required, because the mesh
  has to relay while the phone is locked in a pocket.
- **iOS / macOS** — Keychain, with
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. `ThisDeviceOnly` keeps
  the identity out of iCloud and encrypted backups: a peer id identifies one
  device, and restoring it onto a second phone would make two devices claim
  the same identity.
- **Elsewhere** — `FileIdentityStore`, which is honest about being plain
  files. It exists so desktop and test runs work.

Pinned peer keys are public, so they live beside the message log rather than
in the keystore. Their integrity still relies on the app sandbox.

Both identity seeds are saved in one secure-storage record. The previous
two-record format is migrated without changing keys. Keychain updates replace
the value atomically instead of deleting it first; Android waits for the
wrapped value to be committed. Read errors and partial/corrupt records fail
explicitly and never trigger automatic replacement. A missing native plugin
on Android/iOS/macOS does not fall back to plaintext files. File identity and
trust writes use a serialized temporary-file rename.

## Link authentication and multi-hop discovery

Each BLE link receives a fresh random 256-bit challenge. A signed announcement
must echo that challenge within 30 seconds before the link is authenticated.
Expired announcements are rejected, and captured responses cannot authenticate
another link. Only authenticated links carry chat traffic or participate in
duplicate-link suppression. Failed handshakes retry after timeout.

Separate signed discovery advertisements carry origin keys and names through
up to five hops. They expire after five minutes and refresh every minute.
Discovery is deduplicated after verification, jittered, and capped at 256 live
records; incoming frame processing has a bounded queue. Newly authenticated
links receive cached, unexpired advertisements. A remote peer in the peer list
means recently discovered through the mesh, not necessarily a direct BLE link.

Every signed packet also carries its origin public keys. A newly introduced
relay can verify traffic without previously meeting the origin. Direct sends
still require the recipient's keys, learned through discovery or explicitly
provisioned by the host. Announcements and packet signatures authenticate key
ownership; they do not establish a person's real-world identity.

## Replay and delivery

The facade verifies signatures and decrypts local direct messages before
reserving packet IDs. It checks durable seen IDs as well as the memory cache,
and writes replay state before displaying or forwarding an accepted packet.
Storage failure stops acceptance and is exposed through the error stream.

An acknowledgement can mark a message delivered only when its authenticated
sender matches that message's original direct recipient. That mapping is
restored from retained outgoing history after restart. Arbitrary or unknown
message IDs cannot be acknowledged, and a late transport completion cannot
change `delivered` back to `sent`.

## Encrypted groups

`BleMeshChat.createGroup(memberIds:)` creates a random 256-bit group key and
a unique group ID rooted in the owner's peer ID. The owner must know each
member's public keys. A signed, encrypted direct `groupKeyUpdate` packet sends
the group ID, epoch, member list, and key to each member. The update is queued
until that recipient's signed acknowledgement arrives. It survives an offline
period through the configured `MessageStore`; the keys survive restart through
`GroupStore`. The example uses `PlatformGroupStore`, which stores the serialized
group map in the same Android Keystore or Apple Keychain backed vault as the
identity. The in-memory store is for development; `FileGroupStore` is a
plaintext fallback only on unsupported platforms.

`sendGroup` encrypts content with XChaCha20-Poly1305 under the current group
key and a fresh 24-byte nonce. Its associated data is
`"ble_mesh/group/v1" || packet.associatedData || epoch_u32`. The payload is
`epoch_u32 || nonce_24 || tag_16 || ciphertext`. The signed envelope binds
sender, group destination, expiry, and encrypted payload. Relays can verify
and forward it without a group key. The group ID, sender, time, and traffic
volume remain visible.

Only the group's original owner may call `changeGroupMembers`. That operation
creates a fresh random key, increases the epoch, persists it, and sends the
new key only to remaining members. A removed member still has its old key and
can read old captured traffic, but cannot open messages created under the new
epoch. Current members reject older epoch traffic after rotation. Keys for
older epochs are discarded locally. Future epoch messages that arrive before
the update are held in a bounded, expiring buffer and retried when the update
arrives. A removed member may still see that a group exists on the mesh.

The owner must keep a current signing identity. There is no automatic group
ownership transfer or recovery after owner key loss. The current group model
caps membership at 64 and retained groups at 256. The example offers create,
member change, and send controls so the removal scenario can be performed
manually.

Deterministic suite values for packet signing, direct encryption, and group
AEAD are in [TEST_VECTORS.md](TEST_VECTORS.md). They are generated from fixed
inputs by `tool/generate_crypto_vectors.dart` and still require independent
verification during the external review.

## Nostr relay transport

`NostrChatTransport` adds no new message cryptography. It carries the same
wire-v3 packet, signed by the sender and sealed for the recipient when it is
a direct message, as base64 content inside a NIP-01 event (kind 30078 by
default).

- **Two signatures, two jobs.** The outer BIP-340 signature exists because
  relays require it. It proves only that the event was not modified in
  transit. The Ed25519 packet signature still proves the sender, and the
  facade verifies it before deduplication, as it does for BLE.
- **Per-packet envelope keys.** Each packet is wrapped with a freshly
  generated secp256k1 key, so relays cannot link a sender's events through
  the event `pubkey`. A host may pass a fixed `publisherKey` for relays that
  allow-list by pubkey, at the cost of that linkability.
- **BIP-340 implementation.** Signing and verification use the `bip340`
  package, which is pure Dart and not constant-time. With single-use
  envelope keys, a timing leak does not expose a long-lived secret. The
  suite checks BIP-340 vector 0 against the published value.
- **Only signed, originated, direct packets.** The transport publishes a
  packet only when this device created it, it is addressed to a peer (`p:`),
  and it is signed. Inbound events must pass the event signature, kind, route
  tag, and size checks. Their packet id must match the `d` tag, and the packet
  must be signed and addressed to this device. Anything else is reported on
  `errors` and dropped.
- **Bridging needs signed consent.** The facade relays a packet only on the
  transport it arrived on. The Nostr transport republishes another
  device's packet only when that packet carries its origin's signed
  *bridgeable* flag and this device is an active gateway. See
  [BRIDGE.md](BRIDGE.md).

What relays can see:

| Visible to relays | How |
| --- | --- |
| That the recipient receives traffic | `y` tag = SHA-256 of `p:<peer id>`; anyone who knows a peer id can compute it |
| Packet id, timing, expiry, size | `d` tag, `created_at`, NIP-40 `expiration`, content length |
| Sender peer id and public keys | inside the packet header, which is signed but not encrypted |
| Which packet an ACK confirms | ACK payloads are signed but readable |
| Client IP address | every WebSocket connection |

Relays cannot read direct-message text or forge a packet. A relay can drop,
delay, or withhold events. Delivery state reflects this: a relay `OK` is only
`sent`, and `delivered` still requires the recipient's signed
acknowledgement. Online first contact still uses trust on first use:
`ChatPublicKeys.toContactCode()` gives a shareable code, and whoever supplies
that code decides whom you trust. Anyone who knows a peer id can send it
signed traffic, so rate limiting and blocking remain the host's
responsibility.

## Upgrade compatibility

This revision uses **wire version 3** and signing/AAD domains `bmp2`/`bma2`.
All participating devices must upgrade together. Older wire packets are
rejected; there is no downgrade to the ambiguous signing format. Durable
history and seen IDs are preserved. Queued older-format packets are skipped
and marked failed unless already delivered; users must resend their contents.
Old signatures cannot safely be migrated by a relay or store.

## Automated attacks

Flood limits, hidden-text handling, safety numbers, and fuzzing are covered
in [THREAT_MODEL.md](THREAT_MODEL.md).

## What is not done

- No external review. This is the blocking item.
- Public channel messages are signed but readable. Use an encrypted group
  for confidential multi-member traffic.
- The example shows an agreement-key comparison prompt, but it does not
  provide contact verification or a managed recovery flow.
- No post-compromise security; a stolen agreement key opens past traffic.
- Generated suite vectors need independent confirmation. The automated suite
  passes; testing on physical devices is still in progress.
- Nostr metadata protection is limited to per-packet envelope keys and hashed
  route tags. There is no sender sealing, padding, or cover traffic, and
  relays see the recipient route and client IP addresses.
