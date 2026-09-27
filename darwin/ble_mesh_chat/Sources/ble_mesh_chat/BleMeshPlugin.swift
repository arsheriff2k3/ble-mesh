import Foundation

#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#endif

/// iOS and macOS entry point. Everything interesting lives in [BleController].
///
/// The generated async handlers run inside a `Task`, which is not guaranteed
/// to be the main thread, so each one hops to main before touching controller
/// state. The synchronous handlers are already invoked on the platform thread
/// by the binary messenger, so they call straight through.
public class BleMeshPlugin: NSObject, FlutterPlugin, BleMeshHostApi {
  private let events = BleEventBus()
  private lazy var controller = BleController(events: events)
  private var keys: FlutterMethodChannel?

  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
      let messenger = registrar.messenger()
    #else
      let messenger = registrar.messenger
    #endif

    let instance = BleMeshPlugin()
    BleMeshHostApiSetup.setUp(binaryMessenger: messenger, api: instance)
    EventsStreamHandler.register(with: messenger, streamHandler: instance.events)
    instance.keys = KeyVault.register(with: messenger)

    // Without this the registrar is the only owner and the plugin — along with
    // both CoreBluetooth managers — is deallocated the moment registration
    // returns.
    registrar.publish(instance)
  }

  // ---------------------------------------------------------------- host API

  func capabilities() throws -> BleCapabilities {
    controller.capabilities()
  }

  func adapterState() throws -> BleAdapterState {
    controller.adapterState()
  }

  func requestPermissions() async throws -> BlePermissionState {
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async {
        self.controller.requestPermissions { state in
          continuation.resume(returning: state)
        }
      }
    }
  }

  func start(config: BleConfig) async throws {
    try await onMain { try self.controller.start(config: config) }
  }

  func stop() async throws {
    try await onMain { self.controller.stop() }
  }

  func send(linkId: String, frame: FlutterStandardTypedData) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      DispatchQueue.main.async {
        self.controller.send(linkId: linkId, frame: frame.data) { error in
          if let error = error as? BleTransportError {
            continuation.resume(throwing: error.asPigeonError())
          } else if let error {
            continuation.resume(
              throwing: PigeonError(
                code: "write_failed",
                message: error.localizedDescription,
                details: linkId
              )
            )
          } else {
            continuation.resume()
          }
        }
      }
    }
  }

  func disconnect(linkId: String) async throws {
    try await onMain { self.controller.disconnect(linkId: linkId) }
  }

  func links() throws -> [BleLink] {
    controller.links()
  }

  // --------------------------------------------------------------- internals

  private func onMain<T>(_ body: @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
      DispatchQueue.main.async {
        do {
          continuation.resume(returning: try body())
        } catch let error as BleTransportError {
          continuation.resume(throwing: error.asPigeonError())
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }
}
