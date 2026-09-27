// Performance measurements for doc/PERFORMANCE.md.
//
// Run explicitly; this is not part of the test suite:
//
//   flutter test benchmark/chat_benchmark_test.dart --reporter expanded
//
// `flutter test` runs on the host VM in JIT mode, so absolute numbers are a
// desktop baseline, not phone figures. Radio throughput, battery, and
// thermal behaviour need the device recipes in doc/PERFORMANCE.md.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ble_mesh_chat/ble_mesh_chat.dart';
import 'package:ble_mesh_chat/file_store.dart';
import 'package:ble_mesh_chat/src/chat/nostr/bip340.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/test_chat_transport.dart';

final _results = <String>[];

void _report(String name, String value) {
  final line = '${name.padRight(52)} $value';
  _results.add(line);
  // ignore: avoid_print
  print(line);
}

/// Mean microseconds per call of [body] after a warm-up.
Future<double> _timeAsync(int iterations, Future<void> Function() body) async {
  for (var i = 0; i < (iterations ~/ 10).clamp(1, 50); i++) {
    await body();
  }
  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    await body();
  }
  return watch.elapsedMicroseconds / iterations;
}

double _time(int iterations, void Function() body) {
  for (var i = 0; i < (iterations ~/ 10).clamp(1, 200); i++) {
    body();
  }
  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    body();
  }
  return watch.elapsedMicroseconds / iterations;
}

String _us(double micros) => micros >= 1000
    ? '${(micros / 1000).toStringAsFixed(2)} ms/op'
    : '${micros.toStringAsFixed(1)} µs/op';

int _percentile(List<int> sorted, double p) =>
    sorted[((sorted.length - 1) * p).round()];

