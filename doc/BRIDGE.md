# BLE/Nostr bridging

A **gateway** is a phone with both BLE and internet access that carries other
devices' encrypted direct messages between the mesh and Nostr relays. It lets
an offline phone reach an online contact, and the reverse. Bridging is off
unless two separate people opt in:

| Choice | API | Who makes it | Effect |
| --- | --- | --- | --- |
| Consent | `BleMeshChat(bridgeConsent:)` / `setBridgeConsent` | The sender | Their new direct messages and ACKs carry a signed *bridgeable* flag. While offline, they register with nearby gateways. |
| Gateway | `BleMeshChat(bridgePolicy:)` / `setBridgePolicy` | The gateway's owner | The device carries consenting traffic under its policy. |

A gateway carries a packet only if the origin's signed flag allows it. The
flag is covered by the Ed25519 signature, so no relay or gateway can add it.

## How a message crosses

**Offline → online.** C (no internet) sends to X. The packet floods over BLE
as usual. Gateway A sees a bridgeable direct packet for a recipient that is
not listed on BLE, and publishes it to its relays with one hop removed. X
receives it and replies with an ACK, which A carries back onto BLE if X also
consented.

**Online → offline.** While offline and consenting, C broadcasts a signed
*registration* over BLE every few minutes (TTL 3, valid 10 minutes). A gateway
that allows `nostrToBle` adds C's route key to its relay subscription for as
long as the registration lasts, up to `maximumRoutes` devices. X's bridgeable
packets for C then arrive at A, which sends them onto BLE with one hop removed.

A device that can reach a relay itself never registers, because it needs no
gateway.

## Loops, duplicates, and expiry

- **One id everywhere.** The packet id never changes, so every device drops
  copies through its persistent seen store, whichever transport they arrive
  on. A recipient shows a message once however many gateways and relays
  carried it.
- **Each device bridges a packet at most once**, remembered until the
  packet expires.
- **Crossing costs a hop.** A packet that bounces between BLE and Nostr runs
  out of TTL.
- **Expired packets are never bridged**, and packet lifetimes are capped at
  24 hours. A gateway stores nothing: the origin retries until it is
  acknowledged, so a replacement gateway picks up a backlog without needing
  the first one to return.
- **Nothing that arrived online is flooded back** to relays. A gateway
  publishes only what it bridges.

## Policy

`BridgePolicy` sets the directions (`bleToNostr`, `nostrToBle`), whether
metered or roaming connections may be used (both default **false**),
`maximumPacketsPerMinute` (default 120, both directions combined), and
`maximumRoutes` (default 32). The plugin cannot observe metering or roaming,
so the host reports them with `updateNetworkConditions`. Until it does, a
policy that restricts either stays inactive.

`bridgeStatus` and `bridgeStatusChanges` say whether the device is bridging.
When it isn't, `BridgeInactiveReason` gives the cause: `disabled`,
`requiresSecurity`, `relaysUnavailable`, `networkConditionsUnknown`,
`metered`, or `roaming`.

## Contacts and abuse

A bridgeable packet addressed to you may have come from the internet, so it
gets the strictest contact policy in use. With the default
`contactsOnlyTransports` of `{'nostr'}`, a stranger cannot reach an offline
device through a gateway. Gateways do not need to know the people whose
traffic they carry. They still apply the per-sender and per-route budgets,
plus the bridge budget, so a gateway cannot be used to amplify a flood.

## Metadata consequences

| Who | Learns | Does not learn |
| --- | --- | --- |
| Relays | That a registered device's route key is being served from the gateway's IP address, which roughly locates the offline device. Also sender and recipient peer ids, timing, and sizes of bridged packets. | Message text. |
| The gateway's owner | Peer ids, timing, and sizes of everything it carries, and which nearby devices registered. | Message text. |
| Nearby BLE observers | That an online contact is messaging a nearby device: sender id, timing, size. | Message text. |

Users who consent accept these exposures in exchange for reach. The example
app states them in its bridging dialog.

## Data use

These figures are estimates for text messages. Measure real values with
a device test.

- A sealed direct message is about 300–500 bytes on the wire, and about
  0.7–1.2 KiB as a Nostr event including tags and signatures. The ACK is
  similar.
- A gateway publishes each bridged packet once **per relay**, so with three
  relays one delivered message costs about 4–7 KiB of upload.
- At the default budget (120 packets per minute) with three relays, the
  worst case is roughly 0.3–0.5 MiB of upload per minute, about 20–30 MiB an
  hour. Downloads scale with registered devices' inbound traffic plus
  WebSocket keep-alives. Lower `maximumPacketsPerMinute` or disallow metered
  use to bound this.

## Battery

A gateway keeps WebSocket connections open to each relay, so the cellular or
Wi-Fi radio stays active longer. It also verifies a BIP-340 signature for
every inbound event, in pure Dart, taking tens of milliseconds each on a
phone, and relays BLE traffic as before. Expect noticeably higher drain than
a BLE-only node, especially on cellular data. iOS suspends sockets and BLE
work in the background, so an iPhone gateway should be expected to work only
in the foreground.
