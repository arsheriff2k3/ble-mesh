import 'dart:async';
import 'dart:math';

import 'package:ble_mesh/ble_mesh.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() => runApp(const MeshChatHarness());

class MeshChatHarness extends StatelessWidget {
  const MeshChatHarness({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'ble_mesh chat harness',
    theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
    home: const ChatPage(),
  );
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  late final ChatIdentity _identity;
  late final BleMeshTransport _ble;
  late final BleChatTransport _chatTransport;
  late final BleMeshChat _chat;
  final _text = TextEditingController();
  final _subscriptions = <StreamSubscription<void>>[];
  final _messages = <ChatMessage>[];
  final _log = <String>[];
  List<ChatPeer> _peers = const [];
  List<BleLink> _links = const [];
  BleAdapterState _adapter = BleAdapterState.unknown;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    final suffix = Random.secure()
        .nextInt(0xffffff)
        .toRadixString(16)
        .padLeft(6, '0');
    _identity = ChatIdentity(
      peerId: 'peer-$suffix',
      displayName: 'Phone $suffix',
    );
    _ble = BleMeshTransport();
    _chatTransport = BleChatTransport(identity: _identity, transport: _ble);
    _chat = BleMeshChat();
    _subscriptions.addAll([
      _chat.messages.listen((message) {
        if (!mounted) return;
        setState(() => _messages.add(message));
      }),
      _chat.peers.listen((peers) {
        if (!mounted) return;
        setState(() => _peers = peers);
      }),
      _chat.messageStates.listen(
        (state) =>
            _append('${state.messageId.substring(0, 8)}: ${state.state.name}'),
      ),
      _chat.errors.listen((error) => _append('chat error: $error')),
      _chatTransport.errors.listen(
        (error) => _append('BLE chat error: $error'),
      ),
      _ble.adapterState.listen((state) {
        if (!mounted) return;
        setState(() => _adapter = state);
      }),
      _ble.linksChanged.listen((links) {
        if (!mounted) return;
        setState(() => _links = links);
      }),
    ]);
    unawaited(_refreshAdapter());
  }

  Future<void> _refreshAdapter() async {
    final adapter = await _ble.currentAdapterState();
    if (mounted) setState(() => _adapter = adapter);
  }

  Future<void> _start() async {
    try {
      final permission = await _ble.requestPermissions();
      if (permission != BlePermissionState.granted &&
          permission != BlePermissionState.notRequired) {
        _append('Bluetooth permission: ${permission.name}');
        return;
      }
      await _chat.initialize(identity: _identity, transports: [_chatTransport]);
      if (mounted) setState(() => _running = true);
      _append('mesh chat started as ${_identity.peerId}');
    } on PlatformException catch (error) {
      _append('start failed: ${error.code} ${error.message ?? ''}');
    } on Object catch (error) {
      _append('start failed: $error');
    }
  }

  Future<void> _send() async {
    final value = _text.text.trim();
    if (value.isEmpty) return;
    _text.clear();
    await _chat.send(conversationId: 'general', text: value);
  }

  void _append(String value) {
    if (!mounted) return;
    setState(() {
      _log.insert(0, value);
      if (_log.length > 100) _log.removeLast();
    });
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _text.dispose();
    unawaited(_disposeTransports());
    super.dispose();
  }

  Future<void> _disposeTransports() async {
    await _chat.dispose();
    await _ble.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('ble_mesh chat harness')),
    body: Column(
      children: [
        Material(
          color: Theme.of(context).colorScheme.surfaceContainer,
          child: ListTile(
            title: Text(_identity.displayName),
            subtitle: Text(
              'adapter=${_adapter.name} · links=${_links.length} · '
              'peers=${_peers.length}',
            ),
            trailing: FilledButton(
              onPressed: _running ? null : _start,
              child: Text(_running ? 'Running' : 'Start'),
            ),
          ),
        ),
        if (_peers.isNotEmpty)
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final peer in _peers)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Chip(label: Text(peer.displayName)),
                  ),
              ],
            ),
          ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: _messages.length,
            itemBuilder: (context, index) {
              final message = _messages[index];
              return Align(
                alignment: message.isLocal
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                child: Card(
                  color: message.isLocal
                      ? Theme.of(context).colorScheme.primaryContainer
                      : null,
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          message.senderId,
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                        Text(message.text),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _text,
                  enabled: _running,
                  onSubmitted: (_) => _send(),
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: 'Message #general',
                  ),
                ),
              ),
              IconButton.filled(
                onPressed: _running ? _send : null,
                icon: const Icon(Icons.send),
              ),
            ],
          ),
        ),
        ExpansionTile(
          title: const Text('Diagnostics'),
          children: [
            SizedBox(
              height: 120,
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final entry in _log)
                    Text(
                      entry,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ],
    ),
  );
}