void main() {
  tearDownAll(() {
    // ignore: avoid_print
    print('\n=== summary (${Platform.operatingSystem}, '
        '${Platform.numberOfProcessors} cores, Dart ${Platform.version.split(' ').first}) ===');
    for (final line in _results) {
      // ignore: avoid_print
      print(line);
    }
  });

  test('packet codec', () async {
    final keys = await ChatKeyPair.generate();
    final now = DateTime.now();
    final packet = await PacketSecurity(identity: keys).protect(
      ChatPacket(
        type: ChatPacketType.message,
        packetId: createPacketId(),
        senderId: keys.peerId,
        destination: 'c:general',
        ttl: 5,
        createdAt: now,
        expiresAt: now.add(const Duration(hours: 1)),
        payload: Uint8List(1024),
      ),
      encrypt: false,
    );
    const codec = ChatPacketCodec();
    final encoded = codec.encode(packet);
    _report(
      'codec encode, 1 KiB payload (${encoded.length} B wire)',
      _us(_time(20000, () => codec.encode(packet))),
    );
    _report(
      'codec decode, 1 KiB payload',
      _us(_time(20000, () => codec.decode(encoded))),
    );
  });

  test('fragmentation', () {
    const fragmenter = PacketFragmenter();
    final packet = Uint8List(4096);
    final id = createPacketId();
    final frames = fragmenter.fragment(id, packet, 244);
    _report(
      'fragment 4 KiB into 244 B frames (${frames.length} frames)',
      _us(_time(5000, () => fragmenter.fragment(id, packet, 244))),
    );
    var route = 0;
    _report(
      'reassemble 4 KiB from 244 B frames',
      _us(
        _time(5000, () {
          final reassembler = PacketReassembler();
          final key = 'r${route++}';
          for (final frame in frames) {
            reassembler.add(key, frame);
          }
        }),
      ),
    );
  });

  test('cryptography per operation', () async {
    final alice = await ChatKeyPair.generate();
    final bob = await ChatKeyPair.generate();
    final aliceSide = PacketSecurity(identity: alice);
    final bobSide = PacketSecurity(identity: bob);
    final now = DateTime.now();
    ChatPacket direct() => ChatPacket(
      type: ChatPacketType.message,
      packetId: createPacketId(),
      senderId: alice.peerId,
      destination: 'p:${bob.peerId}',
      ttl: 5,
      createdAt: now,
      expiresAt: now.add(const Duration(hours: 1)),
      payload: Uint8List.fromList(utf8.encode('a typical short message')),
    );
    final sealed = await aliceSide.protect(
      direct(),
      encrypt: true,
      recipient: bob.publicKeys,
    );
    _report(
      'seal + sign direct message (X25519, XChaCha20, Ed25519)',
      _us(
        await _timeAsync(
          200,
          () => aliceSide.protect(
            direct(),
            encrypt: true,
            recipient: bob.publicKeys,
          ),
        ),
      ),
    );
    _report(
      'verify + open direct message',
      _us(
        await _timeAsync(
          200,
          () => bobSide.admit(sealed, announcedKeys: alice.publicKeys),
        ),
      ),
    );
    _report(
      'relay verification only (Ed25519)',
      _us(
        await _timeAsync(
          200,
          () => bobSide.verifyForRelay(sealed, senderKeys: alice.publicKeys),
        ),
      ),
    );

    final nostrKeys = NostrKeyPair.generate();
    final message = '1' * 64;
    final aux = '2' * 64;
    final signature = bip340Sign(nostrKeys.privateKeyHex, message, aux);
    _report(
      'BIP-340 sign (vendored, pure Dart)',
      _us(_time(50, () => bip340Sign(nostrKeys.privateKeyHex, message, aux))),
    );
    _report(
      'BIP-340 verify (vendored, pure Dart)',
      _us(_time(50, () => bip340Verify(nostrKeys.publicKeyHex, message, signature))),
    );
    _report(
      'Nostr envelope key generation',
      _us(_time(50, NostrKeyPair.generate)),
    );
    _report(
      'safety number (5200 SHA-256 rounds per side)',
      _us(
        _time(
          20,
          () => ChatPublicKeys.safetyNumber(alice.publicKeys, bob.publicKeys),
        ),
      ),
    );
  });

  for (final hops in [1, 3, 5]) {
    test('end-to-end direct delivery over $hops hop(s), in memory', () async {
      final keys = [
        for (var i = 0; i <= hops; i++) await ChatKeyPair.generate(),
      ];
      final transports = [
        for (var i = 0; i <= hops; i++) TestChatTransport('n$i'),
      ];
      for (var i = 0; i < hops; i++) {
        transports[i].connect(transports[i + 1]);
      }
      final chats = <BleMeshChat>[];
      for (var i = 0; i <= hops; i++) {
        final security = PacketSecurity(identity: keys[i]);
        for (final other in keys) {
          if (other != keys[i]) {
            security.trustStore.observe(other.peerId, other.publicKeys);
          }
        }
        final chat = BleMeshChat(
          security: security,
          maximumRelayJitter: Duration.zero,
          minimumRelaySpacing: Duration.zero,
        );
        await chat.initialize(
          identity: ChatIdentity(peerId: keys[i].peerId, displayName: 'n$i'),
          transports: [transports[i]],
        );
        chats.add(chat);
      }
      addTearDown(() async {
        for (final chat in chats) {
          await chat.dispose();
        }
        for (final transport in transports) {
          await transport.dispose();
        }
      });

      final sender = chats.first;
      final delivered = <String, int>{};
      final started = <String, Stopwatch>{};
      sender.messageStates.listen((change) {
        if (change.state == MessageState.delivered) {
          delivered[change.messageId] =
              started[change.messageId]!.elapsedMicroseconds;
        }
      });
      const messages = 40;
      for (var i = 0; i < messages; i++) {
        final watch = Stopwatch()..start();
        final message = await sender.sendDirect(
          peerId: keys.last.peerId,
          text: 'benchmark $i',
        );
        started[message.id] = watch;
        while (!delivered.containsKey(message.id)) {
          await Future<void>.delayed(Duration.zero);
          if (watch.elapsed > const Duration(seconds: 10)) {
            fail('message $i was not delivered');
          }
        }
      }
      final latencies = delivered.values.toList()..sort();
      _report(
        'send -> signed ACK, $hops hop(s), no jitter (p50 / p95)',
        '${(_percentile(latencies, .5) / 1000).toStringAsFixed(1)} ms / '
            '${(_percentile(latencies, .95) / 1000).toStringAsFixed(1)} ms',
      );
    });
  }

  test('offline queue growth', () async {
    final directory = Directory.systemTemp.createTempSync('ble_mesh_bench');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = FileMessageStore.at('${directory.path}/chat.log');
    await file.open();
    final memory = InMemoryMessageStore();
    await memory.open();
    final keys = await ChatKeyPair.generate();
    final security = PacketSecurity(identity: keys);
    final now = DateTime.now();
    final packets = [
      for (var i = 0; i < 500; i++)
        await security.protect(
          ChatPacket(
            type: ChatPacketType.message,
            packetId: createPacketId(),
            senderId: keys.peerId,
            destination: 'c:general',
            ttl: 5,
            createdAt: now,
            expiresAt: now.add(const Duration(hours: 1)),
            payload: Uint8List.fromList(utf8.encode('queued message $i')),
          ),
          encrypt: false,
        ),
    ];
    var index = 0;
    _report(
      'enqueue, in-memory store',
      _us(await _timeAsync(500, () => memory.enqueue(packets[index++ % 500]))),
    );
    final watch = Stopwatch()..start();
    for (final packet in packets) {
      await file.enqueue(packet);
    }
    _report(
      'enqueue, file store (checksummed append, flushed)',
      _us(watch.elapsedMicroseconds / packets.length),
    );
    final size = File('${directory.path}/chat.log').lengthSync();
    _report(
      'file store growth per queued short message',
      '${(size / packets.length).toStringAsFixed(0)} B',
    );
    final reopen = Stopwatch()..start();
    await file.close();
    final reopened = FileMessageStore.at('${directory.path}/chat.log');
    await reopened.open();
    _report(
      'reopen file store with 500 queued packets',
      '${(reopen.elapsedMicroseconds / 1000).toStringAsFixed(1)} ms',
    );
    await reopened.close();
    await memory.close();
  });
}
