# Direct offline file sharing: plan and API

## Plugin-first delivery

Implemented independently of ReliefMesh UI/backend:

1. Append a file packet type without changing existing wire indices.
2. Add encrypted offers, explicit acceptance, chunk acknowledgements, retries,
   cancellation, rejection, progress and verified completion receipts.
3. Persist source/destination bytes and receiver checkpoints for restart resume.
4. Enforce file, storage, queue and offer limits; reject unknown peers.
5. Add failure-oriented tests and an Android example harness.

Next delivery: host file picker/camera, image compression, attachment cards,
consent UI, lifecycle-driven resume and safe document preview/export.
Physical Android-to-Android validation requires two phones. iOS/macOS behavior
needs separate device testing. Multi-hop files, cloud synchronization and
unattended/background delivery are outside this first implementation.

## Integration

Core exports: `BleFileTransfer`, `FileTransfer`, `FileTransferState`,
`FileTransferStore`, `InMemoryFileTransferStore`. Core stays free of `dart:io`.
`FileSystemFileTransferStore` is separately exported from `file_store.dart`.
Use a private directory per account/identity, retaining identity keys, pinned
contacts and transfer storage across restarts.

```dart
import 'dart:io';
import 'package:ble_mesh_chat/ble_mesh_chat.dart';
import 'package:ble_mesh_chat/file_store.dart';

// Share the authenticated transport and security instance used by chat.
final files = BleFileTransfer(
  transport: bleChatTransport,
  security: packetSecurity,
  store: FileSystemFileTransferStore(
    directory: Directory('$supportDirectory/files/$localPeerId'),
  ),
);
await files.start(); // Before starting the shared transport.

files.changes.listen(renderTransfer); // Incoming offers and progress.
files.errors.listen(reportFileError);
// Also render files.transfers to include restored records.

final queued = await files.offer(
  peerId: authenticatedNearbyPeerId,
  fileName: 'incident.pdf',
  mimeType: 'application/pdf',
  bytes: selectedBytes, // Uint8List from the host's file picker.
);

// Receiver, following an explicit user decision:
await files.accept(incomingTransferId);
// Or await files.reject(incomingTransferId);

// Sender, after reconnect/restart and no active worker:
await files.resume(queued.id);

// Receiver, only after completed:
final verifiedBytes = await files.readReceived(incomingTransferId);
// Host owns preview/export, then cleanup when appropriate.
await files.cancel(activeTransferId);
await files.delete(terminalTransferId);
await files.dispose(); // Before disposing chat/shared transport.
```

`changes` is broadcast, not replaying; initialize UI from `transfers` after
`start`. Progress is `offset / byteLength`; statuses are lowercase `state.name`.
Sanitize remote filenames using `UntrustedText.stripHidden` for display.

The service never starts/stops the shared transport. The host pins contacts,
renders offers and decides when foreground reconnection should call `resume`.
Only one outgoing worker runs per peer. Re-offer a waiting transfer after the
preceding transfer finishes. Do not repeatedly resume an active worker.

## Limits and lifecycle

| Constraint | Default |
|---|---|
| Declared types | JPEG, PNG, HEIF, HEIC, MP4, MOV, WebM, PDF, DOC, DOCX |
| JPEG/PNG/HEIF/HEIC size (`maximumImageBytes`) | 1 byte–5 MiB (5,242,880 bytes) |
| MP4/MOV/WebM size (`maximumVideoBytes`) | 1 byte–5 MiB (5,242,880 bytes) |
| PDF/Word size (`maximumFileBytes`) | 1 byte–2 MiB |
| Retained declared bytes, including offers/sources | 16 MiB |
| Retained records | 128 |
| Incoming offers awaiting approval | 8 |
| Raw chunk size | 4096 bytes default; negotiated maximum 8192 bytes |
| Pending inbound frames | 32 |
| Inbound frame budget before cryptography | 128 burst, 64/second total |
| Response timeout | 15 seconds |
| Additional attempts per chunk/finish | 3 |
| Outbound packet lifetime | 2 minutes |

