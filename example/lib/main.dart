import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ble_mesh_chat/ble_mesh_chat.dart';
import 'package:ble_mesh_chat/file_store.dart';
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

class _ChatPageState extends State<ChatPage> with WidgetsBindingObserver {
  ChatIdentity? _identity;
  IdentityStore? _identityStore;
  PacketSecurity? _security;
  BleMeshTransport? _ble;
  BleChatTransport? _chatTransport;
  NostrChatTransport? _nostr;
  BleMeshChat? _chat;
  File? _relayFile;
  List<String> _relayUrls = const [];
  List<Uri> _connectedRelays = const [];
  File? _bridgeFile;
  _BridgeSettings _bridge = const _BridgeSettings();
  BridgeStatus? _bridgeStatus;
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
    WidgetsBinding.instance.addObserver(this);
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
    final relayFile = File('${directory.path}/relays.txt');
    final relayUrls = await relayFile.exists()
        ? _parseRelayList(await relayFile.readAsString())
        : const <String>[];
    final bridgeFile = File('${directory.path}/bridge.json');
    final bridge = await _BridgeSettings.load(bridgeFile);

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
      // Both are off until this device's user turns them on.
      bridgeConsent: bridge.consent,
      bridgePolicy: bridge.policy,
    );
    // This harness has no connectivity detection; the user reports it.
    chat.updateNetworkConditions(bridge.conditions);
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
      _relayFile = relayFile;
      _relayUrls = relayUrls;
      _bridgeFile = bridgeFile;
      _bridge = bridge;
      _bridgeStatus = chat.bridgeStatus;
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
      chat.bridgeStatusChanges.listen((status) {
        if (mounted) setState(() => _bridgeStatus = status);
        _append('bridge: $status');
      }),
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
      final bleAllowed =
          permission == BlePermissionState.granted ||
          permission == BlePermissionState.notRequired;
      if (!bleAllowed) _append('Bluetooth permission: ${permission.name}');
      // Relays keep direct messages flowing to peers outside BLE range, and
      // are the only route when Bluetooth is unavailable.
      final online = _createNostr(identity);
      final transports = <ChatTransport>[
        ?(bleAllowed ? transport : null),
        ?online,
      ];
      if (transports.isEmpty) return;
      await chat.initialize(identity: identity, transports: transports);
      if (mounted) setState(() => _running = true);
      _append('mesh chat started as ${identity.peerId}');
    } on PlatformException catch (error) {
      _append('start failed: ${error.code} ${error.message ?? ''}');
    } on Object catch (error) {
      _append('start failed: $error');
    }
  }

  /// Returning to the app usually follows a trip to Settings to switch
  /// Wi-Fi, mobile data, or Bluetooth. Reconnect relays now instead of
  /// waiting out the backoff; the BLE radio recovers on its own.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _nostr?.reconnectNow();
  }

  /// Always created, even with no relays, so relays can be added later
  /// without restarting the app.
  NostrChatTransport? _createNostr(ChatIdentity identity) {
    try {
      final nostr = NostrChatTransport(identity: identity, relays: _relayUrls);
      _subscriptions.addAll([
        nostr.errors.listen((error) => _append('relay: $error')),
        nostr.connectedRelayChanges.listen((relays) {
          if (mounted) setState(() => _connectedRelays = relays);
        }),
      ]);
      _nostr = nostr;
      return nostr;
    } on ArgumentError catch (error) {
      _append('relays ignored: ${error.message}');
      return null;
    }
  }

  static List<String> _parseRelayList(String text) => text
      .split(RegExp(r'[\s,]+'))
      .where((value) => value.isNotEmpty)
      .toSet()
      .toList(growable: false);

  Future<void> _editRelays() async {
    final file = _relayFile;
    if (file == null) return;
    final controller = TextEditingController(text: _relayUrls.join('\n'));
    final saved = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Online relays'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'One wss:// Nostr relay per line. Direct messages to peers '
                'outside BLE range are published there as encrypted events. '
                'Leave empty to stay offline-only.',
              ),
              TextField(
                controller: controller,
                minLines: 3,
                maxLines: 6,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  hintText: 'wss://relay.example.com',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved == null) return;
    final urls = _parseRelayList(saved);
    try {
      await file.writeAsString(urls.join('\n'), flush: true);
    } on Object catch (error) {
      _append('Could not save relays: $error');
      return;
    }
    final nostr = _nostr;
    if (nostr != null) {
      try {
        await nostr.setRelays(urls);
      } on ArgumentError catch (error) {
        _append('relays not applied: ${error.message}');
        return;
      }
    }
    if (mounted) setState(() => _relayUrls = urls);
    _append('Relays saved: ${urls.length}');
  }

  Future<void> _editBridge() async {
    final chat = _chat;
    final file = _bridgeFile;
    if (chat == null || file == null) return;
    var draft = _bridge;
    final saved = await showDialog<_BridgeSettings>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Gateway and bridging'),
          content: SizedBox(
            width: 380,
            child: ListView(
              shrinkWrap: true,
              children: [
                SwitchListTile(
                  title: const Text('Let gateways carry my messages'),
                  subtitle: const Text(
                    'When you have no internet, nearby gateways may publish '
                    'your encrypted direct messages to relays. Relays see '
                    'who you write to and when, not what.',
                  ),
                  value: draft.consent,
                  onChanged: (value) =>
                      update(() => draft = draft.copyWith(consent: value)),
                ),
                const Divider(),
                SwitchListTile(
                  title: const Text('Act as a gateway'),
                  subtitle: const Text(
                    "Uses this phone's data and battery to carry other "
                    "people's encrypted messages between Bluetooth and the "
                    'internet.',
                  ),
                  value: draft.gateway,
                  onChanged: (value) =>
                      update(() => draft = draft.copyWith(gateway: value)),
                ),
                SwitchListTile(
                  title: const Text('Allow on metered data'),
                  value: draft.allowMetered,
                  onChanged: draft.gateway
                      ? (value) => update(
                          () => draft = draft.copyWith(allowMetered: value),
                        )
                      : null,
                ),
                SwitchListTile(
                  title: const Text('Allow while roaming'),
                  value: draft.allowRoaming,
                  onChanged: draft.gateway
                      ? (value) => update(
                          () => draft = draft.copyWith(allowRoaming: value),
                        )
                      : null,
                ),
                const Divider(),
                const ListTile(
                  dense: true,
                  title: Text(
                    'Current connection (set by hand in this harness)',
                  ),
                ),
                CheckboxListTile(
                  title: const Text('Metered (cellular or hotspot)'),
                  value: draft.metered,
                  onChanged: (value) =>
                      update(() => draft = draft.copyWith(metered: value)),
                ),
                CheckboxListTile(
                  title: const Text('Roaming'),
                  value: draft.roaming,
                  onChanged: (value) =>
                      update(() => draft = draft.copyWith(roaming: value)),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, draft),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (saved == null) return;
    try {
      await saved.save(file);
    } on Object catch (error) {
      _append('Could not save bridge settings: $error');
      return;
    }
    chat
      ..setBridgeConsent(saved.consent)
      ..setBridgePolicy(saved.policy)
      ..updateNetworkConditions(saved.conditions);
    if (mounted) {
      setState(() {
        _bridge = saved;
        _bridgeStatus = chat.bridgeStatus;
      });
    }
  }

  String get _bridgeSummary {
    final status = _bridgeStatus;
    if (!_bridge.gateway || status == null) return '';
    return status.active
        ? ' · gateway: ${status.bridgedPeers} peers, ${status.bridgedPackets} carried'
        : ' · gateway off: ${status.reason?.name}';
  }

  /// Shows this device's contact code and pins a pasted one, so two phones
  /// that have never been in BLE range can message each other online.
  Future<void> _contacts() async {
    final security = _security;
    final store = _identityStore;
    final identity = _identity;
    if (security == null || store == null || identity == null) return;
    final myCode = security.identity.publicKeys.toContactCode();
    final input = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Contacts'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Your contact code',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              SelectableText(
                myCode,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
              TextButton.icon(
                onPressed: () => Clipboard.setData(ClipboardData(text: myCode)),
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Copy'),
              ),
              const Divider(),
              TextField(
                controller: input,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: "Paste a peer's code",
                  helperText:
                      'Only add codes received over a channel you trust.',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, input.text),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (code == null || code.trim().isEmpty) return;
    final ChatPublicKeys keys;
    try {
      keys = ChatPublicKeys.fromContactCode(code);
    } on FormatException {
      _append('Not a valid contact code.');
      return;
    }
    if (keys.peerId == identity.peerId) {
      _append("That is this device's own code.");
      return;
    }
    switch (security.trustStore.classify(keys.peerId, keys)) {
      case PeerTrust.changed:
        _append(
          '${keys.peerId} is already pinned with a different key; not replaced.',
        );
        return;
      case PeerTrust.known:
        _append('${keys.peerId} is already a contact.');
      case PeerTrust.firstContact:
        security.trustStore.observe(keys.peerId, keys);
        try {
          await store.saveTrust(security.trustStore);
        } on Object catch (error) {
          security.trustStore.forget(keys.peerId);
          _append('Could not save contact: $error');
          return;
        }
        _append(
          'Added contact ${keys.peerId}. Safety number, to compare in '
          'person: ${ChatPublicKeys.safetyNumber(security.identity.publicKeys, keys)}',
        );
    }
    if (mounted) _selectThread(keys.peerId);
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
    // Mirrored to the system log so a tester can capture it with
    // `adb logcat -s flutter`.
    debugPrint('ble_mesh_harness: $value');
    if (!mounted) return;
    setState(() {
      _log.insert(0, value);
      if (_log.length > 100) _log.removeLast();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
          'Compare this safety number with the peer in person before '
          'accepting. A phone or video call is not enough: voices and faces '
          'can be synthesized.\n\n'
          '${error.peerId}\n'
          '${ChatPublicKeys.safetyNumber(_security!.identity.publicKeys, error.proposedKeys)}',
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
            tooltip: 'Contacts',
            onPressed: _contacts,
            icon: const Icon(Icons.person_add),
          ),
          IconButton(
            tooltip: 'Online relays',
            onPressed: _editRelays,
            icon: Icon(
              _relayUrls.isEmpty ? Icons.cloud_off : Icons.cloud_outlined,
            ),
          ),
          IconButton(
            tooltip: 'Gateway and bridging',
            onPressed: _editBridge,
            icon: Icon(
              _bridge.gateway || _bridge.consent
                  ? Icons.swap_horiz
                  : Icons.sync_disabled,
            ),
          ),
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
      // Keeps Diagnostics clear of the system navigation bar.
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Material(
              color: Theme.of(context).colorScheme.surfaceContainer,
              child: ListTile(
                title: Text(identity.displayName),
                subtitle: Text(
                  'adapter=${_adapter.name} · links=${_links.length} · '
                  'peers=${_peers.length}'
                  '${_relayUrls.isEmpty ? '' : ' · relays=${_connectedRelays.length}/${_relayUrls.length}'}'
                  '$_bridgeSummary',
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
                            // Remote text is untrusted: invisible characters
                            // can hide content from the reader.
                            Text(
                              message.isLocal
                                  ? message.text
                                  : UntrustedText.stripHidden(message.text),
                            ),
                            if (!message.isLocal && message.hasHiddenCharacters)
                              Text(
                                'Hidden characters removed',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
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
                          color:
                              _selectedPeerId != null && !_canEncryptToSelected
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
      ),
    );
  }
}

/// Bridging choices, persisted beside the message log.
class _BridgeSettings {
  const _BridgeSettings({
    this.consent = false,
    this.gateway = false,
    this.allowMetered = false,
    this.allowRoaming = false,
    this.metered = false,
    this.roaming = false,
  });

  final bool consent;
  final bool gateway;
  final bool allowMetered;
  final bool allowRoaming;
  final bool metered;
  final bool roaming;

  BridgePolicy? get policy => gateway
      ? BridgePolicy(allowMetered: allowMetered, allowRoaming: allowRoaming)
      : null;

  NetworkConditions get conditions =>
      NetworkConditions(metered: metered, roaming: roaming);

  _BridgeSettings copyWith({
    bool? consent,
    bool? gateway,
    bool? allowMetered,
    bool? allowRoaming,
    bool? metered,
    bool? roaming,
  }) => _BridgeSettings(
    consent: consent ?? this.consent,
    gateway: gateway ?? this.gateway,
    allowMetered: allowMetered ?? this.allowMetered,
    allowRoaming: allowRoaming ?? this.allowRoaming,
    metered: metered ?? this.metered,
    roaming: roaming ?? this.roaming,
  );

  static Future<_BridgeSettings> load(File file) async {
    if (!await file.exists()) return const _BridgeSettings();
    try {
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      bool flag(String key) => json[key] == true;
      return _BridgeSettings(
        consent: flag('consent'),
        gateway: flag('gateway'),
        allowMetered: flag('allowMetered'),
        allowRoaming: flag('allowRoaming'),
        metered: flag('metered'),
        roaming: flag('roaming'),
      );
    } on Object {
      // Unreadable settings fall back to everything off.
      return const _BridgeSettings();
    }
  }

  Future<void> save(File file) => file.writeAsString(
    jsonEncode({
      'consent': consent,
      'gateway': gateway,
      'allowMetered': allowMetered,
      'allowRoaming': allowRoaming,
      'metered': metered,
      'roaming': roaming,
    }),
    flush: true,
  );
}
