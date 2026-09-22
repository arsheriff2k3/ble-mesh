import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ble_mesh/ble_mesh.dart';

/// Transport-level debugging harness.
///
/// Deliberately independent of any host app: when a link misbehaves on
/// real hardware you want the smallest possible thing between you and the
/// radio. Install on two devices, tap Start on both, and watch the link list.
void main() => runApp(const HarnessApp());

class HarnessApp extends StatelessWidget {
  const HarnessApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'ble_mesh harness',
    theme: ThemeData(
      colorSchemeSeed: const Color(0xFF00695C),
      useMaterial3: true,
    ),
    home: const HarnessPage(),
  );
}

class LogEntry {
  LogEntry(this.at, this.kind, this.message);

  final DateTime at;
  final String kind;
  final String message;
}

class HarnessPage extends StatefulWidget {
  const HarnessPage({super.key});

  @override
  State<HarnessPage> createState() => _HarnessPageState();
}

class _HarnessPageState extends State<HarnessPage> {
  final _transport = BleMeshTransport();
  final _subscriptions = <StreamSubscription<void>>[];
  final _log = <LogEntry>[];

  BleCapabilities? _capabilities;
  BleAdapterState _adapterState = BleAdapterState.unknown;
  BlePermissionState? _permission;
  List<BleLink> _links = const [];

  /// Echoes every inbound frame back on the same link, so a second device can
  /// measure a real round trip rather than just "something arrived".
  bool _echo = true;
  var _counter = 0;

  @override
  void initState() {
    super.initState();
    _subscriptions.addAll([
      _transport.adapterState.listen((state) {
        setState(() => _adapterState = state);
        _append('adapter', state.name);
      }),
      _transport.linkUp.listen((link) {
        _append(
          'link up',
          '${link.linkId} role=${link.role.name} '
              'maxFrame=${link.maxFrameSize}B rssi=${link.rssi ?? '?'}',
        );
      }),
      _transport.linkDown.listen((down) {
        _append('link down', '${down.linkId}: ${down.reason ?? 'no reason'}');
      }),
      _transport.linksChanged.listen((links) => setState(() => _links = links)),
      _transport.errors.listen((error) => _append('error', error.toString())),
      _transport.frames.listen(_onFrame),
    ]);
    _refreshStatus();
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _transport.dispose();
    super.dispose();
  }

  Future<void> _refreshStatus() async {
    final capabilities = await _transport.capabilities();
    final state = await _transport.currentAdapterState();
    if (!mounted) return;
    setState(() {
      _capabilities = capabilities;
      _adapterState = state;
    });
  }

  void _onFrame(BleFrame frame) {
    final text = _describe(frame.data);
    _append('frame in', '${frame.linkId} ${frame.data.length}B $text');
    if (!_echo) return;
    final reply = Uint8List.fromList(utf8.encode('echo:$text'));
    _transport
        .send(frame.linkId, reply)
        .then((_) => _append('echo out', '${frame.linkId} ${reply.length}B'))
        .catchError((Object error) => _append('echo failed', '$error'));
  }

  String _describe(Uint8List data) {
    try {
      return utf8.decode(data);
    } on FormatException {
      return data.take(16).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    }
  }

  void _append(String kind, String message) {
    if (!mounted) return;
    setState(() {
      _log.insert(0, LogEntry(DateTime.now(), kind, message));
      if (_log.length > 300) _log.removeLast();
    });
  }

  Future<void> _requestPermissions() async {
    final state = await _transport.requestPermissions();
    if (!mounted) return;
    setState(() => _permission = state);
    _append('permission', state.name);
    await _refreshStatus();
  }

