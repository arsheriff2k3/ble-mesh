import Foundation

#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#endif

/// The single ordered event channel back to Dart.
///
/// Everything is emitted on the main queue in the order it happened, so a
/// frame can never overtake the `linkUp` for its own link. Events raised
/// before Dart subscribes are buffered rather than dropped — adapter state and
/// the first links routinely land during start-up.
final class BleEventBus: EventsStreamHandler {
  private var sink: PigeonEventSink<BleEvent>?
  private var pending: [BleEvent] = []
  private let maxPending = 256

  override func onListen(withArguments arguments: Any?, sink: PigeonEventSink<BleEvent>) {
    self.sink = sink
    let buffered = pending
    pending.removeAll()
    for event in buffered {
      sink.success(event)
    }
  }

  override func onCancel(withArguments arguments: Any?) {
    sink = nil
  }

  func adapterState(_ state: BleAdapterState) {
    emit(BleEvent(kind: .adapterState, adapterState: state))
  }

  func linkUp(_ link: BleLink) {
    emit(BleEvent(kind: .linkUp, link: link))
  }

  func linkDown(_ linkId: String, reason: String?) {
    emit(BleEvent(kind: .linkDown, linkId: linkId, message: reason))
  }

  func frame(_ linkId: String, data: Data) {
    emit(
      BleEvent(
        kind: .frame,
        linkId: linkId,
        frame: FlutterStandardTypedData(bytes: data)
      )
    )
  }

  func error(_ code: BleErrorCode, message: String, linkId: String? = nil) {
    emit(BleEvent(kind: .error, linkId: linkId, errorCode: code, message: message))
  }

  func dispose() {
    sink = nil
    pending.removeAll()
  }

  private func emit(_ event: BleEvent) {
    if Thread.isMainThread {
      deliver(event)
    } else {
      DispatchQueue.main.async { self.deliver(event) }
    }
  }

  private func deliver(_ event: BleEvent) {
    guard let sink else {
      // Drop the oldest rather than grow without bound: if Dart never
      // subscribes, stale link events are worthless anyway.
      if pending.count >= maxPending { pending.removeFirst() }
      pending.append(event)
      return
    }
    sink.success(event)
  }
}
