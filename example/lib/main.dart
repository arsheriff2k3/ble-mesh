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

/// Conversation id used for the shared broadcast channel.
const _generalChannel = 'general';

class _ChatPageState extends State<ChatPage> {
  late final ChatIdentity _identity;
  late final BleMeshTransport _ble;
  late final BleChatTransport _chatTransport;
  late final BleMeshChat _chat;
  final _text = TextEditingController();
  final _subscriptions = <StreamSubscription<void>>[];
  final _messages = <ChatMessage>[];
  final _log = <String>[];
  final _states = <String, MessageState>{};
  final _unread = <String, int>{};
  List<ChatPeer> _peers = const [];
  List<BleLink> _links = const [];
  BleAdapterState _adapter = BleAdapterState.unknown;
  bool _running = false;

  /// `null` selects [_generalChannel]; otherwise the peer being messaged.
  String? _selectedPeerId;

  String get _thread => _selectedPeerId ?? _generalChannel;

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
        setState(() {
          _messages.add(message);
          final thread = message.threadId;
          if (!message.isLocal && thread != _thread) {
            _unread[thread] = (_unread[thread] ?? 0) + 1;
          }
        });
      }),
      _chat.peers.listen((peers) {
        if (!mounted) return;
        setState(() => _peers = peers);
      }),
      _chat.messageStates.listen((state) {
        if (mounted) {
          setState(() => _states[state.messageId] = state.state);
        }
        _append('${state.messageId.substring(0, 8)}: ${state.state.name}');
      }),
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

  /// Every thread worth offering: the channel, connected peers, and any peer
  /// we have history with even after their link dropped.
  List<String> get _threads {
    final threads = <String>{_generalChannel};
    for (final peer in _peers) {
      threads.add(peer.id);
    }
    for (final message in _messages) {
      threads.add(message.threadId);
    }
    final selected = _selectedPeerId;
    if (selected != null) threads.add(selected);
    return threads.toList();
  }

  List<ChatMessage> get _visibleMessages => _messages
      .where((message) => message.threadId == _thread)
      .toList(growable: false);

  String _labelFor(String thread) {
    if (thread == _generalChannel) return '#$_generalChannel';
    for (final peer in _peers) {
      if (peer.id == thread) return peer.displayName;
    }
    return thread;
  }

  bool _isConnected(String thread) =>
      thread == _generalChannel || _peers.any((peer) => peer.id == thread);

  void _selectThread(String thread) => setState(() {
    _selectedPeerId = thread == _generalChannel ? null : thread;
    _unread.remove(thread);
  });

  Future<void> _send() async {
    final value = _text.text.trim();
    if (value.isEmpty) return;
    _text.clear();
    final peerId = _selectedPeerId;
    try {
      if (peerId == null) {
        await _chat.send(conversationId: _generalChannel, text: value);
      } else {
        await _chat.sendDirect(peerId: peerId, text: value);
      }
    } on Object catch (error) {
      _append('send failed: $error');
    }
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
        SizedBox(
          height: 52,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              for (final thread in _threads)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Center(
                    child: Badge.count(
                      count: _unread[thread] ?? 0,
                      isLabelVisible: (_unread[thread] ?? 0) > 0,
                      child: ChoiceChip(
                        selected: thread == _thread,
                        onSelected: (_) => _selectThread(thread),
                        avatar: thread == _generalChannel
                            ? const Icon(Icons.tag, size: 18)
                            : Icon(
                                _isConnected(thread)
                                    ? Icons.smartphone
                                    : Icons.signal_cellular_off,
                                size: 18,
                              ),
                        label: Text(_labelFor(thread)),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: _visibleMessages.length,
            itemBuilder: (context, index) {
              final message = _visibleMessages[index];
              final state = _states[message.id];
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
                          state == null
                              ? message.senderId
                              : '${message.senderId} · ${state.name}',
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
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    hintText: _selectedPeerId == null
                        ? 'Message #$_generalChannel'
                        : 'Direct message ${_labelFor(_thread)}',
                    helperText: _selectedPeerId == null
                        ? null
                        : 'Direct messages are not encrypted yet (Phase 3)',
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
