import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ble_mesh_chat/ble_mesh_chat.dart';
import 'package:ble_mesh_chat/file_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late DateTime now;
  late String path;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('ble_mesh_store');
    path = '${directory.path}/chat.log';
    now = DateTime.utc(2026, 1, 1, 12);
  });

  tearDown(() => directory.deleteSync(recursive: true));

  FileMessageStore createStore({
    int maximumQueuedPackets = 1024,
    int maximumMessages = 4096,
  }) => FileMessageStore(
    file: File(path),
    maximumQueuedPackets: maximumQueuedPackets,
    maximumMessages: maximumMessages,
    clock: () => now,
  );

  ChatPacket packet({String destination = 'c:general', String text = 'hello'}) =>
      ChatPacket(
        type: ChatPacketType.message,
        packetId: createPacketId(),
        senderId: 'a',
        destination: destination,
        ttl: 4,
        createdAt: now,
        expiresAt: now.add(const Duration(hours: 1)),
        payload: Uint8List.fromList(utf8.encode(text)),
      );

  ChatMessage message(String id, {String text = 'hello'}) => ChatMessage(
    id: id,
    conversationId: 'general',
    threadId: 'general',
    isDirect: false,
    senderId: 'a',
    text: text,
    createdAt: now,
    isLocal: true,
  );

  test('queued packets survive a close and reopen', () async {
    final store = createStore();
    await store.open();
    final pending = packet(text: 'still pending');
    await store.enqueue(pending);
    await store.close();

    final reopened = createStore();
    await reopened.open();
    addTearDown(reopened.close);

    final queued = await reopened.queued();
    expect(queued, hasLength(1));
    expect(queued.single.id, pending.id);
    expect(utf8.decode(queued.single.payload), 'still pending');
  });

  test('a removed packet does not come back after reopening', () async {
    final store = createStore();
    await store.open();
    final sent = packet();
    await store.enqueue(sent);
    await store.remove(sent.id);
    await store.close();

    final reopened = createStore();
    await reopened.open();
    addTearDown(reopened.close);
    expect(await reopened.queued(), isEmpty);
  });

  test('messages and their states are restored together', () async {
    final store = createStore();
    await store.open();
    await store.saveMessage(message('aa', text: 'first'));
    await store.saveMessage(message('bb', text: 'second'));
    await store.saveState('aa', MessageState.delivered);
    await store.saveState('bb', MessageState.queued);
    await store.close();

    final reopened = createStore();
    await reopened.open();
    addTearDown(reopened.close);

    expect(
      (await reopened.messages()).map((item) => item.text),
      ['first', 'second'],
    );
    expect(await reopened.states(), {
      'aa': MessageState.delivered,
      'bb': MessageState.queued,
    });
  });

  test('the newest state for a message wins after a reopen', () async {
    final store = createStore();
    await store.open();
    await store.saveMessage(message('aa'));
    await store.saveState('aa', MessageState.queued);
    await store.saveState('aa', MessageState.sent);
    await store.saveState('aa', MessageState.delivered);
    await store.close();

    final reopened = createStore();
    await reopened.open();
    addTearDown(reopened.close);
    expect(await reopened.states(), {'aa': MessageState.delivered});
  });

  test('expired packets are not returned and do not survive a reopen',
      () async {
    final store = createStore();
    await store.open();
    await store.enqueue(packet(text: 'expires'));
    await store.close();

    now = now.add(const Duration(hours: 2));
    final reopened = createStore();
    await reopened.open();
    addTearDown(reopened.close);
    expect(await reopened.queued(), isEmpty);
  });

  test('the queue rejects rather than silently dropping at quota', () async {
    final store = createStore(maximumQueuedPackets: 2);
    await store.open();
    addTearDown(store.close);

    final first = packet(text: 'one');
    await store.enqueue(first);
    await store.enqueue(packet(text: 'two'));

    await expectLater(
      store.enqueue(packet(text: 'three')),
      throwsA(isA<MessageStoreFullException>()),
    );
    // The existing entries are untouched, which is the point of rejecting.
    expect(await store.queued(), hasLength(2));
    expect((await store.queued()).first.id, first.id);
  });

  test('re-enqueueing a packet already queued does not consume quota',
      () async {
    final store = createStore(maximumQueuedPackets: 1);
    await store.open();
    addTearDown(store.close);
    final retried = packet();
    await store.enqueue(retried);
    await store.enqueue(retried);
    expect(await store.queued(), hasLength(1));
  });

  test('a torn final record is dropped and earlier records survive', () async {
    final store = createStore();
    await store.open();
    final survivor = packet(text: 'durable');
    await store.enqueue(survivor);
    await store.saveMessage(message('aa', text: 'durable message'));
    await store.close();

    // Simulate a process killed mid-append.
    final file = File(path);
    final intact = file.readAsBytesSync();
    file.writeAsBytesSync([...intact, 0x01, 0x00, 0x00, 0x10, 0x00, 0x99]);

    final reopened = createStore();
    await reopened.open();
    addTearDown(reopened.close);
    expect((await reopened.queued()).single.id, survivor.id);
    expect((await reopened.messages()).single.text, 'durable message');
  });

  test('a record failing its checksum is treated as a tear', () async {
    final store = createStore();
    await store.open();
    await store.saveMessage(message('aa', text: 'good'));
    await store.close();

    final file = File(path);
    final bytes = file.readAsBytesSync();
    // Corrupt a byte inside the payload, leaving the length prefix valid.
    bytes[bytes.length - 8] ^= 0xff;
    file.writeAsBytesSync(bytes);

    final reopened = createStore();
    await reopened.open();
    addTearDown(reopened.close);
    expect(await reopened.messages(), isEmpty);
  });

  test('writing continues correctly after a torn tail is trimmed', () async {
    final store = createStore();
    await store.open();
    await store.saveMessage(message('aa', text: 'before'));
    await store.close();

    final file = File(path);
    file.writeAsBytesSync([...file.readAsBytesSync(), 0x03, 0xff, 0xff]);

    final reopened = createStore();
    await reopened.open();
    await reopened.saveMessage(message('bb', text: 'after'));
    await reopened.close();

    final finalRead = createStore();
    await finalRead.open();
    addTearDown(finalRead.close);
    expect(
      (await finalRead.messages()).map((item) => item.text),
      ['before', 'after'],
    );
  });

  test('a store written by a newer format version is refused', () async {
    final store = createStore();
    await store.open();
    await store.saveMessage(message('aa'));
    await store.close();

    // Bump the version field in the header past what this build supports.
    final file = File(path);
    final bytes = file.readAsBytesSync();
    ByteData.sublistView(bytes).setUint16(8, 99);
    file.writeAsBytesSync(bytes);

    final reopened = createStore();
    await expectLater(
      reopened.open(),
      throwsA(isA<MessageStoreVersionException>()),
    );
  });

  test('seen packet ids survive a restart so replays stay duplicates',
      () async {
    final store = createStore();
    await store.open();
    await store.rememberSeen('abc', now.add(const Duration(hours: 1)));
    await store.close();

    final reopened = createStore();
    await reopened.open();
    addTearDown(reopened.close);
    expect((await reopened.seen()).keys, contains('abc'));
  });

  test('expired seen ids are forgotten', () async {
    final store = createStore();
    await store.open();
    await store.rememberSeen('abc', now.add(const Duration(minutes: 5)));
    await store.close();

    now = now.add(const Duration(hours: 1));
    final reopened = createStore();
    await reopened.open();
    addTearDown(reopened.close);
    expect(await reopened.seen(), isEmpty);
  });

  test('history is capped and the log does not grow without bound', () async {
    final store = createStore(maximumMessages: 5);
    await store.open();
    addTearDown(store.close);
    for (var index = 0; index < 50; index++) {
      await store.saveMessage(message('id$index', text: 'message $index'));
    }
    final retained = await store.messages();
    expect(retained, hasLength(5));
    expect(retained.last.text, 'message 49');
  });

  test('an unreadable file is reported rather than silently ignored',
      () async {
    File(path).writeAsBytesSync(utf8.encode('this is not a store'));
    final store = createStore();
    await expectLater(store.open(), throwsA(isA<FormatException>()));
  });
}
