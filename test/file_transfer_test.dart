import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ble_mesh_chat/ble_mesh_chat.dart';
import 'package:ble_mesh_chat/file_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_chat_transport.dart';

class _LossyTransport extends TestChatTransport {
  _LossyTransport(super.id);
  bool dropNext = false;
  void Function(ChatPacket)? onSend;
  @override
  Future<ChatTransportSendResult> send(
    ChatPacket packet, {
    String? routeId,
    String? excludeRouteId,
  }) async {
    onSend?.call(packet);
    if (dropNext && packet.type == ChatPacketType.fileTransfer) {
      dropNext = false;
      sentPackets.add(packet);
      return const ChatTransportSendResult(
        attemptedRoutes: 1,
        deliveredRoutes: 1,
      );
    }
    return super.send(packet, routeId: routeId, excludeRouteId: excludeRouteId);
  }
}

class _CountingStore extends InMemoryFileTransferStore {
  int saves = 0;
  @override
  Future<void> save(FileTransfer transfer) async {
    saves++;
    await super.save(transfer);
  }
}

Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('condition timed out');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late ChatKeyPair alice;
  late ChatKeyPair bob;
  late PacketSecurity aSecurity;
  late PacketSecurity bSecurity;
  late _LossyTransport aRadio;
  late _LossyTransport bRadio;
  late BleFileTransfer a;
  late BleFileTransfer b;
  late FileTransferStore aStore;
  late FileTransferStore bStore;
  final bytes = Uint8List.fromList(List.generate(70001, (i) => i % 251));

  BleFileTransfer service(
    ChatTransport radio,
    PacketSecurity security,
    FileTransferStore store,
  ) => BleFileTransfer(
    transport: radio,
    security: security,
    store: store,
    responseTimeout: const Duration(milliseconds: 100),
    maximumRetries: 2,
  );

  setUp(() async {
    alice = await ChatKeyPair.generate();
    bob = await ChatKeyPair.generate();
    aSecurity = PacketSecurity(
      identity: alice,
      trustStore: TrustStore(pinned: {bob.peerId: bob.publicKeys}),
    );
    bSecurity = PacketSecurity(
      identity: bob,
      trustStore: TrustStore(pinned: {alice.peerId: alice.publicKeys}),
    );
    aRadio = _LossyTransport(alice.peerId);
    bRadio = _LossyTransport(bob.peerId);
    aRadio.connect(bRadio);
    aStore = InMemoryFileTransferStore();
    bStore = InMemoryFileTransferStore();
    a = service(aRadio, aSecurity, aStore);
    b = service(bRadio, bSecurity, bStore);
    await a.start();
    await b.start();
  });
  tearDown(() async {
    await a.dispose();
    await b.dispose();
    await aRadio.dispose();
    await bRadio.dispose();
  });

  Future<FileTransfer> offer([Uint8List? source]) => a.offer(
    peerId: bob.peerId,
    fileName: 'incident.pdf',
    mimeType: 'application/pdf',
    bytes: source ?? bytes,
  );

  test(
    '8 KiB negotiation halves chunk acknowledgements and batches metadata',
    () async {
      await a.dispose();
      await b.dispose();
      final senderStore = _CountingStore();
      final receiverStore = _CountingStore();
      a = BleFileTransfer(
        transport: aRadio,
        security: aSecurity,
        store: senderStore,
        chunkBytes: 8192,
        checkpointBytes: 65536,
      );
      b = BleFileTransfer(
        transport: bRadio,
        security: bSecurity,
        store: receiverStore,
        chunkBytes: 8192,
        checkpointBytes: 65536,
      );
      await a.start();
      await b.start();
      final progress = <int>[];
      final subscription = b.changes.listen((f) {
        if (f.state == FileTransferState.transferring) progress.add(f.offset);
      });
      final file = await offer();
      await _until(() => b.transfers.isNotEmpty);
      await b.accept(file.id);
      await _until(
        () => a.transfers.single.state == FileTransferState.completed,
      );
      expect(await b.readReceived(file.id), bytes);
      final offsets = progress.toSet().where((n) => n > 0).toList()..sort();
      expect(offsets.first, 8192);
      expect(offsets.length, (bytes.length + 8191) ~/ 8192);
      expect(senderStore.saves, lessThan(8));
      expect(receiverStore.saves, lessThan(8));
      await subscription.cancel();
    },
  );

  test('fast sender negotiates down to a 4 KiB receiver', () async {
    await a.dispose();
    a = BleFileTransfer(
      transport: aRadio,
      security: aSecurity,
      store: aStore,
      chunkBytes: 8192,
    );
    await a.start();
    final offsets = <int>[];
    final subscription = b.changes.listen((f) {
      if (f.offset > 0) offsets.add(f.offset);
    });
    final file = await offer();
    await _until(() => b.transfers.isNotEmpty);
    await b.accept(file.id);
    await _until(() => a.transfers.single.state == FileTransferState.completed);
    expect(offsets.first, 4096);
    expect(await b.readReceived(file.id), bytes);
    await subscription.cancel();
  });

  test(
    'batched checkpoint replays uncheckpointed data safely after a crash',
    () async {
      await a.dispose();
      await b.dispose();
      a = BleFileTransfer(
        transport: aRadio,
        security: aSecurity,
        store: aStore,
        chunkBytes: 8192,
        checkpointBytes: 65536,
        responseTimeout: const Duration(milliseconds: 100),
        maximumRetries: 0,
      );
      b = BleFileTransfer(
        transport: bRadio,
        security: bSecurity,
        store: bStore,
        chunkBytes: 8192,
        checkpointBytes: 65536,
      );
      await a.start();
      await b.start();
      final file = await offer();
      await _until(() => b.transfers.isNotEmpty);
      var dropped = false;
      final subscription = b.changes.listen((f) {
        if (f.offset >= 16384 && !dropped) {
          dropped = true;
          aRadio.disconnect(bRadio);
        }
      });
      await b.accept(file.id);
      await _until(() => a.transfers.single.state == FileTransferState.paused);
      final durable = await bStore.get(file.id);
      expect(durable!.offset, 0);
      expect(b.transfers.single.offset, greaterThan(0));
      final crashStore = InMemoryFileTransferStore();
      await crashStore.write(
        file.id,
        0,
        await bStore.read(file.id, 0, file.byteLength),
      );
      await crashStore.save(durable);
      await subscription.cancel();
      await b.dispose();
      b = BleFileTransfer(
        transport: bRadio,
        security: bSecurity,
        store: crashStore,
        chunkBytes: 8192,
        checkpointBytes: 65536,
      );
      await b.start();
      expect(b.transfers.single.offset, 0);
      aRadio.connect(bRadio);
      await a.resume(file.id);
      await _until(
        () => a.transfers.single.state == FileTransferState.completed,
      );
      expect(await b.readReceived(file.id), bytes);
    },
  );

  test(
    'route handover binds source identity and refuses conflicting reuse',
    () async {
      final file = await a.offer(
        peerId: bob.peerId,
        fileName: 'incident.pdf',
        mimeType: 'application/pdf',
        bytes: bytes,
        transferId: 'a' * 32,
        sourceId: 'b' * 32,
      );
      await _until(() => b.transfers.isNotEmpty);
      expect(b.transfers.single.sourceId, 'b' * 32);
      expect(
        FileTransfer.fromJson(b.transfers.single.toJson()).sourceId,
        'b' * 32,
      );
      await expectLater(
        a.offer(
          peerId: bob.peerId,
          fileName: 'incident.pdf',
          mimeType: 'application/pdf',
          bytes: bytes,
          transferId: file.id,
          sourceId: 'c' * 32,
        ),
        throwsFormatException,
      );
      expect(a.transfers.single.sourceId, 'b' * 32);
      await b.accept(file.id);
      await _until(
        () => b.transfers.single.state == FileTransferState.completed,
      );
      expect(await b.readReceived(file.id), bytes);
    },
  );

  test(
    'route handover rejects invalid source ids before reserving storage',
    () async {
      await expectLater(
        a.offer(
          peerId: bob.peerId,
          fileName: 'incident.pdf',
          mimeType: 'application/pdf',
          bytes: bytes,
          sourceId: '../foreign',
        ),
        throwsFormatException,
      );
      expect(a.transfers, isEmpty);
    },
  );

  test(
    'consent, encrypted chunks larger than packet limit, verified receipt and progress',
    () async {
      final progress = <int>[];
      final subscription = b.changes.listen((r) => progress.add(r.offset));
      final file = await offer();
      await _until(() => b.transfers.isNotEmpty);
      expect(b.transfers.single.state, FileTransferState.offered);
      expect(b.transfers.single.offset, 0);
      expect(await bStore.read(file.id, 0, bytes.length), isEmpty);
      expect(b.readReceived(file.id), throwsStateError);
      await b.accept(file.id);
      await _until(
        () => a.transfers.single.state == FileTransferState.completed,
      );
      expect(b.transfers.single.state, FileTransferState.completed);
      expect(await b.readReceived(file.id), bytes);
      expect(
        progress.where((n) => n > 0 && n < bytes.length).length,
        greaterThan(10),
      );
      expect(
        aRadio.sentPackets.every(
          (p) => p.isSealed && p.ttl == 1 && !p.bridgeable,
        ),
        isTrue,
      );
      expect(aRadio.sentPackets.every((p) => p.payload.length < 12288), isTrue);
      await subscription.cancel();
    },
  );

  test(
    'transfers an image at the exact 5 MiB limit with verified receipt',
    () async {
      final image = Uint8List.fromList(
        List.generate(5 * 1024 * 1024, (i) => i % 251),
      );
      final file = await a.offer(
        peerId: bob.peerId,
        fileName: 'large.png',
        mimeType: 'image/png',
        bytes: image,
      );
      await _until(() => b.transfers.isNotEmpty);
      expect(b.transfers.single.byteLength, 5242880);
      await b.accept(file.id);
      await _until(
        () => a.transfers.single.state == FileTransferState.completed,
        timeout: const Duration(seconds: 60),
      );
      expect(await b.readReceived(file.id), image);
    },
  );

  test('all supported image types reject bytes beyond 5 MiB', () async {
    for (final mime in [
      'image/png',
      'image/jpeg',
      'image/heif',
      'image/heic',
    ]) {
      await expectLater(
        a.offer(
          peerId: bob.peerId,
          fileName: 'large.image',
          mimeType: mime,
          bytes: Uint8List(5 * 1024 * 1024 + 1),
        ),
        throwsFormatException,
      );
    }
    expect(a.transfers, isEmpty);
  });

  test(
    'HEIF and HEIC transfer original encrypted bytes with verified receipts',
    () async {
      for (final format in [
        ('image/heif', 'photo.heif'),
        ('image/heic', 'photo.heic'),
      ]) {
        final file = await a.offer(
          peerId: bob.peerId,
          fileName: format.$2,
          mimeType: format.$1,
          bytes: bytes,
        );
        await _until(() => b.transfers.isNotEmpty);
        expect(b.transfers.single.mimeType, format.$1);
        await b.accept(file.id);
        await _until(
          () => a.transfers.single.state == FileTransferState.completed,
        );
        expect(await b.readReceived(file.id), bytes);
        await a.delete(file.id);
        await b.delete(file.id);
      }
    },
  );

  test('HEIF and HEIC accept offers at exactly 5 MiB', () async {
    for (final mime in ['image/heif', 'image/heic']) {
      final file = await a.offer(
        peerId: bob.peerId,
        fileName: 'limit.heif',
        mimeType: mime,
        bytes: Uint8List(5 * 1024 * 1024),
      );
      await _until(() => b.transfers.isNotEmpty);
      expect(b.transfers.single.byteLength, 5242880);
      await b.reject(file.id);
      await _until(
        () => a.transfers.single.state == FileTransferState.rejected,
      );
      await a.delete(file.id);
      await b.delete(file.id);
    }
  });

  test(
    'receiver applies its configured image limit to HEIF and HEIC',
    () async {
      await b.dispose();
      b = BleFileTransfer(
        transport: bRadio,
        security: bSecurity,
        store: bStore,
        maximumImageBytes: 10,
      );
      await b.start();
      final errors = <Object>[];
      final subscription = b.errors.listen(errors.add);
      for (final mime in ['image/heif', 'image/heic']) {
        errors.clear();
        final file = await a.offer(
          peerId: bob.peerId,
          fileName: 'too-large.heif',
          mimeType: mime,
          bytes: Uint8List(11),
        );
        await _until(() => errors.isNotEmpty);
        expect(errors.single, isA<FormatException>());
        expect(b.transfers, isEmpty);
        await a.cancel(file.id);
        await a.delete(file.id);
      }
      await subscription.cancel();
    },
  );

  test('receiver rejects an image offer over its own 5 MiB limit', () async {
    await a.dispose();
    a = BleFileTransfer(
      transport: aRadio,
      security: aSecurity,
      store: aStore,
      maximumImageBytes: 6 * 1024 * 1024,
    );
    await a.start();
    final errors = <Object>[];
    final subscription = b.errors.listen(errors.add);
    await a.offer(
      peerId: bob.peerId,
      fileName: 'too-large.jpg',
      mimeType: 'image/jpeg',
      bytes: Uint8List(5 * 1024 * 1024 + 1),
    );
    await _until(() => errors.isNotEmpty);
    expect(errors.single, isA<FormatException>());
    expect(b.transfers, isEmpty);
    await subscription.cancel();
  });

  test(
    'MP4, MOV and WebM transfer encrypted bytes with verified receipts',
    () async {
      for (final mime in ['video/mp4', 'video/quicktime', 'video/webm']) {
        final file = await a.offer(
          peerId: bob.peerId,
          fileName: 'clip.video',
          mimeType: mime,
          bytes: bytes,
        );
        await _until(() => b.transfers.isNotEmpty);
        await b.accept(file.id);
        await _until(
          () => a.transfers.single.state == FileTransferState.completed,
        );
        expect(await b.readReceived(file.id), bytes);
        await a.delete(file.id);
        await b.delete(file.id);
      }
    },
  );

  test(
    'video supports exactly 5 MiB and rejects larger files for all formats',
    () async {
      final video = Uint8List(5 * 1024 * 1024);
      for (final mime in ['video/mp4', 'video/quicktime', 'video/webm']) {
        final file = await a.offer(
          peerId: bob.peerId,
          fileName: 'limit.video',
          mimeType: mime,
          bytes: video,
        );
        await _until(() => b.transfers.isNotEmpty);
        expect(b.transfers.single.byteLength, 5242880);
        await b.reject(file.id);
        await _until(
          () => a.transfers.single.state == FileTransferState.rejected,
        );
        await a.delete(file.id);
        await b.delete(file.id);
        await expectLater(
          a.offer(
            peerId: bob.peerId,
            fileName: 'large.video',
            mimeType: mime,
            bytes: Uint8List(5 * 1024 * 1024 + 1),
          ),
          throwsFormatException,
        );
      }
    },
  );

  test('receiver enforces its own video limit on encrypted offers', () async {
    await b.dispose();
    b = BleFileTransfer(
      transport: bRadio,
      security: bSecurity,
      store: bStore,
      maximumVideoBytes: 10,
    );
    await b.start();
    final errors = <Object>[];
    final subscription = b.errors.listen(errors.add);
    await a.offer(
      peerId: bob.peerId,
      fileName: 'clip.mp4',
      mimeType: 'video/mp4',
      bytes: Uint8List(11),
    );
    await _until(() => errors.isNotEmpty);
    expect(errors.single, isA<FormatException>());
    expect(b.transfers, isEmpty);
    await subscription.cancel();
  });

  test('lost chunk acknowledgement retries without writing twice', () async {
    final file = await offer();
    await _until(() => b.transfers.isNotEmpty);
    var armed = false;
    final subscription = b.changes.listen((r) {
      if (r.offset > 0 && !armed) {
        armed = true;
        bRadio.dropNext = true;
      }
    });
    await b.accept(file.id);
    await _until(() => a.transfers.single.state == FileTransferState.completed);
    expect(armed, isTrue);
    expect(await b.readReceived(file.id), bytes);
    expect(aRadio.sentPackets.length, greaterThan(20));
    await subscription.cancel();
  });

  test('reject and cancellation are terminal and stop data', () async {
    final file = await offer();
    await _until(() => b.transfers.isNotEmpty);
    await b.reject(file.id);
    await _until(() => a.transfers.single.state == FileTransferState.rejected);
    expect(await bStore.read(file.id, 0, 100), isEmpty);
    await a.delete(file.id);
    await b.delete(file.id);
    final next = await offer();
    await _until(() => b.transfers.isNotEmpty);
    await a.cancel(next.id);
    await _until(() => b.transfers.single.state == FileTransferState.cancelled);
    expect(b.accept(next.id), throwsStateError);
  });

  test('checksum corruption never exposes received bytes', () async {
    final file = await offer();
    await _until(() => b.transfers.isNotEmpty);
    await aStore.write(file.id, 0, Uint8List.fromList([99]));
    await b.accept(file.id);
    await _until(() => b.transfers.single.state == FileTransferState.failed);
    expect(b.transfers.single.error, 'checksum mismatch');
    expect(b.readReceived(file.id), throwsStateError);
    await _until(() => a.transfers.single.state == FileTransferState.rejected);
  });

  test('offline offer remains resumable and preserves consent', () async {
    aRadio.disconnect(bRadio);
    final file = await offer();
    expect(file.state, FileTransferState.paused);
    aRadio.connect(bRadio);
    await a.resume(file.id);
    await _until(() => b.transfers.isNotEmpty);
    expect(b.transfers.single.state, FileTransferState.offered);
    await b.accept(file.id);
    await _until(() => a.transfers.single.state == FileTransferState.completed);
  });

  test(
    'durable stores resume from flushed offset after both services restart',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'ble-file-resume',
      );
      addTearDown(() => directory.delete(recursive: true));
      await a.dispose();
      await b.dispose();
      aStore = FileSystemFileTransferStore(
        directory: Directory('${directory.path}/a'),
      );
      bStore = FileSystemFileTransferStore(
        directory: Directory('${directory.path}/b'),
      );
      a = service(aRadio, aSecurity, aStore);
      b = service(bRadio, bSecurity, bStore);
      await a.start();
      await b.start();
      final file = await offer();
      await _until(() => b.transfers.isNotEmpty);
      var disconnected = false;
      final subscription = b.changes.listen((r) {
        if (r.offset >= 4096 && !disconnected) {
          disconnected = true;
          aRadio.disconnect(bRadio);
        }
      });
      await b.accept(file.id);
      await _until(() => a.transfers.single.state == FileTransferState.paused);
      final checkpoint = b.transfers.single.offset;
      expect(checkpoint, greaterThan(0));
      expect(checkpoint, lessThan(bytes.length));
      await subscription.cancel();
      await a.dispose();
      await b.dispose();
      a = service(
        aRadio,
        aSecurity,
        FileSystemFileTransferStore(
          directory: Directory('${directory.path}/a'),
        ),
      );
      b = service(
        bRadio,
        bSecurity,
        FileSystemFileTransferStore(
          directory: Directory('${directory.path}/b'),
        ),
      );
      await a.start();
      await b.start();
      expect(b.transfers.single.offset, checkpoint);
      expect(b.transfers.single.state, FileTransferState.paused);
      aRadio.connect(bRadio);
      await a.resume(file.id);
      await _until(
        () => a.transfers.single.state == FileTransferState.completed,
      );
      expect(await b.readReceived(file.id), bytes);
    },
  );

  test(
    'lost completion receipt is replayed after resume without duplicate bytes',
    () async {
      final file = await offer(Uint8List.fromList([1, 2, 3]));
      await _until(() => b.transfers.isNotEmpty);
      final subscription = b.changes.listen((r) {
        if (r.state == FileTransferState.completed) aRadio.disconnect(bRadio);
      });
      await b.accept(file.id);
      await _until(() => a.transfers.single.state == FileTransferState.paused);
      expect(b.transfers.single.state, FileTransferState.completed);
      await subscription.cancel();
      aRadio.connect(bRadio);
      await a.resume(file.id);
      await _until(
        () => a.transfers.single.state == FileTransferState.completed,
      );
      expect(await b.readReceived(file.id), [1, 2, 3]);
    },
  );

  test(
    'rejects unsafe names, unsupported types, oversize and unknown peer',
    () async {
      expect(
        a.offer(
          peerId: bob.peerId,
          fileName: '../a.pdf',
          mimeType: 'application/pdf',
          bytes: bytes,
        ),
        throwsFormatException,
      );
      expect(
        a.offer(
          peerId: bob.peerId,
          fileName: 'a.exe',
          mimeType: 'application/octet-stream',
          bytes: bytes,
        ),
        throwsFormatException,
      );
      expect(
        a.offer(
          peerId: bob.peerId,
          fileName: 'a.pdf',
          mimeType: 'application/pdf',
          bytes: Uint8List(2 * 1024 * 1024 + 1),
        ),
        throwsFormatException,
      );
      expect(
        a.offer(
          peerId: 'stranger',
          fileName: 'a.pdf',
          mimeType: 'application/pdf',
          bytes: bytes,
        ),
        throwsArgumentError,
      );
      await pumpEventQueue();
      expect(a.transfers, isEmpty);
    },
  );

  test('plaintext and unknown signed offers are ignored', () async {
    final stranger = await ChatKeyPair.generate();
    final now = DateTime.now();
    final plain = ChatPacket(
      type: ChatPacketType.fileTransfer,
      packetId: createPacketId(),
      senderId: alice.peerId,
      destination: 'p:${bob.peerId}',
      ttl: 1,
      createdAt: now,
      expiresAt: now.add(const Duration(minutes: 1)),
      payload: Uint8List.fromList(utf8.encode('{}')),
    );
    bRadio.inject(plain, from: aRadio);
    final unknown = await PacketSecurity(identity: stranger).protect(
      ChatPacket(
        type: ChatPacketType.fileTransfer,
        packetId: createPacketId(),
        senderId: stranger.peerId,
        destination: 'p:${bob.peerId}',
        ttl: 1,
        createdAt: now,
        expiresAt: plain.expiresAt,
        payload: plain.payload,
      ),
      encrypt: true,
      recipient: bob.publicKeys,
    );
    bRadio.inject(unknown, from: aRadio);
    await pumpEventQueue(times: 20);
    expect(b.transfers, isEmpty);
    expect(bSecurity.trustStore.keysFor(stranger.peerId), isNull);
  });

  test('file packets do not enter chat history or errors', () async {
    final chat = BleMeshChat(security: bSecurity);
    await chat.initialize(
      identity: ChatIdentity(peerId: bob.peerId, displayName: 'B'),
      transports: [bRadio],
    );
    final messages = <ChatMessage>[];
    final errors = <Object>[];
    chat.messages.listen(messages.add);
    chat.errors.listen(errors.add);
    final file = await offer();
    await _until(() => b.transfers.isNotEmpty);
    await b.accept(file.id);
    await _until(() => a.transfers.single.state == FileTransferState.completed);
    expect(messages, isEmpty);
    expect(errors, isEmpty);
    await chat.dispose();
  });

  test('storage quota bounds offered files before allocating bytes', () async {
    final limited = BleFileTransfer(
      transport: aRadio,
      security: aSecurity,
      store: InMemoryFileTransferStore(),
      maximumFileBytes: 10,
      maximumImageBytes: 10,
      maximumVideoBytes: 10,
      maximumStoredBytes: 10,
      maximumTransfers: 1,
    );
    await limited.start();
    await limited.offer(
      peerId: bob.peerId,
      fileName: 'a.pdf',
      mimeType: 'application/pdf',
      bytes: Uint8List(8),
    );
    expect(
      limited.offer(
        peerId: bob.peerId,
        fileName: 'b.pdf',
        mimeType: 'application/pdf',
        bytes: Uint8List(8),
      ),
      throwsStateError,
    );
    await limited.dispose();
  });

  test(
    'channel namespaces isolate private and general offers with independent recipient consent',
    () async {
      final charlie = await ChatKeyPair.generate();
      final cRadio = _LossyTransport(charlie.peerId);
      aRadio.connect(cRadio);
      aSecurity.trustStore.observe(charlie.peerId, charlie.publicKeys);
      final cSecurity = PacketSecurity(
        identity: charlie,
        trustStore: TrustStore(pinned: {alice.peerId: alice.publicKeys}),
      );
      BleFileTransfer general(ChatTransport radio, PacketSecurity security) =>
          BleFileTransfer(
            namespace: 'test-general',
            transport: radio,
            security: security,
            store: InMemoryFileTransferStore(),
            responseTimeout: const Duration(milliseconds: 100),
          );
      final ag = general(aRadio, aSecurity);
      final bg = general(bRadio, bSecurity);
      final cg = general(cRadio, cSecurity);
      await ag.start();
      await bg.start();
      await cg.start();
      addTearDown(() async {
        await ag.dispose();
        await bg.dispose();
        await cg.dispose();
        await cRadio.dispose();
      });
      final toBob = await ag.offer(
        peerId: bob.peerId,
        fileName: 'general.pdf',
        mimeType: 'application/pdf',
        bytes: bytes,
      );
      final toCharlie = await ag.offer(
        peerId: charlie.peerId,
        fileName: 'general.pdf',
        mimeType: 'application/pdf',
        bytes: bytes,
      );
      await _until(() => bg.transfers.length == 1 && cg.transfers.length == 1);
      expect(b.transfers, isEmpty);
      expect(bg.transfers.single.offset, 0);
      expect(cg.transfers.single.offset, 0);
      await bg.accept(toBob.id);
      await cg.reject(toCharlie.id);
      await _until(
        () =>
            ag.transfers.firstWhere((f) => f.id == toBob.id).state ==
                FileTransferState.completed &&
            ag.transfers.firstWhere((f) => f.id == toCharlie.id).state ==
                FileTransferState.rejected,
      );
      expect(await bg.readReceived(toBob.id), bytes);
      expect(cg.transfers.single.offset, 0);
      final private = await offer();
      await _until(() => b.transfers.length == 1);
      expect(bg.transfers, hasLength(1));
      await b.accept(private.id);
      await _until(
        () => a.transfers.single.state == FileTransferState.completed,
      );
      expect(ag.transfers, hasLength(2));
      expect(
        () => BleFileTransfer(
          namespace: '',
          transport: aRadio,
          security: aSecurity,
          store: InMemoryFileTransferStore(),
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'filesystem writes support absolute overwrite and reject path traversal',
    () async {
      final dir = await Directory.systemTemp.createTemp('ble-file-store');
      addTearDown(() => dir.delete(recursive: true));
      final store = FileSystemFileTransferStore(directory: dir);
      final id = 'a' * 32;
      await store.write(id, 0, Uint8List.fromList([1, 2, 3]));
      await store.write(id, 1, Uint8List.fromList([9]));
      expect(await store.read(id, 0, 20), [1, 9, 3]);
      expect(store.write('../escape', 0, Uint8List(1)), throwsArgumentError);
    },
  );
}
