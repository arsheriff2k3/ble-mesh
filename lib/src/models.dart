import 'dart:typed_data';

import 'ble_api.g.dart';

/// One frame as it arrived from a peer, tagged with the link it came in on.
class BleFrame {
  const BleFrame({required this.linkId, required this.data});

  final String linkId;
  final Uint8List data;

  @override
  String toString() => 'BleFrame($linkId, ${data.length}B)';
}

/// A link that has gone away, with whatever the platform said about why.
class BleLinkDown {
  const BleLinkDown({required this.linkId, this.reason});

  final String linkId;
  final String? reason;

  @override
  String toString() => 'BleLinkDown($linkId, ${reason ?? 'no reason given'})';
}

/// A non-fatal platform problem worth surfacing in diagnostics.
///
/// These are advisory: the transport keeps running. Fatal conditions are
/// thrown from the method that caused them instead.
class BleTransportError {
  const BleTransportError({
    required this.code,
    required this.message,
    this.linkId,
  });

  final BleErrorCode code;
  final String message;
  final String? linkId;

  @override
  String toString() =>
      'BleTransportError(${code.name}, $message${linkId == null ? '' : ', $linkId'})';
}

/// Per-link outcome of a [BleMeshTransport.broadcast].
///
/// A broadcast that partially fails is the normal case in a mesh — peers walk
/// out of range mid-send — so the caller gets the detail rather than a single
/// thrown error.
class BleBroadcastReport {
  const BleBroadcastReport({required this.delivered, required this.failed});

  final List<String> delivered;
  final Map<String, Object> failed;

  bool get isCompleteSuccess => failed.isEmpty;

  int get attempted => delivered.length + failed.length;

  @override
  String toString() =>
      'BleBroadcastReport(${delivered.length} delivered, ${failed.length} failed)';
}

/// Thrown when the host platform has no BLE transport at all (web, Linux,
/// Windows), so the caller can fall back to an online transport instead of
/// treating it as a crash.
class BleUnsupportedPlatformException implements Exception {
  const BleUnsupportedPlatformException(this.message);

  final String message;

  @override
  String toString() => 'BleUnsupportedPlatformException: $message';
}

/// Thrown when a frame is larger than the link can carry.
///
/// The transport never fragments: splitting a packet is a protocol decision
/// (fragment headers, reassembly timeouts, ordering) and belongs one layer up.
class BleFrameTooLargeException implements Exception {
  const BleFrameTooLargeException({
    required this.linkId,
    required this.frameSize,
    required this.maxFrameSize,
  });

  final String linkId;
  final int frameSize;
  final int maxFrameSize;

  @override
  String toString() =>
      'BleFrameTooLargeException: ${frameSize}B frame exceeds the ${maxFrameSize}B '
      'limit of $linkId; fragment before sending';
}

/// Thrown when [BleMeshTransport.send] names a link that is no longer live.
class BleUnknownLinkException implements Exception {
  const BleUnknownLinkException(this.linkId);

  final String linkId;

  @override
  String toString() => 'BleUnknownLinkException: no live link $linkId';
}