  Future<void> _start() async {
    try {
      await _transport.start(
        // Sample UUIDs are fine here. A real app generates its own — see
        // `BleMeshUuids`.
        config: BleMeshTransport.defaultConfig(advertisedName: 'bm-harness'),
      );
      _append('transport', 'started');
    } on BleUnsupportedPlatformException catch (error) {
      _append('transport', error.message);
    } on PlatformException catch (error) {
      _append('transport', 'start failed: ${error.code} ${error.message}');
    }
    if (mounted) setState(() {});
  }

  Future<void> _stop() async {
    await _transport.stop();
    _append('transport', 'stopped');
    if (mounted) setState(() {});
  }

  Future<void> _broadcastPing() async {
    final payload = Uint8List.fromList(utf8.encode('ping-${_counter++}'));
    final report = await _transport.broadcast(payload);
    _append(
      'broadcast',
      '${report.delivered.length} delivered, ${report.failed.length} failed'
          '${report.failed.isEmpty ? '' : ' ${report.failed}'}',
    );
  }

  Future<void> _pingLink(BleLink link) async {
    final payload = Uint8List.fromList(utf8.encode('ping-${_counter++}'));
    try {
      final started = DateTime.now();
      await _transport.send(link.linkId, payload);
      final elapsed = DateTime.now().difference(started).inMilliseconds;
      _append('sent', '${link.linkId} ${payload.length}B in ${elapsed}ms');
    } catch (error) {
      _append('send failed', '${link.linkId}: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final capabilities = _capabilities;
    return Scaffold(
      appBar: AppBar(title: const Text('ble_mesh harness')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'adapter: ${_adapterState.name}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  if (capabilities != null)
                    Text(
                      'platform: ${capabilities.platformName} · '
                      'central: ${capabilities.supportsCentral} · '
                      'peripheral: ${capabilities.supportsPeripheral}',
                    ),
                  if (capabilities != null && !capabilities.supportsPeripheral)
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text(
                        'This device cannot advertise: it can receive from the '
                        'mesh but peers cannot discover it.',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  if (_permission != null) Text('permission: ${_permission!.name}'),
                  Text('running: ${_transport.isRunning}'),
                  Text('minFrameSize: ${_transport.minFrameSize ?? '-'}'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: _requestPermissions,
                child: const Text('Permissions'),
              ),
              FilledButton(
                onPressed: _transport.isRunning ? null : _start,
                child: const Text('Start'),
              ),
              FilledButton.tonal(
                onPressed: _transport.isRunning ? _stop : null,
                child: const Text('Stop'),
              ),
              OutlinedButton(
                onPressed: _links.isEmpty ? null : _broadcastPing,
                child: const Text('Broadcast ping'),
              ),
              OutlinedButton(
                onPressed: () => _transport.refreshLinks(),
                child: const Text('Refresh links'),
              ),
            ],
          ),
          SwitchListTile(
            value: _echo,
            onChanged: (value) => setState(() => _echo = value),
            title: const Text('Echo inbound frames'),
            subtitle: const Text('Reply on the same link so round trips are measurable'),
          ),
          const Divider(),
          Text('links (${_links.length})', style: Theme.of(context).textTheme.titleMedium),
          if (_links.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('No links. Start the transport on two devices.'),
            ),
          for (final link in _links)
            ListTile(
              dense: true,
              title: Text(link.linkId),
              subtitle: Text(
                'role=${link.role.name} · maxFrame=${link.maxFrameSize}B · '
                'rssi=${link.rssi ?? '?'} · remote=${link.remoteId}',
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Ping',
                    icon: const Icon(Icons.send),
                    onPressed: () => _pingLink(link),
                  ),
                  IconButton(
                    tooltip: 'Disconnect',
                    icon: const Icon(Icons.link_off),
                    onPressed: () => _transport.disconnect(link.linkId),
                  ),
                ],
              ),
            ),
          const Divider(),
          Text('log', style: Theme.of(context).textTheme.titleMedium),
          for (final entry in _log)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                '${entry.at.toIso8601String().substring(11, 23)} '
                '[${entry.kind}] ${entry.message}',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}
