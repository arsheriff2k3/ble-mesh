import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../chat_models.dart';
import 'chat_keys.dart';
import 'message_cipher.dart';

/// One current group epoch. Old keys are discarded when membership changes.
class ChatGroup {
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

  final String id;
  final String ownerId;
  final int epoch;
  final Set<String> members;
  final Uint8List key;

  Map<String, Object> toJson() => {
    'id': id,
    'owner': ownerId,
    'epoch': epoch,
    'members': members.toList()..sort(),
    'key': base64Encode(key),
  };

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
  Future<Map<String, ChatGroup>> load();
  Future<void> save(Map<String, ChatGroup> groups);
}

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
class GroupCipher {
  const GroupCipher();

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
