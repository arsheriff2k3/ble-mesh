import Foundation

/// Owns each notification completion until accepted by CoreBluetooth or failed.
/// Main-queue only. Detach cancelled work before calling back to allow re-entry.
final class PendingFrameQueue<Peer> {
  typealias Completion = (Error?) -> Void
  private struct Item {
    let peer: Peer
    let data: Data
    let completion: Completion
  }
  private var items: [Item] = []
  private var draining = false

  func append(peer: Peer, data: Data, completion: @escaping Completion) {
    items.append(Item(peer: peer, data: data, completion: completion))
  }

  func drain(accept: (Peer, Data) -> Bool) {
    guard !draining else { return }
    draining = true
    defer { draining = false }
    while let next = items.first {
      guard accept(next.peer, next.data) else { return }
      items.removeFirst()
      next.completion(nil)
    }
  }

  func fail(where matches: (Peer) -> Bool, error: Error) {
    let cancelled = items.filter { matches($0.peer) }
    items.removeAll { matches($0.peer) }
    for item in cancelled { item.completion(error) }
  }

  func failAll(error: Error) {
    let cancelled = items
    items.removeAll()
    for item in cancelled { item.completion(error) }
  }
}
