import 'dart:async';
import 'dart:typed_data';

import 'package:ble_mesh/ble_mesh.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('A and C exchange a direct message through relay B', () async {
    final aTransport = TestChatTransport('a');
    final bTransport = TestChatTransport('b');
    final cTransport = TestChatTransport('c');
    aTransport.connect(bTransport);
    bTransport.connect(cTransport);

    final a = createChat();
    final b = createChat();
    final c = createChat();
    addTearDown(() async {
      await a.dispose();
      await b.dispose();
      await c.dispose();
      await aTransport.dispose();
      await bTransport.dispose();
      await cTransport.dispose();
    });
    await a.initialize(
      identity: const ChatIdentity(peerId: 'a', displayName: 'A'),
      transports: [aTransport],
    );
    await b.initialize(
      identity: const ChatIdentity(peerId: 'b', displayName: 'B'),
      transports: [bTransport],
    );
    await c.initialize(
      identity: const ChatIdentity(peerId: 'c', displayName: 'C'),
      transports: [cTransport],
    );

    final received = <ChatMessage>[];
    final sent = <ChatMessage>[];
    final relayed = <ChatMessage>[];
    final states = <MessageState>[];
    c.messages.listen(received.add);
    a.messages.listen(sent.add);
    b.messages.listen(relayed.add);
    a.messageStates.listen((change) => states.add(change.state));

    await a.sendDirect(peerId: 'c', text: 'through B');
    await pumpEventQueue(times: 20);

    expect(received.map((message) => message.text), ['through B']);
    // The relay moves the packet without it becoming a conversation.
    expect(relayed, isEmpty);
    // Both ends must agree on one thread key, so a UI can group the
    // conversation. conversationId cannot do this: it is 'c' on both sides.
    expect(received.single.threadId, 'a');
    expect(sent.single.threadId, 'c');
    expect(received.single.isDirect, isTrue);
    expect(sent.single.isDirect, isTrue);
    expect(
      states,
      containsAllInOrder([MessageState.sending, MessageState.sent]),
    );
    expect(states, contains(MessageState.delivered));
    expect(
      bTransport.sentPackets.where(
        (packet) => packet.type == ChatPacketType.message,
      ),
      hasLength(1),
    );
    expect(
      bTransport.sentPackets
          .singleWhere((packet) => packet.type == ChatPacketType.message)
          .ttl,
      4,
    );
  });

  test('duplicate packets are displayed and forwarded only once', () async {
    final transport = TestChatTransport('local');
    final neighbor = TestChatTransport('remote');
    transport.connect(neighbor);
    final chat = createChat();
    addTearDown(() async {
      await chat.dispose();
      await transport.dispose();
      await neighbor.dispose();
    });
    await chat.initialize(
      identity: const ChatIdentity(peerId: 'local', displayName: 'Local'),
      transports: [transport],
    );
    final received = <ChatMessage>[];
    chat.messages.listen(received.add);
    final now = DateTime.now();
    final packet = ChatPacket(
      type: ChatPacketType.message,
      packetId: createPacketId(),
      senderId: 'remote',
      destination: 'c:general',
      ttl: 3,
      createdAt: now,
      expiresAt: now.add(const Duration(minutes: 1)),
      payload: Uint8List.fromList('hello'.codeUnits),
    );

    transport.inject(packet, from: neighbor);
    transport.inject(packet, from: neighbor);
    await pumpEventQueue(times: 10);

    expect(received, hasLength(1));
  });

  test('messages queue offline and retry when a route appears', () async {
    final aTransport = TestChatTransport('a');
    final bTransport = TestChatTransport('b');
    final a = createChat();
    final b = createChat();
    addTearDown(() async {
      await a.dispose();
      await b.dispose();
      await aTransport.dispose();
      await bTransport.dispose();
    });
    await a.initialize(
      identity: const ChatIdentity(peerId: 'a', displayName: 'A'),
      transports: [aTransport],
    );
    await b.initialize(
      identity: const ChatIdentity(peerId: 'b', displayName: 'B'),
      transports: [bTransport],
    );
    final states = <MessageState>[];
    final received = <ChatMessage>[];
    a.messageStates.listen((change) => states.add(change.state));
    b.messages.listen(received.add);

    await a.sendDirect(peerId: 'b', text: 'queued');
    await pumpEventQueue();
    expect(states, contains(MessageState.queued));

    aTransport.connect(bTransport);
    await pumpEventQueue(times: 20);

    expect(received.map((message) => message.text), ['queued']);
    expect(states, contains(MessageState.sent));
    expect(states, contains(MessageState.delivered));
  });
}

BleMeshChat createChat() => BleMeshChat(maximumRelayJitter: Duration.zero);

class TestChatTransport implements ChatTransport {
  TestChatTransport(this.nodeId);

  final String nodeId;
  final _incoming = StreamController<ReceivedChatPacket>.broadcast();
  final _availability = StreamController<bool>.broadcast();
  final _peers = StreamController<List<ChatPeer>>.broadcast();
  final Map<String, TestChatTransport> _neighbors = {};
  final List<ChatPacket> sentPackets = [];

  @override
  String get id => 'test';
  @override
  bool get available => _neighbors.isNotEmpty;
  @override
  Stream<bool> get availabilityChanges => _availability.stream;
  @override
  Stream<ReceivedChatPacket> get incoming => _incoming.stream;
  @override
  Stream<List<ChatPeer>> get peers => _peers.stream;

  void connect(TestChatTransport other) {
    _neighbors[other.nodeId] = other;
    other._neighbors[nodeId] = this;
    _availability.add(true);
    other._availability.add(true);
  }

  void inject(ChatPacket packet, {required TestChatTransport from}) {
    _incoming.add(
      ReceivedChatPacket(packet: packet, transportId: id, routeId: from.nodeId),
    );
  }

  @override
  Future<ChatTransportSendResult> send(
    ChatPacket packet, {
    String? routeId,
    String? excludeRouteId,
  }) async {
    sentPackets.add(packet);
    final targets = routeId == null
        ? _neighbors.entries.where((entry) => entry.key != excludeRouteId)
        : _neighbors.entries.where((entry) => entry.key == routeId);
    for (final target in targets) {
      target.value._incoming.add(
        ReceivedChatPacket(packet: packet, transportId: id, routeId: nodeId),
      );
    }
    return ChatTransportSendResult(
      attemptedRoutes: targets.length,
      deliveredRoutes: targets.length,
    );
  }

  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}

  Future<void> dispose() async {
    await _incoming.close();
    await _availability.close();
    await _peers.close();
  }
}
