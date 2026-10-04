import CoreBluetooth
import Foundation

/// The advertising / GATT-server half of the mesh.
///
/// A peer that finds our advertisement connects in and subscribes to the mesh
/// characteristic; from then on we push frames to it as notifications and it
/// pushes frames to us as writes. Main queue only, same as the central side.
final class PeripheralController: NSObject {
  typealias Completion = (Error?) -> Void

  private let registry: LinkRegistry
  private let events: BleEventBus

  private var manager: CBPeripheralManager?
  private var characteristic: CBMutableCharacteristic?
  private var config: BleConfig?
  private var serviceUUID: CBUUID?
  private var characteristicUUID: CBUUID?

  private var running = false
  private var serviceAdded = false
  private var serviceAdding = false

  /// One FIFO across all subscribers on purpose: `updateValue` returning false
  /// means the shared transmit queue is full, not that one central is slow.
  private let outbound = PendingFrameQueue<CBCentral>()

  init(registry: LinkRegistry, events: BleEventBus) {
    self.registry = registry
    self.events = events
    super.init()
  }

  func start(config: BleConfig) {
    guard !running else { return }
    self.config = config
    serviceUUID = CBUUID(string: config.serviceUuid)
    characteristicUUID = CBUUID(string: config.characteristicUuid)
    running = true

    if manager == nil {
      var options: [String: Any] = [:]
      if config.enableBackground {
        options[CBPeripheralManagerOptionRestoreIdentifierKey] = "blemesh.peripheral"
      }
      manager = CBPeripheralManager(delegate: self, queue: DispatchQueue.main, options: options)
    } else if manager?.state == .poweredOn {
      publish()
    }
  }

  func stop() {
    running = false
    manager?.stopAdvertising()
    manager?.removeAllServices()
    serviceAdded = false
    serviceAdding = false
    characteristic = nil
    failAllQueued(reason: "transport stopped")
    dropAllLinks(reason: "transport stopped")
  }

  func notify(link: MeshLink, frame: Data, completion: @escaping Completion) {
    guard running, serviceAdded, manager?.state == .poweredOn, characteristic != nil else {
      completion(BleTransportError.notReady("GATT server is not running"))
      return
    }
    guard let central = link.central else {
      completion(BleTransportError.notReady("link \(link.linkId) has no subscriber"))
      return
    }
    guard Int64(frame.count) <= link.maxFrameSize else {
      completion(
        BleTransportError.frameTooLarge(
          "frame of \(frame.count)B exceeds maxFrameSize \(link.maxFrameSize) on \(link.linkId)"
        )
      )
      return
    }
    outbound.append(peer: central, data: frame, completion: completion)
    pump()
  }

  /// CoreBluetooth offers no way to hang up on a specific subscriber, so the
  /// best we can do is forget the link and stop feeding it.
  func disconnect(link: MeshLink) {
    dropLink(remoteId: link.remoteId, reason: "disconnect requested")
  }

  func dropAllLinks(reason: String) {
    failAllQueued(reason: reason)
    for link in registry.all() where link.role == .peripheral {
      registry.remove(id: link.linkId)
      events.linkDown(link.linkId, reason: reason)
    }
  }

  // ------------------------------------------------------------------ internals

  private func publish() {
    guard running, let manager, manager.state == .poweredOn,
      let serviceUUID, let characteristicUUID, let config
    else { return }

    if !serviceAdded {
      guard !serviceAdding else { return }
      // No CCCD here: CoreBluetooth manages the client configuration
      // descriptor itself and adding one explicitly is an exception.
      let mesh = CBMutableCharacteristic(
        type: characteristicUUID,
        properties: [.write, .writeWithoutResponse, .notify],
        value: nil,
        permissions: [.writeable]
      )
      let service = CBMutableService(type: serviceUUID, primary: true)
      service.characteristics = [mesh]
      characteristic = mesh
      serviceAdding = true
      manager.add(service)
      return
    }

    if !manager.isAdvertising {
      // iOS accepts only these two advertisement keys, and truncates the name
      // aggressively; anything richer has to wait for the post-connect
      // ANNOUNCE.
      manager.startAdvertising([
        CBAdvertisementDataServiceUUIDsKey: [serviceUUID],
        CBAdvertisementDataLocalNameKey: config.advertisedName,
      ])
    }
  }

