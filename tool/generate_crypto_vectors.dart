import 'dart:convert';
import 'dart:typed_data';

import 'package:ble_mesh_chat/src/chat/chat_models.dart';
import 'package:ble_mesh_chat/src/chat/crypto/chat_keys.dart';
import 'package:ble_mesh_chat/src/chat/packet_codec.dart';
import 'package:cryptography/cryptography.dart';

Future<void> main() async {
  final alice = await ChatKeyPair.fromPrivateBytes(
    signingSeed: List<int>.generate(32, (i) => i),
    agreementSeed: List<int>.generate(32, (i) => 32 + i),
  );
  final bob = await ChatKeyPair.fromPrivateBytes(
    signingSeed: List<int>.generate(32, (i) => 64 + i),
    agreementSeed: List<int>.generate(32, (i) => 96 + i),
  );
  final packet = ChatPacket(
    type: ChatPacketType.message,
    packetId: Uint8List.fromList(List<int>.generate(16, (i) => i)),
    senderId: alice.peerId,
    destination: 'p:${bob.peerId}',
    ttl: 5,
    createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true),
    expiresAt: DateTime.fromMillisecondsSinceEpoch(1700003600000, isUtc: true),
    payload: Uint8List.fromList(utf8.encode('test vector')),
  ).withSenderKeys(alice.publicKeys);
  final signingInput = packet.signingInput;
  final signature = await Ed25519().sign(
    signingInput,
    keyPair: alice.signingKeyPair,
  );
  final signed = packet.withSignature(Uint8List.fromList(signature.bytes));
  final codec = const ChatPacketCodec();

  final ephemeral = await X25519().newKeyPairFromSeed(
    List<int>.generate(32, (i) => 128 + i),
  );
  final ephemeralPublic = await ephemeral.extractPublicKey();
  final shared = await X25519().sharedSecretKey(
    keyPair: ephemeral,
    remotePublicKey: SimplePublicKey(
      bob.publicKeys.agreement,
      type: KeyPairType.x25519,
    ),
  );
  final salt = [...ephemeralPublic.bytes, ...bob.publicKeys.agreement];
  final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
    secretKey: shared,
    info: utf8.encode('ble_mesh/message/v1'),
    nonce: salt,
  );
  final nonce = List<int>.generate(24, (i) => 160 + i);
  final directBox = await Xchacha20.poly1305Aead().encrypt(
    packet.payload,
    secretKey: key,
    nonce: nonce,
    aad: packet.associatedData,
  );

  final groupPacket = ChatPacket(
    type: ChatPacketType.groupMessage,
    packetId: Uint8List.fromList(List<int>.generate(16, (i) => i)),
    senderId: alice.peerId,
    destination: 'g:${alice.peerId}/000102030405060708090a0b0c0d0e0f',
    ttl: 5,
    createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true),
    expiresAt: DateTime.fromMillisecondsSinceEpoch(1700003600000, isUtc: true),
    payload: Uint8List.fromList(utf8.encode('test vector')),
  ).withSenderKeys(alice.publicKeys);
  final groupKey = List<int>.generate(32, (i) => 192 + i);
  final groupNonce = List<int>.generate(24, (i) => 48 + i);
  final groupEpoch = ByteData(4)..setUint32(0, 7);
  final groupAad = [
    ...utf8.encode('ble_mesh/group/v1'),
    ...groupPacket.associatedData,
    ...groupEpoch.buffer.asUint8List(),
  ];
  final groupBox = await Xchacha20.poly1305Aead().encrypt(
    groupPacket.payload,
    secretKey: SecretKey(groupKey),
    nonce: groupNonce,
    aad: groupAad,
  );

  final values = <String, String>{
    'alice_signing_public': _hex(alice.publicKeys.signing),
    'alice_agreement_public': _hex(alice.publicKeys.agreement),
    'alice_peer_id': alice.peerId,
    'bob_signing_public': _hex(bob.publicKeys.signing),
    'bob_agreement_public': _hex(bob.publicKeys.agreement),
    'bob_peer_id': bob.peerId,
    'canonical_signing_input': _hex(signingInput),
    'ed25519_signature': _hex(signature.bytes),
    'wire_packet_v3': _hex(codec.encode(signed)),
    'direct_aad': _hex(packet.associatedData),
    'ephemeral_public': _hex(ephemeralPublic.bytes),
    'x25519_shared': _hex(await shared.extractBytes()),
    'hkdf_salt': _hex(salt),
    'hkdf_key': _hex(await key.extractBytes()),
    'direct_nonce': _hex(nonce),
    'direct_ciphertext': _hex(directBox.cipherText),
    'direct_tag': _hex(directBox.mac.bytes),
    'group_destination': groupPacket.destination,
    'group_key': _hex(groupKey),
    'group_epoch': '7',
    'group_nonce': _hex(groupNonce),
    'group_aad': _hex(groupAad),
    'group_ciphertext': _hex(groupBox.cipherText),
    'group_tag': _hex(groupBox.mac.bytes),
  };
  for (final entry in values.entries) {
    // ignore: avoid_print
    print('${entry.key}=${entry.value}');
  }
}

String _hex(List<int> value) =>
    value.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
