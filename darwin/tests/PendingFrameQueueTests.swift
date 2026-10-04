import Foundation

@main
struct PendingFrameQueueTests {
  static func main() {
    let queue = PendingFrameQueue<String>()
    var results: [String] = []
    queue.append(peer: "a", data: Data([1])) { error in
      precondition(error == nil)
      results.append("a")
      // Completion callbacks may enqueue and request another drain.
      queue.append(peer: "c", data: Data([3])) { error in
        precondition(error == nil)
        results.append("c")
      }
      queue.drain { _, _ in true }
    }
    queue.append(peer: "b", data: Data([2])) { error in
      precondition(error == nil)
      results.append("b")
    }
    queue.drain { _, _ in false }
    precondition(results.isEmpty, "backpressure must retain completions")
    var sent: [UInt8] = []
    queue.drain { _, data in
      sent.append(data[0])
      return true
    }
    precondition(sent == [1, 2, 3] && results == ["a", "b", "c"], "FIFO despite re-entry")

    let error = NSError(domain: "test.disconnect", code: 1)
    var failed = 0
    var succeeded = 0
    for peer in ["a", "b", "a"] {
      queue.append(peer: peer, data: Data([4])) { completionError in
        if peer == "a" {
          precondition(completionError != nil)
          failed += 1
        } else {
          precondition(completionError == nil)
          succeeded += 1
        }
      }
    }
    queue.fail(where: { $0 == "a" }, error: error)
    precondition(failed == 2 && succeeded == 0, "disconnect must finish every affected send")
    queue.drain { _, _ in true }
    precondition(succeeded == 1, "other subscribers remain usable")
    queue.append(peer: "d", data: Data([5])) { completionError in
      precondition(completionError != nil)
      failed += 1
    }
    queue.failAll(error: error)
    queue.failAll(error: error)
    queue.drain { _, _ in true }
    precondition(failed == 3, "shutdown completes a send exactly once")
    print("PASS: backpressure, FIFO/re-entry, peer disconnect, shutdown completions")
  }
}
