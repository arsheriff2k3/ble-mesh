import 'dart:typed_data';

import 'package:ble_mesh/ble_mesh.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 1, 2, 3, 4, 5);
  final packet = ChatPacket(
    type: ChatPacketType.message,
    packetId: Uint8List.fromList(List<int>.generate(16, (index) => index)),
    senderId: 'alice',
    destination: 'p:bob',
    ttl: 5,
    createdAt: now,
    expiresAt: now.add(const Duration(minutes: 5)),
    payload: Uint8List.fromList([1, 2, 3, 4]),
  );

  test('packet codec round trips deterministically', () {
    const codec = ChatPacketCodec();
    final encoded = codec.encode(packet);
    final decoded = codec.decode(encoded);

    expect(codec.encode(decoded), encoded);
    expect(decoded.id, packet.id);
    expect(decoded.senderId, 'alice');
    expect(decoded.destination, 'p:bob');
    expect(decoded.ttl, 5);
    expect(decoded.payload, [1, 2, 3, 4]);
  });

  test('packet codec rejects truncated and inconsistent input', () {
    const codec = ChatPacketCodec();
    expect(
      () => codec.decode(Uint8List(10)),
      throwsA(isA<ChatPacketFormatException>()),
    );
    final encoded = codec.encode(packet).removeLastForTest();
    expect(
      () => codec.decode(encoded),
      throwsA(isA<ChatPacketFormatException>()),
    );
  });

  test('packet codec turns hostile timestamps into typed format errors', () {
    const codec = ChatPacketCodec();
    final encoded = codec.encode(packet);
    ByteData.sublistView(encoded).setInt64(6, 0x7fffffffffffffff);

    expect(
      () => codec.decode(encoded),
      throwsA(isA<ChatPacketFormatException>()),
    );
  });

  test('fragmentation reassembles out of order and ignores duplicates', () {
    const codec = ChatPacketCodec();
    const fragmenter = PacketFragmenter();
    final encoded = codec.encode(packet);
    final fragments = fragmenter.fragment(packet.packetId, encoded, 20);
    final reassembler = PacketReassembler();

    Uint8List? result;
    for (final fragment in fragments.reversed) {
      result = reassembler.add('link', fragment) ?? result;
      reassembler.add('link', fragment);
    }

    expect(result, encoded);
  });

  test('reassembly enforces its packet size cap', () {
    const codec = ChatPacketCodec();
    const fragmenter = PacketFragmenter();
    final encoded = codec.encode(packet);
    final fragments = fragmenter.fragment(packet.packetId, encoded, 20);
    final reassembler = PacketReassembler(maxPacketSize: 24);

    expect(() {
      for (final fragment in fragments) {
        reassembler.add('link', fragment);
      }
    }, throwsA(isA<FragmentFormatException>()));
  });
}

extension on Uint8List {
  Uint8List removeLastForTest() => Uint8List.fromList(sublist(0, length - 1));
}
