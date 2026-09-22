import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ble_mesh/ble_mesh.dart';
import 'package:ble_mesh/file_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_chat_transport.dart';

/// Phase 2: a message written while nothing is reachable has to outlive the
/// process and go out once a route appears, exactly once.
void main() {
  late Directory directory;
  late String path;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('ble_mesh_durable');
    path = '${directory.path}/chat.log';
  });

  tearDown(() => directory.deleteSync(recursive: true));

  BleMeshChat createChat() => BleMeshChat(
    store: FileMessageStore.at(path),
    maximumRelayJitter: Duration.zero,
  );

  test('a queued message survives termination and sends when a route appears',
      () async {
    // First run: no peers, so the message can only be queued.
    final firstRun = createChat();
    final offlineTransport = TestChatTransport('a');
    await firstRun.initialize(
      identity: const ChatIdentity(peerId: 'a', displayName: 'A'),
      transports: [offlineTransport],
    );
    final firstStates = <MessageState>[];
    firstRun.messageStates.listen((change) => firstStates.add(change.state));
    await firstRun.sendDirect(peerId: 'b', text: 'survives a restart');
    await pumpEventQueue();
    expect(firstStates, contains(MessageState.queued));

    // Terminate.
    await firstRun.dispose();
    await offlineTransport.dispose();

    // Second run: same store on disk, and this time a route exists.
    final secondRun = createChat();
    final aTransport = TestChatTransport('a');
    final bTransport = TestChatTransport('b');
    final peer = BleMeshChat(maximumRelayJitter: Duration.zero);
    addTearDown(() async {
      await secondRun.dispose();
      await peer.dispose();
      await aTransport.dispose();
      await bTransport.dispose();
    });

    final restored = <ChatMessage>[];
    secondRun.messages.listen(restored.add);
    await secondRun.initialize(
      identity: const ChatIdentity(peerId: 'a', displayName: 'A'),
      transports: [aTransport],
    );
    await peer.initialize(
      identity: const ChatIdentity(peerId: 'b', displayName: 'B'),
      transports: [bTransport],
    );

    // History is on screen before any radio is available.
    expect(restored.map((message) => message.text), ['survives a restart']);
    expect(restored.single.threadId, 'b');

    final delivered = <ChatMessage>[];
    peer.messages.listen(delivered.add);
    final secondStates = <MessageState>[];
    secondRun.messageStates.listen((change) => secondStates.add(change.state));

    aTransport.connect(bTransport);
    await pumpEventQueue(times: 30);

    expect(delivered.map((message) => message.text), ['survives a restart']);
    expect(secondStates, contains(MessageState.sent));
    expect(secondStates, contains(MessageState.delivered));
  });

  test('a delivered message is not sent again on the next launch', () async {
    final firstRun = createChat();
    final aTransport = TestChatTransport('a');
    final bTransport = TestChatTransport('b');
    final peer = BleMeshChat(maximumRelayJitter: Duration.zero);
    aTransport.connect(bTransport);
    await firstRun.initialize(
      identity: const ChatIdentity(peerId: 'a', displayName: 'A'),
      transports: [aTransport],
    );
    await peer.initialize(
      identity: const ChatIdentity(peerId: 'b', displayName: 'B'),
      transports: [bTransport],
    );
    await firstRun.sendDirect(peerId: 'b', text: 'only once');
    await pumpEventQueue(times: 30);
    await firstRun.dispose();

    final received = <ChatMessage>[];
    peer.messages.listen(received.add);

    final secondRun = createChat();
    final reconnected = TestChatTransport('a');
    addTearDown(() async {
      await secondRun.dispose();
      await peer.dispose();
      await aTransport.dispose();
      await bTransport.dispose();
      await reconnected.dispose();
    });
    reconnected.connect(bTransport);
    await secondRun.initialize(
      identity: const ChatIdentity(peerId: 'a', displayName: 'A'),
      transports: [reconnected],
    );
    await pumpEventQueue(times: 30);

    // It was acknowledged before the restart, so the queue is empty and the
    // peer sees nothing new.
    expect(received, isEmpty);
  });

  test('message state is restored, not reset to queued', () async {
    final firstRun = createChat();
    final aTransport = TestChatTransport('a');
    final bTransport = TestChatTransport('b');
    final peer = BleMeshChat(maximumRelayJitter: Duration.zero);
    aTransport.connect(bTransport);
    await firstRun.initialize(
      identity: const ChatIdentity(peerId: 'a', displayName: 'A'),
      transports: [aTransport],
    );
    await peer.initialize(
      identity: const ChatIdentity(peerId: 'b', displayName: 'B'),
      transports: [bTransport],
    );
    await firstRun.sendDirect(peerId: 'b', text: 'done');
    await pumpEventQueue(times: 30);
    await firstRun.dispose();

    final secondRun = createChat();
    final reconnected = TestChatTransport('a');
    addTearDown(() async {
      await secondRun.dispose();
      await peer.dispose();
      await aTransport.dispose();
      await bTransport.dispose();
      await reconnected.dispose();
    });
    final states = <MessageStateChange>[];
    secondRun.messageStates.listen(states.add);
    await secondRun.initialize(
      identity: const ChatIdentity(peerId: 'a', displayName: 'A'),
      transports: [reconnected],
    );
    await pumpEventQueue();

    expect(states, hasLength(1));
    expect(states.single.state, MessageState.delivered);
  });

  test('a duplicate arriving after a restart is still shown once', () async {
    final first = createChat();
    final transport = TestChatTransport('local');
    final neighbor = TestChatTransport('remote');
    transport.connect(neighbor);
    await first.initialize(
      identity: const ChatIdentity(peerId: 'local', displayName: 'Local'),
      transports: [transport],
    );

    final replayed = ChatPacket(
      type: ChatPacketType.message,
      packetId: createPacketId(),
      senderId: 'remote',
      destination: 'c:general',
      ttl: 3,
      createdAt: DateTime.now(),
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
      payload: Uint8List.fromList(utf8.encode('replayed')),
    );

    final before = <ChatMessage>[];
    first.messages.listen(before.add);
    transport.inject(replayed, from: neighbor);
    await pumpEventQueue(times: 10);
    expect(before, hasLength(1));
    await first.dispose();

    final second = createChat();
    final reopened = TestChatTransport('local');
    final other = TestChatTransport('remote');
    reopened.connect(other);
    addTearDown(() async {
      await second.dispose();
      await transport.dispose();
      await neighbor.dispose();
      await reopened.dispose();
      await other.dispose();
    });
    final after = <ChatMessage>[];
    await second.initialize(
      identity: const ChatIdentity(peerId: 'local', displayName: 'Local'),
      transports: [reopened],
    );
    // Only listen once history has replayed, so this counts new arrivals.
    second.messages.listen(after.add);
    reopened.inject(replayed, from: other);
    await pumpEventQueue(times: 10);

    expect(after, isEmpty, reason: 'the replay must still be a duplicate');
  });
}
