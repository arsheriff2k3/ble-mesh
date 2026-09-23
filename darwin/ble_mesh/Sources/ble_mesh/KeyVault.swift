import Foundation
import Security

#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#endif

/// Stores the mesh identity's private keys in the Keychain.
///
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` is deliberate: the mesh
/// must be able to receive and relay while the phone is locked in a pocket, so
/// requiring an unlocked device would break the transport. `ThisDeviceOnly`
/// keeps the identity out of iCloud and encrypted backups — a peer id is meant
/// to identify one device, and silently restoring it onto a second one would
/// make two phones claim the same identity.
enum KeyVault {
  static let channelName = "dev.blemesh.ble_mesh/keys"
  private static let service = "dev.blemesh.ble_mesh.identity"

  static func register(with messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      handle(call: call, result: result)
    }
    return channel
  }

  private static func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any]
    switch call.method {
    case "isAvailable":
      result(true)
    case "read":
      guard let key = arguments?["key"] as? String else {
        result(FlutterError(code: "bad_arguments", message: "key is required", details: nil))
        return
      }
      do {
        result(try read(key).map { FlutterStandardTypedData(bytes: $0) })
      } catch {
        result(FlutterError(code: "keychain_failed", message: "could not read key", details: nil))
      }
    case "write":
      guard let key = arguments?["key"] as? String,
        let value = arguments?["value"] as? FlutterStandardTypedData
      else {
        result(FlutterError(code: "bad_arguments", message: "key and value are required", details: nil))
        return
      }
      if write(key, value.data) {
        result(nil)
      } else {
        result(FlutterError(code: "keychain_failed", message: "could not store key", details: nil))
      }
    case "delete":
      guard let key = arguments?["key"] as? String else {
        result(FlutterError(code: "bad_arguments", message: "key is required", details: nil))
        return
      }
      let status = SecItemDelete(baseQuery(key) as CFDictionary)
      if status == errSecSuccess || status == errSecItemNotFound {
        result(nil)
      } else {
        result(FlutterError(code: "keychain_failed", message: "could not delete key", details: nil))
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func read(_ key: String) throws -> Data? {
    var query = baseQuery(key)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
    return data
  }

  private static func write(_ key: String, _ value: Data) -> Bool {
    let attributes: [String: Any] = [
      kSecValueData as String: value,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let status = SecItemUpdate(baseQuery(key) as CFDictionary, attributes as CFDictionary)
    if status == errSecSuccess { return true }
    guard status == errSecItemNotFound else { return false }
    var query = baseQuery(key)
    attributes.forEach { query[$0.key] = $0.value }
    return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
  }

  private static func baseQuery(_ key: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
    ]
  }
}