  private func pump() {
    guard running, serviceAdded, let manager, manager.state == .poweredOn,
      let characteristic else { return }
    outbound.drain { central, data in
      manager.updateValue(data, for: characteristic, onSubscribedCentrals: [central])
    }
  }

  private func failAllQueued(reason: String) {
    outbound.failAll(error: BleTransportError.writeFailed(reason))
  }

  private func registerLink(central: CBCentral) {
    guard running, serviceAdded, let config else { return }
    let remoteId = central.identifier.uuidString
    if registry.link(role: .peripheral, remoteId: remoteId) != nil { return }
    if Int64(registry.count) >= config.maxConcurrentLinks { return }

    let link = MeshLink(role: .peripheral, remoteId: remoteId)
    link.central = central
    link.maxFrameSize = Int64(central.maximumUpdateValueLength)
    registry.put(link)
    events.linkUp(link.toPigeon())
  }

  private func dropLink(remoteId: String, reason: String) {
    outbound.fail(
      where: { $0.identifier.uuidString == remoteId },
      error: BleTransportError.writeFailed(reason)
    )
    if let link = registry.remove(id: MeshLink.id(for: .peripheral, remoteId: remoteId)) {
      events.linkDown(link.linkId, reason: reason)
    }
  }
}

// MARK: - CBPeripheralManagerDelegate

extension PeripheralController: CBPeripheralManagerDelegate {
  func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
    switch peripheral.state {
    case .poweredOn:
      publish()
    case .unsupported:
      events.error(
        .unsupported,
        message: "this device cannot advertise; it can receive but not be discovered"
      )
      dropAllLinks(reason: "advertising unavailable")
    default:
      serviceAdded = false
      serviceAdding = false
      characteristic = nil
      failAllQueued(reason: "bluetooth unavailable")
      dropAllLinks(reason: "bluetooth unavailable")
    }
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager,
    didAdd service: CBService,
    error: Error?
  ) {
    guard running, serviceAdding, service.uuid == serviceUUID else { return }
    serviceAdding = false
    if let error {
      serviceAdded = false
      events.error(.internalError, message: "adding the mesh service failed: \(error.localizedDescription)")
      return
    }
    serviceAdded = true
    publish()
  }

  func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
    if let error {
      events.error(
        .advertisingFailed,
        message: "advertising failed: \(error.localizedDescription)"
      )
    }
  }

  /// Subscription, not connection, is what makes a link usable in both
  /// directions — a connected-but-unsubscribed peer could never hear a reply.
  func peripheralManager(
    _ peripheral: CBPeripheralManager,
    central: CBCentral,
    didSubscribeTo characteristic: CBCharacteristic
  ) {
    guard characteristic.uuid == characteristicUUID else { return }
    registerLink(central: central)
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager,
    central: CBCentral,
    didUnsubscribeFrom characteristic: CBCharacteristic
  ) {
    guard characteristic.uuid == characteristicUUID else { return }
    dropLink(remoteId: central.identifier.uuidString, reason: "peer unsubscribed")
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager,
    didReceiveWrite requests: [CBATTRequest]
  ) {
    for request in requests {
      guard running, serviceAdded, request.characteristic.uuid == characteristicUUID,
        request.offset == 0, let value = request.value else { continue }
      let remoteId = request.central.identifier.uuidString
      guard let link = registry.link(role: .peripheral, remoteId: remoteId) else {
        // Legal but useless to us: with no subscription we could not reply.
        NSLog("%@", "[ble_mesh] frame from unsubscribed peer \(remoteId) dropped")
        continue
      }
      events.frame(link.linkId, data: value)
    }
    if let first = requests.first {
      peripheral.respond(to: first, withResult: .success)
    }
  }

  func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
    pump()
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager,
    willRestoreState dict: [String: Any]
  ) {
    guard
      let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService]
    else { return }
    // Re-adopt the restored service so a background relaunch does not end up
    // advertising a second copy of it.
    for service in services where service.uuid == serviceUUID {
      serviceAdded = true
      serviceAdding = false
      characteristic =
        service.characteristics?.first { $0.uuid == characteristicUUID } as? CBMutableCharacteristic
    }
  }
}
