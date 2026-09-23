import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ble_mesh/ble_mesh.dart';
import 'package:ble_mesh/file_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

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
  ChatIdentity? _identity;
  IdentityStore? _identityStore;
  PacketSecurity? _security;
  BleMeshTransport? _ble;
  BleChatTransport? _chatTransport;
  BleMeshChat? _chat;
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
  bool _restartRequired = false;
  Object? _startupError;
  final Set<String> _rotationPrompts = {};

  /// `null` selects [_generalChannel]; otherwise the peer being messaged.
  String? _selectedPeerId;

  String get _thread => _selectedPeerId ?? _generalChannel;

  @override
  void initState() {
    super.initState();
    unawaited(
      _bootstrap().catchError((Object error) {
        if (mounted) setState(() => _startupError = error);
      }),
    );
  }

  /// Loads the durable identity and store before wiring anything up.
  ///
  /// The identity has to outlive the process: a fresh peer id on every launch
  /// would make a restart look like a different phone, and every restored
  /// conversation would point at a peer nobody recognises.
  Future<void> _bootstrap() async {
    final directory = await getApplicationSupportDirectory();

    // Private keys go to Android Keystore / iOS Keychain; pinned peer keys are
    // public, so they sit beside the message log.
    final identityStore = PlatformIdentityStore(
      fallback: FileIdentityStore(directory: directory),
    );
    final marker = File('${directory.path}/identity.peer');
    final previousId = await marker.exists()
        ? await marker.readAsString()
        : null;
    final keys = await loadOrCreateIdentity(identityStore);
    if (previousId != null && previousId != keys.peerId) {
      _append(
        'Identity changed: $previousId -> ${keys.peerId}. Old direct messages remain addressed to the old device.',
      );
    }
    await marker.writeAsString(keys.peerId, flush: true);
    final security = PacketSecurity(
      identity: keys,
      trustStore: await identityStore.loadTrust(),
    );

    // The peer id is the fingerprint of the signing key, not a random label,
    // so it cannot be claimed by another device.
    final identity = ChatIdentity(
      peerId: keys.peerId,
      displayName: 'Phone ${keys.peerId.substring(5, 11)}',
    );
    final chat = BleMeshChat(
      security: security,
      groupStore: PlatformGroupStore(
        fallback: FileGroupStore(File('${directory.path}/groups.keys')),
      ),
      store: FileMessageStore.at('${directory.path}/chat.log'),
      // Space out a backlog so a reconnect after a long offline stretch does
      // not hit neighbours with everything at once.
      retrySpacing: const Duration(milliseconds: 120),
    );
    final ble = BleMeshTransport();
    final chatTransport = BleChatTransport(
      identity: identity,
      transport: ble,
      security: security,
    );
    if (!mounted) return;
    setState(() {
      _identity = identity;
      _identityStore = identityStore;
      _security = security;
      _ble = ble;
      _chat = chat;
      _chatTransport = chatTransport;
    });
    _listen(chat, chatTransport, ble);
    _append('identity ${identity.peerId}');
    unawaited(_refreshAdapter());
  }

  void _listen(
    BleMeshChat chat,
    BleChatTransport chatTransport,
    BleMeshTransport ble,
  ) {
    _subscriptions.addAll([
      chat.messages.listen((message) {
        if (!mounted) return;
        setState(() {
          _messages.add(message);
          final thread = message.threadId;
          if (!message.isLocal && thread != _thread) {
            _unread[thread] = (_unread[thread] ?? 0) + 1;
          }
        });
      }),
      chat.groupChanges.listen((_) {
        if (mounted) setState(() {});
      }),
      chat.peers.listen((peers) {
        if (!mounted) return;
        setState(() => _peers = peers);
        for (final peer in peers) {
          if (peer.trust == PeerTrust.firstContact) {
            _append('pinned ${peer.displayName} (${peer.id})');
          }
        }
        // Persist the pin so the same peer is recognised after a restart.
        final security = _security;
        final store = _identityStore;
        if (security != null && store != null) {
          unawaited(
            store.saveTrust(security.trustStore).catchError((Object error) {
              _append('Could not save peer trust: $error');
            }),
          );
        }
      }),
      chat.messageStates.listen((state) {
        if (mounted) {
          setState(() => _states[state.messageId] = state.state);
        }
        _append('${state.messageId.substring(0, 8)}: ${state.state.name}');
      }),
      chat.errors.listen((error) => _append('chat error: $error')),
      chatTransport.errors.listen(_onSecurityError),
      ble.adapterState.listen((state) {
        if (!mounted) return;
        setState(() => _adapter = state);
      }),
      ble.linksChanged.listen((links) {
        if (!mounted) return;
        setState(() => _links = links);
      }),
    ]);
  }

  Future<void> _refreshAdapter() async {
    final adapter = await _ble?.currentAdapterState();
    if (mounted && adapter != null) setState(() => _adapter = adapter);
  }

  Future<void> _start() async {
    if (_restartRequired) return;
    final ble = _ble;
    final chat = _chat;
    final identity = _identity;
    final transport = _chatTransport;
    if (ble == null || chat == null || identity == null || transport == null) {
      return;
    }
    try {
      final permission = await ble.requestPermissions();
      if (permission != BlePermissionState.granted &&
          permission != BlePermissionState.notRequired) {
        _append('Bluetooth permission: ${permission.name}');
        return;
      }
      await chat.initialize(identity: identity, transports: [transport]);
      if (mounted) setState(() => _running = true);
      _append('mesh chat started as ${identity.peerId}');
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
    threads.addAll(_chat?.groups.keys ?? const <String>[]);
    final selected = _selectedPeerId;
    if (selected != null) threads.add(selected);
    return threads.toList();
  }

  List<ChatMessage> get _visibleMessages => _messages
      .where((message) => message.threadId == _thread)
      .toList(growable: false);

  String _labelFor(String thread) {
    if (thread == _generalChannel) return '#$_generalChannel';
    if (_chat?.groups.containsKey(thread) ?? false) {
      return 'Group ${thread.split('/').last.substring(0, 6)}';
    }
    for (final peer in _peers) {
      if (peer.id == thread) return peer.displayName;
    }
    return thread;
  }

  bool _isConnected(String thread) =>
      thread == _generalChannel || _peers.any((peer) => peer.id == thread);

  bool _hasKeyFor(String thread) {
    if (thread == _generalChannel) return false;
    if (_chat?.groups.containsKey(thread) ?? false) return true;
    for (final peer in _peers) {
      if (peer.id == thread) return peer.canReceiveDirect;
    }
    return _security?.trustStore.keysFor(thread) != null;
  }

  /// Whether we hold a verified key for the selected peer. Without one a
  /// direct message cannot be sealed, and the plugin refuses to send it in
  /// the clear.
  bool get _canEncryptToSelected {
    final selected = _selectedPeerId;
    if (selected == null || (_chat?.groups.containsKey(selected) ?? false)) {
      return true;
    }
    for (final peer in _peers) {
      if (peer.id == selected) return peer.canReceiveDirect;
    }
    return _security?.trustStore.keysFor(selected) != null;
  }

  void _selectThread(String thread) => setState(() {
    _selectedPeerId = thread == _generalChannel ? null : thread;
    _unread.remove(thread);
  });

  Future<void> _send() async {
    final value = _text.text.trim();
    if (value.isEmpty) return;
    _text.clear();
    final chat = _chat;
    if (chat == null) return;
    final peerId = _selectedPeerId;
    try {
      if (peerId == null) {
        await chat.send(conversationId: _generalChannel, text: value);
      } else if (chat.groups.containsKey(peerId)) {
        await chat.sendGroup(groupId: peerId, text: value);
      } else {
        await chat.sendDirect(peerId: peerId, text: value);
      }
    } on Object catch (error) {
      _append('send failed: $error');
    }
  }

  Future<void> _createGroup() async {
    final chat = _chat;
    if (chat == null || !_running) return;
    final candidates = _peers.where((peer) => peer.canReceiveDirect).toList();
    final selected = <String>{};
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Create encrypted group'),
          content: SizedBox(
            width: 320,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final peer in candidates)
                  CheckboxListTile(
                    title: Text(peer.displayName),
                    subtitle: Text(peer.id),
                    value: selected.contains(peer.id),
                    onChanged: (value) => update(() {
                      if (value == true) {
                        selected.add(peer.id);
                      } else {
                        selected.remove(peer.id);
                      }
                    }),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: selected.isEmpty
                  ? null
                  : () => Navigator.pop(context, true),
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
    if (approved != true) return;
    try {
      final group = await chat.createGroup(memberIds: selected);
      if (mounted) _selectThread(group.id);
      _append('Created group ${group.id}, epoch ${group.epoch}');
    } catch (error) {
      _append('group creation failed: $error');
    }
  }

  Future<void> _changeGroupMember() async {
    final chat = _chat;
    final selfId = _identity?.peerId;
    final group = chat?.groups[_thread];
    if (chat == null ||
        selfId == null ||
        group == null ||
        group.ownerId != selfId) {
      return;
    }
    final candidates = {...group.members, ..._peers.map((peer) => peer.id)}
      ..remove(selfId);
    final selected = {...group.members}..remove(selfId);
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Change group members'),
          content: SizedBox(
            width: 320,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final id in candidates)
                  CheckboxListTile(
                    title: Text(_labelFor(id)),
                    subtitle: Text(id),
                    value: selected.contains(id),
                    onChanged: (value) => update(() {
                      if (value == true) {
                        selected.add(id);
                      } else {
                        selected.remove(id);
                      }
                    }),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Rotate key'),
            ),
          ],
        ),
      ),
    );
    if (approved != true) return;
    try {
      final next = await chat.changeGroupMembers(
        groupId: group.id,
        memberIds: selected,
      );
      _append('Group key rotated to epoch ${next.epoch}');
    } catch (error) {
      _append('group change failed: $error');
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

  void _onSecurityError(Object error) {
    _append('BLE chat error: $error');
    if (error is PeerKeyChangedException &&
        _rotationPrompts.add(error.peerId)) {
      unawaited(
        _approveRotation(error).catchError((Object failure) {
          _append('Could not approve key change: $failure');
        }),
      );
    }
  }

  Future<void> _approveRotation(PeerKeyChangedException error) async {
    if (!mounted) return;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Peer encryption key changed'),
        content: SelectableText(
          'Compare this key with the peer before accepting.\n'
          '${error.peerId}\n${base64Encode(error.proposedKeys.agreement)}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Reject'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Accept'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    final security = _security!;
    final previous = security.trustStore.keysFor(error.peerId);
    security.trustStore.acceptRotation(error.peerId, error.proposedKeys);
    try {
      await _identityStore!.saveTrust(security.trustStore);
    } catch (_) {
      if (previous != null) {
        security.trustStore.acceptRotation(error.peerId, previous);
      }
      rethrow;
    }
    _chatTransport?.refreshTrust();
    _append('Approved new key for ${error.peerId}; authentication will retry.');
  }

  Future<void> _rotateOwnKey() async {
    final security = _security;
    final store = _identityStore;
    if (security == null || store == null) return;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rotate encryption key?'),
        content: const Text(
          'Peers must approve the replacement. Messages encrypted to the old key will no longer decrypt. Restart this app after rotation.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Rotate'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    try {
      final replacement = await security.identity.rotateAgreementKey();
      await store.save(replacement);
      await _chatTransport?.stop();
      if (mounted) {
        setState(() {
          _running = false;
          _restartRequired = true;
        });
      }
      _append(
        'Key rotated. Restart the app before chatting. New agreement key: ${base64Encode(replacement.publicKeys.agreement)}',
      );
    } catch (error) {
      _append('Key rotation failed: $error');
    }
  }

  Future<void> _disposeTransports() async {
    await _chat?.dispose();
    await _ble?.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final identity = _identity;
    if (identity == null) {
      return Scaffold(
        body: Center(
          child: _startupError == null
              ? const CircularProgressIndicator()
              : Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'Could not load the saved identity. Existing keys have been preserved. '
                    'Resolve the storage error and restart.\n$_startupError',
                  ),
                ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('ble_mesh chat harness'),
        actions: [
          IconButton(
            tooltip: 'Create encrypted group',
            onPressed: _running ? _createGroup : null,
            icon: const Icon(Icons.group_add),
          ),
          IconButton(
            tooltip: 'Change group members',
            onPressed: _chat?.groups.containsKey(_thread) == true
                ? _changeGroupMember
                : null,
            icon: const Icon(Icons.group),
          ),
          IconButton(
            tooltip: 'Rotate encryption key',
            onPressed: _restartRequired ? null : _rotateOwnKey,
            icon: const Icon(Icons.key),
          ),
        ],
      ),
      body: Column(
        children: [
          Material(
            color: Theme.of(context).colorScheme.surfaceContainer,
            child: ListTile(
              title: Text(identity.displayName),
              subtitle: Text(
                'adapter=${_adapter.name} · links=${_links.length} · '
                'peers=${_peers.length}',
              ),
              trailing: FilledButton(
                onPressed: _running || _restartRequired ? null : _start,
                child: Text(
                  _restartRequired
                      ? 'Restart app'
                      : _running
                      ? 'Running'
                      : 'Start',
                ),
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
                              : (_chat?.groups.containsKey(thread) ?? false)
                              ? const Icon(Icons.group, size: 18)
                              : Icon(
                                  _hasKeyFor(thread)
                                      ? Icons.lock
                                      : _isConnected(thread)
                                      ? Icons.lock_open
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
                          : (_chat?.groups.containsKey(_thread) ?? false)
                          ? 'Encrypted message ${_labelFor(_thread)}'
                          : 'Direct message ${_labelFor(_thread)}',
                      helperText: _selectedPeerId == null
                          ? 'Channel messages are signed but readable'
                          : (_chat?.groups.containsKey(_thread) ?? false)
                          ? 'Encrypted group · experimental, unreviewed'
                          : _canEncryptToSelected
                          ? 'Encrypted · experimental, unreviewed'
                          : 'No key for this peer yet — sending will fail',
                      helperStyle: TextStyle(
                        color: _selectedPeerId != null && !_canEncryptToSelected
                            ? Theme.of(context).colorScheme.error
                            : null,
                      ),
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
}
