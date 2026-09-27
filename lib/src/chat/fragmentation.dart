import 'dart:typed_data';

/// Thrown when a fragment is malformed or inconsistent with its siblings, or
/// when a packet cannot be split into a valid fragment sequence.
class FragmentFormatException implements FormatException {
  /// Creates an exception describing the fault in [message].
  const FragmentFormatException(this.message);

  @override
  final String message;
  @override
  Object? get source => null;
  @override
  int? get offset => null;

  @override
  String toString() => 'FragmentFormatException: $message';
}

/// Splits an encoded packet into frames small enough for a BLE link.
///
/// Each frame carries a [headerLength]-byte header: magic `0xb17e` (u16),
/// version (u8), a reserved byte, a group id taken from the first four bytes
/// of the packet id (u32), the fragment index (u16), and the fragment count
/// (u16), all big-endian. [PacketReassembler] reverses the split.
class PacketFragmenter {
  /// Creates a stateless fragmenter.
  const PacketFragmenter();

  /// Bytes of header prepended to every frame.
  static const headerLength = 12;
  static const _magic = 0xb17e;
  static const _version = 1;

  /// Splits [packet] into frames of at most [maxFrameSize] bytes, in index
  /// order.
  ///
  /// Every frame except possibly the last carries
  /// `maxFrameSize - headerLength` payload bytes. Throws [ArgumentError] when
  /// [packetId] is not 16 bytes or [maxFrameSize] does not exceed
  /// [headerLength], and [FragmentFormatException] when [packet] is empty or
  /// would need more than 65535 fragments.
  List<Uint8List> fragment(
    Uint8List packetId,
    Uint8List packet,
    int maxFrameSize,
  ) {
    if (packetId.length != 16) throw ArgumentError('packetId must be 16 bytes');
    final payloadSize = maxFrameSize - headerLength;
    if (payloadSize < 1) {
      throw ArgumentError.value(
        maxFrameSize,
        'maxFrameSize',
        'must exceed $headerLength',
      );
    }
    final count = (packet.length / payloadSize).ceil();
    if (count == 0 || count > 0xffff) {
      throw const FragmentFormatException('invalid fragment count');
    }
    final groupId = ByteData.sublistView(packetId).getUint32(0);
    return List.generate(count, (index) {
      final start = index * payloadSize;
      final end = (start + payloadSize).clamp(0, packet.length);
      final frame = Uint8List(headerLength + end - start);
      final data = ByteData.sublistView(frame);
      data.setUint16(0, _magic);
      data.setUint8(2, _version);
      data.setUint8(3, 0);
      data.setUint32(4, groupId);
      data.setUint16(8, index);
      data.setUint16(10, count);
      frame.setRange(headerLength, frame.length, packet, start);
      return frame;
    }, growable: false);
  }
}

/// Rebuilds packets from frames produced by [PacketFragmenter].
///
/// Partial packets are tracked per route and fragment group, so frames from
/// different links never mix. Memory is bounded by [maxAssemblies] and
/// [maxPacketSize], and a partial packet that stops receiving frames is
/// dropped after [timeout].
class PacketReassembler {
  /// Creates a reassembler. [clock] defaults to [DateTime.now] and exists for
  /// tests.
  PacketReassembler({
    this.maxPacketSize = 64 * 1024,
    this.maxAssemblies = 32,
    this.timeout = const Duration(seconds: 20),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Largest reassembled packet accepted, in bytes. Defaults to 64 KiB.
  final int maxPacketSize;

  /// Most partial packets held at once. Defaults to 32; when full, starting
  /// a new one evicts the partial packet updated least recently.
  final int maxAssemblies;

  /// How long a partial packet survives without a new frame. Defaults to
  /// 20 seconds.
  final Duration timeout;
  final DateTime Function() _clock;
  final Map<String, _Assembly> _assemblies = {};

  /// Adds [frame] received on [routeId] and returns the whole packet once its
  /// last missing fragment arrives, or null while fragments are outstanding.
  ///
  /// Fragments may arrive in any order; a repeated index keeps the first
  /// copy. Throws [FragmentFormatException] for a truncated frame, an unknown
  /// magic or version, an index outside the declared count, a count that
  /// differs from earlier fragments of the same group, or a packet that
  /// exceeds [maxPacketSize]. The last two also discard the partial packet.
  Uint8List? add(String routeId, Uint8List frame) {
    _expire();
    if (frame.length < PacketFragmenter.headerLength) {
      throw const FragmentFormatException('truncated fragment');
    }
    final data = ByteData.sublistView(frame);
    if (data.getUint16(0) != 0xb17e || data.getUint8(2) != 1) {
      throw const FragmentFormatException('invalid fragment header');
    }
    final groupId = data.getUint32(4);
    final index = data.getUint16(8);
    final count = data.getUint16(10);
    if (count == 0 || index >= count) {
      throw const FragmentFormatException('invalid fragment index');
    }
    final key = '$routeId:$groupId';
    var assembly = _assemblies[key];
    if (assembly == null) {
      if (_assemblies.length >= maxAssemblies) {
        _assemblies.remove(_oldestKey());
      }
      assembly = _Assembly(count: count, updatedAt: _clock());
      _assemblies[key] = assembly;
    } else if (assembly.count != count) {
      _assemblies.remove(key);
      throw const FragmentFormatException('fragment count changed');
    }

    final payload = Uint8List.fromList(
      frame.sublist(PacketFragmenter.headerLength),
    );
    final previous = assembly.parts[index];
    if (previous == null) {
      assembly.parts[index] = payload;
      assembly.totalBytes += payload.length;
      if (assembly.totalBytes > maxPacketSize) {
        _assemblies.remove(key);
        throw FragmentFormatException(
          'reassembled packet exceeds ${maxPacketSize}B',
        );
      }
    }
    assembly.updatedAt = _clock();
    if (assembly.parts.length != count) return null;

    final result = Uint8List(assembly.totalBytes);
    var offset = 0;
    for (var partIndex = 0; partIndex < count; partIndex++) {
      final part = assembly.parts[partIndex];
      if (part == null) return null;
      result.setRange(offset, offset + part.length, part);
      offset += part.length;
    }
    _assemblies.remove(key);
    return result;
  }

  /// Drops every partial packet received on [routeId], for example when its
  /// link goes down.
  void discardRoute(String routeId) {
    _assemblies.removeWhere((key, _) => key.startsWith('$routeId:'));
  }

  void _expire() {
    final threshold = _clock().subtract(timeout);
    _assemblies.removeWhere(
      (_, assembly) => assembly.updatedAt.isBefore(threshold),
    );
  }

  String _oldestKey() => _assemblies.entries
      .reduce((a, b) => a.value.updatedAt.isBefore(b.value.updatedAt) ? a : b)
      .key;
}

class _Assembly {
  _Assembly({required this.count, required this.updatedAt});

  final int count;
  DateTime updatedAt;
  final Map<int, Uint8List> parts = {};
  int totalBytes = 0;
}
