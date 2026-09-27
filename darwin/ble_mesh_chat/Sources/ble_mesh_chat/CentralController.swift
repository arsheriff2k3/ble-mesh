import CoreBluetooth
import Foundation

/// The scanning / GATT-client half of the mesh.
///
/// CoreBluetooth is driven on the main queue and every piece of state here is
/// main-queue-only, which is what lets the whole controller stay lock-free.
final class CentralController: NSObject {
  typealias Completion = (Error?) -> Void

  private let registry: LinkRegistry
  private let events: BleEventBus

  private var manager: CBCentralManager?
  private var config: BleConfig?
  private var serviceUUID: CBUUID?
  private var characteristicUUID: CBUUID?

  private var running = false
  private var scanning = false

  /// CoreBluetooth deallocates a `CBPeripheral` we do not hold, and the link
  /// then dies mid-connection with no callback at all.
  private var retained: [UUID: CBPeripheral] = [:]
  private var connecting: Set<UUID> = []
  private var failures: [UUID: Int] = [:]
  private var cooldownUntil: [UUID: Date] = [:]
  private var writeQueues: [UUID: [(data: Data, completion: Completion)]] = [:]
  private var connectTimers: [UUID: DispatchWorkItem] = [:]
  private var scanTimer: DispatchWorkItem?

  /// Resumed on the next state callback, for the permission prompt flow.
  private var stateWaiters: [(BleAdapterState) -> Void] = []

  /// Called whenever the radio's state changes, so the controller above can
  /// mirror it to Dart and tear the peripheral role down in step.
  var onAdapterStateChange: ((BleAdapterState) -> Void)?

  init(registry: LinkRegistry, events: BleEventBus) {
    self.registry = registry
    self.events = events
    super.init()
  }

  // ------------------------------------------------------------------ lifecycle

  var adapterState: BleAdapterState {
    guard let manager else { return .unknown }
    return CentralController.map(manager.state)
  }

  /// Creating the manager is what triggers the system Bluetooth prompt, so
  /// this doubles as the permission request on Apple platforms — there is no
  /// separate request API.
  func ensureManager(restoreIdentifier: String?) {
    guard manager == nil else { return }
    var options: [String: Any] = [CBCentralManagerOptionShowPowerAlertKey: true]
    if let restoreIdentifier {
      options[CBCentralManagerOptionRestoreIdentifierKey] = restoreIdentifier
    }
    manager = CBCentralManager(delegate: self, queue: DispatchQueue.main, options: options)
  }

  /// Waits for the first definite state, so `requestPermissions` can answer
  /// after the user has actually responded to the prompt.
  func awaitState(timeout: TimeInterval, completion: @escaping (BleAdapterState) -> Void) {
    let current = adapterState
    if current != .unknown {
      completion(current)
      return
    }
    var settled = false
    stateWaiters.append { state in
      guard !settled else { return }
      settled = true
      completion(state)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
      guard !settled else { return }
      settled = true
      completion(self?.adapterState ?? .unknown)
    }
  }

  func start(config: BleConfig) {
    guard !running else { return }
    self.config = config
    serviceUUID = CBUUID(string: config.serviceUuid)
    characteristicUUID = CBUUID(string: config.characteristicUuid)
    running = true
    ensureManager(restoreIdentifier: config.enableBackground ? "blemesh.central" : nil)
    if manager?.state == .poweredOn { startScanWindow() }
  }

  func stop() {
    running = false
    stopScan()
    scanTimer?.cancel()
    scanTimer = nil

    connectTimers.values.forEach { $0.cancel() }
    connectTimers.removeAll()

    for peripheral in retained.values {
      manager?.cancelPeripheralConnection(peripheral)
    }
    retained.removeAll()
    connecting.removeAll()
    failures.removeAll()
    cooldownUntil.removeAll()
    failAllQueuedWrites(reason: "transport stopped")
  }

