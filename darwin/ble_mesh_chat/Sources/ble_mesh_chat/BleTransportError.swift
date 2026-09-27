import Foundation

/// Internal failures that surface to Dart as a `PigeonError`.
enum BleTransportError: LocalizedError {
  case unsupported(String)
  case permissionDenied(String)
  case bluetoothOff(String)
  case notReady(String)
  case unknownLink(String)
  case frameTooLarge(String)
  case writeFailed(String)

  var code: String {
    switch self {
    case .unsupported: return "unsupported"
    case .permissionDenied: return "permission_denied"
    case .bluetoothOff: return "bluetooth_off"
    case .notReady: return "not_ready"
    case .unknownLink: return "unknown_link"
    case .frameTooLarge: return "frame_too_large"
    case .writeFailed: return "write_failed"
    }
  }

  var detail: String {
    switch self {
    case .unsupported(let message),
      .permissionDenied(let message),
      .bluetoothOff(let message),
      .notReady(let message),
      .unknownLink(let message),
      .frameTooLarge(let message),
      .writeFailed(let message):
      return message
    }
  }

  var errorDescription: String? { detail }

  /// The shape Pigeon forwards to Dart as a `PlatformException`, so error
  /// codes are the same string on both platforms.
  func asPigeonError() -> PigeonError {
    PigeonError(code: code, message: detail, details: nil)
  }
}
