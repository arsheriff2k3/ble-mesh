import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../chat_models.dart';
import 'chat_keys.dart';
import 'message_cipher.dart';

/// One current group epoch. Old keys are discarded when membership changes.
class ChatGroup {
  /// Creates a group state, copying [key] and freezing [members].
  ///
  /// Throws [FormatException] unless [key] is 32 bytes, [epoch] is in
  /// 1..0xffffffff, [id] starts with `'$ownerId/'`, and [members] holds 1 to
  /// 64 ids including [ownerId].
  ChatGroup({
    required this.id,
    required this.ownerId,
    required this.epoch,
    required Set<String> members,
    required Uint8List key,
  }) : members = Set.unmodifiable(members),
       key = Uint8List.fromList(key) {
    if (key.length != 32 ||
        epoch < 1 ||
        epoch > 0xffffffff ||
        !id.startsWith('$ownerId/') ||
        members.isEmpty ||
        members.length > 64 ||
        !members.contains(ownerId)) {
      throw const FormatException('invalid group state');
    }
  }

  /// Group id, rooted in the owner's peer id as `'<ownerId>/<suffix>'`.
  final String id;

  /// Peer id of the only device allowed to change membership.
  final String ownerId;

  /// Key generation, starting at 1 and increased on every membership change.
  final int epoch;

  /// Peer ids of the current members, including [ownerId]. Unmodifiable.
  final Set<String> members;

  /// The 32-byte XChaCha20-Poly1305 key for [epoch]. Secret.
  final Uint8List key;

  /// Serializes the group, including [key] in base64, for a [GroupStore] or a
  /// sealed key update. Members are sorted, so output is deterministic.
  Map<String, Object> toJson() => {
    'id': id,
    'owner': ownerId,
    'epoch': epoch,
    'members': members.toList()..sort(),
    'key': base64Encode(key),
  };

  /// Parses the output of [toJson].
  ///
  /// Throws [FormatException] for invalid state or malformed base64, and a
  /// [TypeError] when a field is missing or has the wrong type.
  factory ChatGroup.fromJson(Map<String, dynamic> json) => ChatGroup(
    id: json['id'] as String,
    ownerId: json['owner'] as String,
    epoch: json['epoch'] as int,
    members: (json['members'] as List).cast<String>().toSet(),
    key: base64Decode(json['key'] as String),
  );
}

/// Stores group secrets. A production app must use secure persistent storage.
abstract interface class GroupStore {
  /// Returns every saved group, keyed by [ChatGroup.id].
  Future<Map<String, ChatGroup>> load();

  /// Replaces the saved state with [groups], keyed by [ChatGroup.id].
  Future<void> save(Map<String, ChatGroup> groups);
}

/// Volatile [GroupStore] for tests and development. Keys are lost when the
/// process exits.
class InMemoryGroupStore implements GroupStore {
  Map<String, ChatGroup> _groups = {};

  @override
  Future<Map<String, ChatGroup>> load() async => Map.of(_groups);

  @override
  Future<void> save(Map<String, ChatGroup> groups) async {
    _groups = Map.of(groups);
  }
}

/// XChaCha20-Poly1305 using a fresh nonce under the current group epoch.
///
/// The associated data is `"ble_mesh/group/v1"`, then
/// [ChatPacket.associatedData], then the epoch as a big-endian u32, so a
/// ciphertext cannot be moved to another packet or epoch.
class GroupCipher {
  /// Creates a stateless cipher.
  const GroupCipher();

  /// Encrypts [packet]'s payload under [group]'s current key.
  ///
  /// Returns `epoch_u32 || nonce_24 || tag_16 || ciphertext`, to be used as
  /// the payload of a packet with the same associated data as [packet].
  Future<Uint8List> encrypt(ChatPacket packet, ChatGroup group) async {
    final nonce = aead.newNonce();
    final box = await aead.encrypt(
      packet.payload,
      secretKey: SecretKey(group.key),
      nonce: nonce,
      aad: _aad(packet, group.epoch),
    );
    final epoch = ByteData(4)..setUint32(0, group.epoch);
    return (BytesBuilder()
          ..add(epoch.buffer.asUint8List())
          ..add(box.nonce)
          ..add(box.mac.bytes)
          ..add(box.cipherText))
        .toBytes();
  }

  /// Decrypts a payload produced by [encrypt] and returns the plaintext.
  ///
  /// Throws [MessageSecurityException] with reason `'group epoch
  /// unavailable'` when the payload is shorter than 44 bytes or names an
  /// epoch other than [group]'s, and `'authentication failed'` when the tag
  /// does not verify.
  Future<Uint8List> decrypt(ChatPacket packet, ChatGroup group) async {
    final bytes = packet.payload;
    if (bytes.length < 44 ||
        ByteData.sublistView(bytes).getUint32(0) != group.epoch) {
      throw const MessageSecurityException('group epoch unavailable');
    }
    try {
      final clear = await aead.decrypt(
        SecretBox(
          Uint8List.sublistView(bytes, 44),
          nonce: Uint8List.sublistView(bytes, 4, 28),
          mac: Mac(Uint8List.sublistView(bytes, 28, 44)),
        ),
        secretKey: SecretKey(group.key),
        aad: _aad(packet, group.epoch),
      );
      return Uint8List.fromList(clear);
    } on Object {
      throw const MessageSecurityException('authentication failed');
    }
  }

  Uint8List _aad(ChatPacket packet, int epoch) {
    final value = ByteData(4)..setUint32(0, epoch);
    return (BytesBuilder()
          ..add(utf8.encode('ble_mesh/group/v1'))
          ..add(packet.associatedData)
          ..add(value.buffer.asUint8List()))
        .toBytes();
  }
}