  func write(link: MeshLink, frame: Data, completion: @escaping Completion) {
    guard let peripheral = link.peripheral, link.characteristic != nil else {
      completion(BleTransportError.notReady("link \(link.linkId) has no GATT client"))
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
    writeQueues[peripheral.identifier, default: []].append((data: frame, completion: completion))
    pumpWrites(for: peripheral)
  }

  func disconnect(link: MeshLink) {
    guard let peripheral = link.peripheral else { return }
    manager?.cancelPeripheralConnection(peripheral)
  }

  // ------------------------------------------------------------------- scanning

  /// Duty-cycled rather than continuous: a permanent scan is the single
  /// largest battery draw available to an app, and a flat phone relays
  /// nothing.
  private func startScanWindow() {
    guard running, let manager, manager.state == .poweredOn,
      let serviceUUID, let config
    else { return }

    if !scanning {
      // Background scanning ignores a nil service filter entirely, so the
      // filter is not an optimisation — it is the only thing that works.
      manager.scanForPeripherals(
        withServices: [serviceUUID],
        options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
      )
      scanning = true
    }

    let rest = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.stopScan()
      let resume = DispatchWorkItem { [weak self] in self?.startScanWindow() }
      self.scanTimer = resume
      DispatchQueue.main.asyncAfter(
        deadline: .now() + Double(config.scanRestMs) / 1000,
        execute: resume
      )
    }
    scanTimer = rest
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Double(config.scanWindowMs) / 1000,
      execute: rest
    )
  }

  private func stopScan() {
    guard scanning else { return }
    scanning = false
    manager?.stopScan()
  }

  private func consider(peripheral: CBPeripheral, rssi: NSNumber) {
    guard running, let config, let manager else { return }
    let id = peripheral.identifier

    if let existing = registry.link(role: .central, remoteId: id.uuidString) {
      existing.rssi = rssi.int64Value
      return
    }
    if connecting.contains(id) { return }
    if let until = cooldownUntil[id] {
      if Date() < until { return }
      cooldownUntil.removeValue(forKey: id)
    }
    // The cap counts every link, inbound included: the radio, not the role, is
    // the scarce resource.
    if Int64(registry.count) >= config.maxConcurrentLinks { return }

    connecting.insert(id)
    retained[id] = peripheral
    manager.connect(peripheral, options: nil)
    scheduleConnectTimeout(peripheral, timeoutMs: config.connectionTimeoutMs)
  }

  private func scheduleConnectTimeout(_ peripheral: CBPeripheral, timeoutMs: Int64) {
    let id = peripheral.identifier
    let timeout = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.connectTimers.removeValue(forKey: id)
      if self.registry.link(role: .central, remoteId: id.uuidString) != nil { return }
      self.manager?.cancelPeripheralConnection(peripheral)
      self.teardown(peripheral, reason: "connection timed out", countAsFailure: true)
    }
    connectTimers[id] = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + Double(timeoutMs) / 1000, execute: timeout)
  }

  // --------------------------------------------------------------------- writes

  /// iOS gives no completion callback for writes without response. The honest
  /// definition of "sent" available to us is "the stack accepted it", which is
  /// exactly what `canSendWriteWithoutResponse` gates.
  private func pumpWrites(for peripheral: CBPeripheral) {
    let id = peripheral.identifier
    guard let link = registry.link(role: .central, remoteId: id.uuidString),
      let characteristic = link.characteristic
    else {
      failQueuedWrites(for: id, reason: "link is gone")
      return
    }

    while let queue = writeQueues[id], !queue.isEmpty {
      guard peripheral.canSendWriteWithoutResponse else { return }
      var remaining = queue
      let item = remaining.removeFirst()
      writeQueues[id] = remaining
      peripheral.writeValue(item.data, for: characteristic, type: .withoutResponse)
      item.completion(nil)
    }
  }

  private func failQueuedWrites(for id: UUID, reason: String) {
    guard let queue = writeQueues.removeValue(forKey: id) else { return }
    for item in queue {
      item.completion(BleTransportError.writeFailed(reason))
    }
  }

  private func failAllQueuedWrites(reason: String) {
    let ids = Array(writeQueues.keys)
    for id in ids { failQueuedWrites(for: id, reason: reason) }
  }

  // ------------------------------------------------------------------ teardown

  private func teardown(_ peripheral: CBPeripheral, reason: String?, countAsFailure: Bool) {
    let id = peripheral.identifier
    connecting.remove(id)
    connectTimers.removeValue(forKey: id)?.cancel()
    retained.removeValue(forKey: id)
    failQueuedWrites(for: id, reason: reason ?? "link closed")

    if let link = registry.remove(id: MeshLink.id(for: .central, remoteId: id.uuidString)) {
      events.linkDown(link.linkId, reason: reason)
    }
    if countAsFailure { noteFailure(id, reason: reason) }
  }

  private func noteFailure(_ id: UUID, reason: String?) {
    let count = (failures[id] ?? 0) + 1
    failures[id] = count
    let exponent = min(count - 1, 6)
    let backoff = min(0.5 * pow(2.0, Double(exponent)), 30.0)
    let jitter = Double.random(in: 0...(backoff / 4))
    cooldownUntil[id] = Date().addingTimeInterval(backoff + jitter)
    NSLog(
      "%@",
      "[ble_mesh] peer \(id.uuidString) failed (\(count)): \(reason ?? "unknown")"
    )
  }

  func dropAllLinks(reason: String) {
    for link in registry.all() where link.role == .central {
      registry.remove(id: link.linkId)
      events.linkDown(link.linkId, reason: reason)
    }
    retained.removeAll()
    connecting.removeAll()
    failAllQueuedWrites(reason: reason)
  }

  static func map(_ state: CBManagerState) -> BleAdapterState {
    switch state {
    case .poweredOn: return .poweredOn
    case .poweredOff: return .poweredOff
    case .unauthorized: return .unauthorized
    case .unsupported: return .unsupported
    case .resetting, .unknown: return .unknown
    @unknown default: return .unknown
    }
  }
}