HEIF/HEIC use the registered `image/heif` and `image/heic` declarations
([IANA registration](https://www.iana.org/assignments/media-types/image/heif)).
Original bytes are preserved; transfer support does not add HEIF decoding or
conversion to the example's PNG preview. The host owns format-capable previews.

States: `offered`, `transferring`, `paused`, `completed`, `rejected`, `cancelled`,
`failed`. Transport errors pause outgoing work. Interrupted accepted transfers
restore as `paused`, retaining consent and durable offset. An unaccepted receiver
offer remains `offered`. Checksum failure marks incoming state `failed` and
rejects the sender. Completion is reported only after recipient verification.

Offer/ready controls are not automatically retried: after control loss, re-offer
using `resume`. Chunk and finish requests have bounded retries. Provide Resume
and Cancel actions; retained offers count against quota until deleted.

## Wire protocol v1

`ChatPacketType.fileTransfer` is appended at index 8. Existing wire-v3 text
packets remain unchanged. Both endpoints must support files: old builds reject
the new type. There is no capability negotiation yet.

Frames are JSON inside signed, sealed direct packets: TTL 1, non-bridgeable.
Each has `v: 1`, random 32-character hex `id`, and `op`:

| Operation | Fields / meaning |
|---|---|
| `offer` | `name`, `mime`, `size`, SHA-256 `hash` |
| `ready` | Receiver's durable `offset`, following consent/resume |
| `chunk` | `offset`, base64 `data`, random `request` correlation ID |
| `ack` | Durable `offset`, echoed `request` |
| `finish` | `request`; asks for full-file verification |
| `complete` | Final `offset`, echoed `request`; offer replay may omit request |
| `cancel` / `reject` | Terminal decision |

Stop-and-wait sends one chunk at a time. Receiver flushes bytes before acknowledging. Progress metadata is saved at
checkpointBytes intervals, state changes, completion and clean shutdown. A crash
may replay bytes beyond the last durable metadata checkpoint. Duplicate/out-of-order chunks never
advance storage; receiver returns its current offset. Retries use fresh packet
IDs and the same request ID. Responses must match transfer, pinned peer,
request and the exact expected next offset.

Re-offers must match retained peer, filename, MIME, size and digest. Accepted
receivers return the durable offset. Completed receivers replay their receipt
to recover completion lost before sender confirmation. Terminal transfers
reject late chunks and cannot resume.

BLE sends are restricted to the destination's authenticated physical links.
BLE receives require packet origin to match the authenticated link peer.
Relay transports are rejected; chat ignores file frames before its own admission
budgets or history. Custom local transports must provide equivalent link checks.

## Storage and boundaries

Disk filenames use validated random IDs, never received filenames. Data is
flushed before metadata is atomically replaced. Bytes written before a crash
but not checkpointed are overwritten on resume from the earlier durable offset.
One service owns a store directory; concurrent writers are unsupported.

Files are in private host storage, without encryption at rest. The API copies
outgoing files and reads whole bounded files for verification; it is intended
for small attachments, not streaming media. MIME validation checks declarations,
not actual contents. SHA-256 integrity does not make a file safe. Preview/export
must use host-owned decoders/viewers. Cryptography retains the plugin's existing
experimental status.

## Validation

`flutter test test/file_transfer_test.dart` covers consent, encryption, files
at the exact 5 MiB image limit, supported video formats and their size boundaries,
larger than the packet limit, progress, ACK loss, rejection/cancellation,
corruption, offline offers, restart with real disk checkpoints, lost completion
receipt, quota/name/type limits, unknown/plaintext senders, history isolation
and absolute overwrite/path safety.

The example's paperclip opens **Offline files**, with valid PDF/PNG fixtures,
approval, progress, cancellation, resume and verified-byte inspection. It has
no system picker or external document viewer; those belong to host integration.

On two updated physical phones:

1. Start BLE and choose a nearby authenticated peer in Offline files.
2. Send a PDF: no data before acceptance; then inspect size/hash. Repeat PNG and
   confirm preview decoding. Decline a separate offer.
3. Cancel an accepted transfer. Disable Bluetooth mid-transfer, reconnect and
   Resume offer; verify retained offset and matching final bytes.
4. Kill/relaunch both apps mid-transfer, reconnect and resume from disk checkpoint.
5. Exchange ordinary chat before/after files and confirm no file frames in chat
   history. Repeat with airplane mode/internet disabled.

Automated transports establish protocol/storage behavior, not radio throughput,
OEM background behavior or cross-platform reliability.

## Bluetooth transfer performance

Hosts can choose `chunkBytes: 8192, checkpointBytes: 64 * 1024`. Ready advertises
the receiver limit; sender chooses the smaller limit. Absent capability uses the
legacy 4096-byte limit. Packet budgets, consent, retries and final SHA-256 remain.
Doubling chunks halves application ACK round trips. GATT fragments remain capped
to 512 bytes and negotiated MTU limits.

Android central detects 4 KiB of traffic in one second in either direction,
requests CONNECTION_PRIORITY_HIGH, then returns to balanced after two idle
seconds. Requests are best effort. Disconnect/stop remove activity timers.

Tests verify chunk/metadata counts, 4 KiB interoperability, and safe replay of
uncheckpointed bytes after a crash. These measure protocol overhead, not physical
radio throughput. Phone speed depends on radios, interference and link retries.

File transport now refreshes late native MTU updates when its cache is still at
the minimum frame size. It submits at most four frames ahead while the native
GATT queue still issues one operation at a time. Callback operation names guard
against an unsolicited/duplicate MTU callback completing discovery or a write.
