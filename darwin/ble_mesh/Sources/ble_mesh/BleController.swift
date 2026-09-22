import CoreBluetooth
import Foundation

/// Orchestrates both radio roles and owns the link registry.
///
/// Every mesh device runs as central *and* peripheral simultaneously: it scans
/// and connects out while advertising and serving connections in. That is the
/// whole reason this plugin exists instead of an off-the-shelf package.
///
/// Main queue only. The plugin hops async host-API calls onto main before
/// touching anything here, and the synchronous ones already arrive there.
final class BleController {
  private let registry = LinkRegistry()
  private let events: BleEventBus
  private let central: CentralController
  private let peripheral: PeripheralController

  /// What Dart asked for, which outlives the radios: if Bluetooth is switched
  /// off mid-session the links drop, but the mesh comes back by itself once
  /// the user switches it on again.
  private var desiredConfig: BleConfig?

  init(events: BleEventBus) {
    self.events = events
    self.central = CentralController(registry: registry, events: events)
    self.peripheral = PeripheralController(registry: registry, events: events)

    central.onAdapterStateChange = { [weak self] state in
      guard let self else { return }
      self.events.adapterState(state)
      if state != .poweredOn {
        self.peripheral.dropAllLinks(reason: "bluetooth unavailable")
      }
    }
  }

  func capabilities() -> BleCapabilities {
    #if os(iOS)
      let platform = "ios"
    #else
      let platform = "macos"
    #endif
    // Unlike Android, every Apple device with BLE can act as a peripheral.
    return BleCapabilities(
      supportsCentral: true,
      supportsPeripheral: true,
      platformName: platform
    )
  }

  func adapterState() -> BleAdapterState {
    switch CBManager.authorization {
    case .denied, .restricted:
      return .unauthorized
    case .notDetermined:
      // Creating a manager is what prompts, so before that we genuinely do
      // not know whether the radio is on.
      return central.adapterState
    case .allowedAlways:
      return central.adapterState
    @unknown default:
      return central.adapterState
    }
  }

  /// Apple platforms have no permission request API: instantiating a manager
  /// is what shows the prompt, and the answer arrives as a state change.
  func requestPermissions(completion: @escaping (BlePermissionState) -> Void) {
    switch CBManager.authorization {
    case .allowedAlways:
      completion(.granted)
      return
    case .denied, .restricted:
      completion(.permanentlyDenied)
      return
    default:
      break
    }

    central.ensureManager(restoreIdentifier: nil)
    central.awaitState(timeout: 30) { _ in
      switch CBManager.authorization {
      case .allowedAlways: completion(.granted)
      case .denied, .restricted: completion(.permanentlyDenied)
      default: completion(.denied)
      }
    }
  }

  /// Idempotent by contract: Dart restarts on lifecycle and adapter changes.
  func start(config: BleConfig) throws {
    switch CBManager.authorization {
    case .denied, .restricted:
      throw BleTransportError.permissionDenied("Bluetooth permission was denied")
    default:
      break
    }
    // Only refuse when we actually know the radio is off. On the very first
    // call the state is still unknown, and the truthful answer then is to
    // start and report `poweredOff` on the event stream if that is what it
    // turns out to be.
    if central.adapterState == .poweredOff {
      throw BleTransportError.bluetoothOff("Bluetooth is switched off")
    }
    if central.adapterState == .unsupported {
      throw BleTransportError.unsupported("this device has no usable BLE radio")
    }

    desiredConfig = config

    // Peripheral first: a peer that discovers us mid-handshake should find a
    // GATT server that is already able to answer.
    peripheral.start(config: config)
    central.start(config: config)
  }

  func stop() {
    desiredConfig = nil
    central.stop()
    peripheral.stop()

    // The controllers drop their own links, but anything still registered
    // here would otherwise be invisible garbage to Dart.
    for link in registry.clear() {
      events.linkDown(link.linkId, reason: "transport stopped")
    }
  }

  func send(linkId: String, frame: Data, completion: @escaping (Error?) -> Void) {
    guard let link = registry.link(id: linkId) else {
      completion(BleTransportError.unknownLink("no live link \(linkId)"))
      return
    }
    switch link.role {
    case .central:
      central.write(link: link, frame: frame, completion: completion)
    case .peripheral:
      peripheral.notify(link: link, frame: frame, completion: completion)
    }
  }

  func disconnect(linkId: String) {
    guard let link = registry.link(id: linkId) else { return }
    switch link.role {
    case .central: central.disconnect(link: link)
    case .peripheral: peripheral.disconnect(link: link)
    }
  }

  func links() -> [BleLink] {
    registry.all().map { $0.toPigeon() }
  }
}
