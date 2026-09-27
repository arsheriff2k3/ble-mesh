# API stability, compatibility, and migration

`ble_mesh_chat` is pre-1.0. This document states what may change, how changes are
announced, and what each kind of upgrade requires.

## Versioning

- Releases follow semantic versioning with the pre-1.0 convention: a
  breaking change bumps the **minor** version (`0.2.0` → `0.3.0`), and
  additive or fix-only changes bump the **patch** version.
- Every release's `CHANGELOG.md` entry ends with **Upgrade notes** listing
  any action a host must take. That covers Dart API changes, wire
  compatibility, stored data, and platform configuration.
- Where practical, an API is deprecated (`@Deprecated`) for one minor
  release before it is removed.

## Stability tiers

Only symbols exported from `package:ble_mesh_chat/ble_mesh_chat.dart` and
`package:ble_mesh_chat/file_store.dart` are public. Importing anything under
`package:ble_mesh_chat/src/` is unsupported and may break in any release.

| Tier | Symbols | Promise |
| --- | --- | --- |
| **Stable** | `BleMeshTransport`, `BleConfig`, `BleLink`, `BleFrame`, adapter, permission and capability types; `BleMeshChat` messaging (`initialize`, `send`, `sendDirect`, `messages`, `messageStates`, `peers`, `errors`, `dispose`); `ChatMessage`, `MessageState`, `MessageStateChange`, `ChatIdentity`, `ChatPeer`; `ChatTransport`, `ReceivedChatPacket`, `ChatTransportSendResult`; `BleChatTransport`; `MessageStore`, `InMemoryMessageStore`, `FileMessageStore` and their exceptions | Changes only in a minor release, with upgrade notes. |
| **Experimental** | Everything cryptographic (`PacketSecurity`, `ChatKeyPair`, `ChatPublicKeys`, ciphers, `TrustStore`, identity and group stores, groups); `NostrChatTransport`, `NostrEvent`, `NostrKeyPair`, `RelayChatTransport`; bridging (`BridgePolicy`, `BridgeStatus`, consent and gateway methods); `InboundRateLimit` and contact policies; `UntrustedText`; `ChatPacket`, `ChatPacketCodec`, fragmentation | May change in any minor release. The cryptography stays experimental until an external review completes. |

## Compatibility dimensions

### Wire format

Every device in a mesh or conversation has to understand the others'
packets.

- The codec carries a **wire version** byte (currently **3**). A packet with
  a different version is rejected. Changing it is a coordinated upgrade:
  every participating device must move together.
- New optional features use new **flag bits**. Decoders reject unknown
  flags, so a packet using a new feature is dropped by older builds, while
  packets without the feature stay byte-identical and interoperable.
- Signing input and AAD layouts are part of the wire format.
  `doc/TEST_VECTORS.md` pins them.

| Sender build | Receiver build | Result |
| --- | --- | --- |
| Wire v1/v2 | Current | Rejected; queued v1/v2 packets are marked failed on upgrade |
| Current, `bridgeConsent` off | Wire v3 without bridging support | Interoperable |
| Current, `bridgeConsent` on | Wire v3 without bridging support | Bridgeable packets rejected (unknown flag 0x04); other traffic interoperable |

### Stored data

- `FileMessageStore` writes a format version. A build refuses a store newer
  than it understands with `MessageStoreVersionException`, rather than
  corrupting it. Migrations run forward only, when the store is opened.
  Downgrading a device after its store was migrated is unsupported.
- Identity keys live in platform secure storage, with a file fallback. A
  release that changes their format must read the previous one. Losing
  identity keys changes the peer id, and the change is never silent.
- Changing how peer ids are derived invalidates identities and history. It
  is treated as a breaking change with a prominent upgrade note.

### Native channel

The Pigeon contract (`pigeons/ble_api.dart`) is internal. Dart and native
code ship together in one package version, so it can change in any
release.

### Platform configuration

Required manifest keys, entitlements, and `Info.plist` entries are listed in
the README. Adding a required entry is a breaking change and appears in the
upgrade notes.

## Migration checklist for a host upgrade

1. Read the upgrade notes for every version between yours and the target.
2. Upgrade every device in a test mesh together when the notes mention the
   wire format.
3. Keep a copy of the app support directory before first launch on the new
   version. Store migrations are one-way.
4. Run the smoke suite in `doc/INTEGRATION_TESTING.md` on each supported
   platform.
