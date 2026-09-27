import 'dart:typed_data';

import 'ble_api.g.dart';

/// One frame as it arrived from a peer, tagged with the link it came in on.
class BleFrame {
  /// Creates a frame.
  const BleFrame({required this.linkId, required this.data});

  /// Platform id of the link the frame arrived on.
  final String linkId;

  /// Frame bytes exactly as the peer sent them, with no reassembly. Any
  /// device that connects can send these, so treat them as untrusted input.
  final Uint8List data;

  @override
  String toString() => 'BleFrame($linkId, ${data.length}B)';
}

/// A link that has gone away, with whatever the platform said about why.
class BleLinkDown {
  /// Creates a link-down notice.
  const BleLinkDown({required this.linkId, this.reason});

  /// Platform id of the link that went away.
  final String linkId;

  /// The platform's free-form explanation, or null when it gave none. For
  /// diagnostics only; do not parse it.
  final String? reason;

  @override
  String toString() => 'BleLinkDown($linkId, ${reason ?? 'no reason given'})';
}

/// A non-fatal platform problem worth surfacing in diagnostics.
///
/// These are advisory: the transport keeps running. Fatal conditions are
/// thrown from the method that caused them instead.
class BleTransportError {
  /// Creates a transport error.
  const BleTransportError({
    required this.code,
    required this.message,
    this.linkId,
  });

  /// Category of the problem, for deciding how to react.
  final BleErrorCode code;

  /// Human-readable detail for logs and diagnostics.
  final String message;

  /// The link the problem concerns, or null when it is not about one link.
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
  /// Creates a broadcast report.
  const BleBroadcastReport({required this.delivered, required this.failed});

  /// Ids of the links that transmitted the frame.
  final List<String> delivered;

  /// Links that did not take the frame, mapped to the error each threw.
  final Map<String, Object> failed;

  /// Whether no link failed. Also true when there were no links at all.
  bool get isCompleteSuccess => failed.isEmpty;

  /// Number of links the frame was sent to.
  int get attempted => delivered.length + failed.length;

  @override
  String toString() =>
      'BleBroadcastReport(${delivered.length} delivered, ${failed.length} failed)';
}

/// Thrown when the host platform has no BLE transport at all (web, Linux,
/// Windows), so the caller can fall back to an online transport instead of
/// treating it as a crash.
class BleUnsupportedPlatformException implements Exception {
  /// Creates the exception with an explanatory [message].
  const BleUnsupportedPlatformException(this.message);

  /// Human-readable explanation.
  final String message;

  @override
  String toString() => 'BleUnsupportedPlatformException: $message';
}

/// Thrown when a frame is larger than the link can carry.
///
/// The transport never fragments: splitting a packet is a protocol decision
/// (fragment headers, reassembly timeouts, ordering) and belongs one layer up.
class BleFrameTooLargeException implements Exception {
  /// Creates the exception.
  const BleFrameTooLargeException({
    required this.linkId,
    required this.frameSize,
    required this.maxFrameSize,
  });

  /// The link the frame was meant for.
  final String linkId;

  /// Size of the rejected frame, in bytes.
  final int frameSize;

  /// Largest frame the link accepts, in bytes.
  final int maxFrameSize;

  @override
  String toString() =>
      'BleFrameTooLargeException: ${frameSize}B frame exceeds the ${maxFrameSize}B '
      'limit of $linkId; fragment before sending';
}

/// Thrown when [BleMeshTransport.send] names a link that is no longer live.
class BleUnknownLinkException implements Exception {
  /// Creates the exception for [linkId].
  const BleUnknownLinkException(this.linkId);

  /// The link id that was not found among the live links.
  final String linkId;

  @override
  String toString() => 'BleUnknownLinkException: no live link $linkId';
}
