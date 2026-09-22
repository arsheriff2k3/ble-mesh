import CoreBluetooth
import Foundation

/// One physical connection.
///
/// Deliberately *not* a peer: the same device can hold two links at once (we
/// connected out, they connected in). Collapsing links into peer identities is
/// protocol-layer work in Dart, because only Dart has seen the ANNOUNCE.
final class MeshLink {
  static let defaultMaxFrameSize: Int64 = 20

  let linkId: String
  let role: BleLinkRole
  let remoteId: String
  let connectedAtMs: Int64

  var maxFrameSize: Int64 = MeshLink.defaultMaxFrameSize
  var rssi: Int64?

  /// Central role: the peer we connected to, and the characteristic we write.
  var peripheral: CBPeripheral?
  var characteristic: CBCharacteristic?

  /// Peripheral role: the peer that connected to us and subscribed.
  var central: CBCentral?

  init(role: BleLinkRole, remoteId: String) {
    self.linkId = MeshLink.id(for: role, remoteId: remoteId)
    self.role = role
    self.remoteId = remoteId
    self.connectedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
  }

  func toPigeon() -> BleLink {
    BleLink(
      linkId: linkId,
      role: role,
      remoteId: remoteId,
      maxFrameSize: maxFrameSize,
      connectedAtMs: connectedAtMs,
      rssi: rssi
    )
  }

  static func id(for role: BleLinkRole, remoteId: String) -> String {
    switch role {
    case .central: return "c:\(remoteId)"
    case .peripheral: return "p:\(remoteId)"
    }
  }
}

/// Main-queue-only map of live links.
final class LinkRegistry {
  private var links: [String: MeshLink] = [:]
  private var order: [String] = []

  var count: Int { links.count }

  func all() -> [MeshLink] { order.compactMap { links[$0] } }

  func link(id: String) -> MeshLink? { links[id] }

  func link(role: BleLinkRole, remoteId: String) -> MeshLink? {
    links[MeshLink.id(for: role, remoteId: remoteId)]
  }

  func put(_ link: MeshLink) {
    if links[link.linkId] == nil { order.append(link.linkId) }
    links[link.linkId] = link
  }

  @discardableResult
  func remove(id: String) -> MeshLink? {
    order.removeAll { $0 == id }
    return links.removeValue(forKey: id)
  }

  func clear() -> [MeshLink] {
    let snapshot = all()
    links.removeAll()
    order.removeAll()
    return snapshot
  }
}
