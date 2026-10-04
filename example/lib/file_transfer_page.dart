import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ble_mesh_chat/ble_mesh_chat.dart';
import 'package:flutter/material.dart';

/// Physical-device harness for the file protocol; fixtures avoid picker or
/// document-viewer dependencies in the transport plugin example.
class FileTransferPage extends StatefulWidget {
  const FileTransferPage({
    super.key,
    required this.service,
    required this.peers,
  });
  final BleFileTransfer service;
  final List<ChatPeer> peers;
  @override
  State<FileTransferPage> createState() => _FileTransferPageState();
}

class _FileTransferPageState extends State<FileTransferPage> {
  StreamSubscription<FileTransfer>? _subscription;
  String? _peer;
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _peer = widget.peers.firstOrNull?.id;
    _subscription = widget.service.changes.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  Future<void> _act(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _offer(bool image) => _act(() async {
    final peer = _peer;
    if (peer == null) throw StateError('select a direct BLE peer');
    await widget.service.offer(
      peerId: peer,
      fileName: image ? 'mesh-pixel.png' : 'mesh-demo.pdf',
      mimeType: image ? 'image/png' : 'application/pdf',
      bytes: image
          ? base64Decode(
              'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAFklEQVR4nGPgndJBEmIY1TCqYfhqAABqqikQLN19fgAAAABJRU5ErkJggg==',
            )
          : _pdf(),
    );
  });

  Future<void> _inspect(FileTransfer file) => _act(() async {
    final bytes = await widget.service.readReceived(file.id);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(UntrustedText.stripHidden(file.fileName)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (file.mimeType == 'image/png')
                Image.memory(
                  bytes,
                  width: 120,
                  height: 120,
                  errorBuilder: (_, error, stack) =>
                      const Text('Image decoding failed'),
                ),
              Text('${bytes.length} bytes verified\nSHA-256: ${file.sha256}'),
              const SizedBox(height: 12),
              const Text(
                'The host application can export these verified bytes or open them with its document viewer.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Offline files')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Direct BLE only · approval · images/videos 5 MiB · documents 2 MiB',
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: _peer,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Nearby BLE peer',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final peer in widget.peers)
                DropdownMenuItem(
                  value: peer.id,
                  child: Text(
                    UntrustedText.stripHidden(peer.displayName),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: _busy ? null : (value) => setState(() => _peer = value),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: _busy || _peer == null ? null : () => _offer(false),
                icon: const Icon(Icons.picture_as_pdf),
                label: const Text('Send demo PDF'),
              ),
              OutlinedButton.icon(
                onPressed: _busy || _peer == null ? null : () => _offer(true),
                icon: const Icon(Icons.image_outlined),
                label: const Text('Send demo PNG'),
              ),
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 16),
          if (widget.service.transfers.isEmpty)
            const Text('Incoming offers and saved transfers appear here.'),
          for (final file in widget.service.transfers.reversed)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      UntrustedText.stripHidden(file.fileName),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      '${file.outgoing ? 'sending' : 'receiving'} · ${file.state.name} · ${file.offset}/${file.byteLength} bytes',
                    ),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: file.offset / file.byteLength,
                    ),
                    if (file.error != null) Text(file.error!),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        if (!file.outgoing &&
                            file.state == FileTransferState.offered) ...[
                          FilledButton(
                            onPressed: _busy
                                ? null
                                : () => _act(
                                    () => widget.service.accept(file.id),
                                  ),
                            child: const Text('Accept'),
                          ),
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () => _act(
                                    () => widget.service.reject(file.id),
                                  ),
                            child: const Text('Decline'),
                          ),
                        ],
                        if (file.outgoing &&
                            (file.state == FileTransferState.paused ||
                                file.state == FileTransferState.offered))
                          OutlinedButton(
                            onPressed: _busy
                                ? null
                                : () => _act(
                                    () => widget.service.resume(file.id),
                                  ),
                            child: const Text('Resume offer'),
                          ),
                        if (!file.terminal)
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () => _act(
                                    () => widget.service.cancel(file.id),
                                  ),
                            child: const Text('Cancel'),
                          ),
                        if (!file.outgoing &&
                            file.state == FileTransferState.completed)
                          FilledButton(
                            onPressed: _busy ? null : () => _inspect(file),
                            child: const Text('Inspect verified file'),
                          ),
                        if (file.terminal)
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () => _act(
                                    () => widget.service.delete(file.id),
                                  ),
                            child: const Text('Delete'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

// Valid single-page PDF with padding comments to exercise multiple BLE chunks.
Uint8List _pdf() {
  final out = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[0];
  const text =
      'BT /F1 18 Tf 50 740 Td (Offline BLE attachment verified.) Tj ET';
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    '<< /Length ${text.length} >>\nstream\n$text\nendstream',
  ];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(out.length);
    out.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  for (var i = 0; i < 1600; i++) {
    out.write('% BLE offline transfer fixture padding $i\n');
  }
  final xref = out.length;
  out.write('xref\n0 6\n0000000000 65535 f \n');
  for (final offset in offsets.skip(1)) {
    out.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  out.write('trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n');
  return Uint8List.fromList(ascii.encode(out.toString()));
}