// MARK: - CBCentralManagerDelegate

extension CentralController: CBCentralManagerDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    let state = CentralController.map(central.state)

    let waiters = stateWaiters
    stateWaiters.removeAll()
    for waiter in waiters { waiter(state) }

    onAdapterStateChange?(state)

    switch central.state {
    case .poweredOn:
      if running { startScanWindow() }
    default:
      scanning = false
      dropAllLinks(reason: "bluetooth unavailable (\(state))")
    }
  }

  func centralManager(
    _ central: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {
    consider(peripheral: peripheral, rssi: RSSI)
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    guard let serviceUUID else { return }
    peripheral.delegate = self
    peripheral.discoverServices([serviceUUID])
  }

  func centralManager(
    _ central: CBCentralManager,
    didFailToConnect peripheral: CBPeripheral,
    error: Error?
  ) {
    teardown(
      peripheral,
      reason: error?.localizedDescription ?? "failed to connect",
      countAsFailure: true
    )
  }

  func centralManager(
    _ central: CBCentralManager,
    didDisconnectPeripheral peripheral: CBPeripheral,
    error: Error?
  ) {
    teardown(
      peripheral,
      reason: error?.localizedDescription ?? "peer disconnected",
      countAsFailure: error != nil
    )
  }

  /// Background relaunch hands the peripherals back rather than rediscovering
  /// them. Full relaunch support is not implemented; re-adopting what the system
  /// gives us is cheap and stops the links from being orphaned.
  func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
    guard let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]
    else { return }
    for peripheral in peripherals {
      retained[peripheral.identifier] = peripheral
      peripheral.delegate = self
      if peripheral.state == .connected, let serviceUUID {
        peripheral.discoverServices([serviceUUID])
      }
    }
  }
}

// MARK: - CBPeripheralDelegate

extension CentralController: CBPeripheralDelegate {
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard error == nil, let serviceUUID, let characteristicUUID else {
      teardown(
        peripheral,
        reason: error?.localizedDescription ?? "service discovery failed",
        countAsFailure: true
      )
      return
    }
    guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
      teardown(peripheral, reason: "peer does not expose the mesh service", countAsFailure: false)
      return
    }
    peripheral.discoverCharacteristics([characteristicUUID], for: service)
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didDiscoverCharacteristicsFor service: CBService,
    error: Error?
  ) {
    guard error == nil, let characteristicUUID,
      let characteristic = service.characteristics?.first(where: { $0.uuid == characteristicUUID })
    else {
      teardown(
        peripheral,
        reason: error?.localizedDescription ?? "mesh characteristic missing",
        countAsFailure: false
      )
      return
    }
    peripheral.setNotifyValue(true, for: characteristic)
  }

  /// Only once notifications are on is the link usable in both directions, so
  /// this — not `didConnect` — is where it is reported to Dart.
  func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateNotificationStateFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    guard error == nil, characteristic.isNotifying else {
      teardown(
        peripheral,
        reason: error?.localizedDescription ?? "could not subscribe",
        countAsFailure: true
      )
      return
    }
    let id = peripheral.identifier
    connecting.remove(id)
    connectTimers.removeValue(forKey: id)?.cancel()
    failures.removeValue(forKey: id)
    cooldownUntil.removeValue(forKey: id)

    let link = MeshLink(role: .central, remoteId: id.uuidString)
    link.peripheral = peripheral
    link.characteristic = characteristic
    link.maxFrameSize = Int64(peripheral.maximumWriteValueLength(for: .withoutResponse))
    registry.put(link)

    peripheral.readRSSI()
    events.linkUp(link.toPigeon())
    pumpWrites(for: peripheral)
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    guard error == nil, let value = characteristic.value else { return }
    guard
      let link = registry.link(role: .central, remoteId: peripheral.identifier.uuidString)
    else { return }
    events.frame(link.linkId, data: value)
  }

  func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
    pumpWrites(for: peripheral)
  }

  func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
    guard error == nil else { return }
    registry.link(role: .central, remoteId: peripheral.identifier.uuidString)?.rssi =
      RSSI.int64Value
  }
}
