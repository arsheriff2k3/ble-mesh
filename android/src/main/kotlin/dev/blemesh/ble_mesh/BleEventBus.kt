package dev.blemesh.ble_mesh

import android.os.Handler
import android.os.Looper

/**
 * The single ordered event channel back to Dart.
 *
 * Everything is delivered on the main thread, in the order it was emitted, so
 * a frame can never overtake the `linkUp` for its own link. Events raised
 * before Dart subscribes are buffered rather than dropped — the adapter state
 * and the first links often land during start-up.
 */
class BleEventBus : EventsStreamHandler() {
    private val main = Handler(Looper.getMainLooper())
    private val pending = ArrayDeque<BleEvent>()
    private var sink: PigeonEventSink<BleEvent>? = null

    override fun onListen(
        p0: Any?,
        sink: PigeonEventSink<BleEvent>
    ) {
        this.sink = sink
        while (pending.isNotEmpty()) {
            sink.success(pending.removeFirst())
        }
    }

    override fun onCancel(p0: Any?) {
        sink = null
    }

    fun adapterState(state: BleAdapterState) =
        emit(BleEvent(kind = BleEventKind.ADAPTER_STATE, adapterState = state))

    fun linkUp(link: BleLink) = emit(BleEvent(kind = BleEventKind.LINK_UP, link = link))

    fun linkDown(
        linkId: String,
        reason: String?
    ) = emit(BleEvent(kind = BleEventKind.LINK_DOWN, linkId = linkId, message = reason))

    fun frame(
        linkId: String,
        data: ByteArray
    ) = emit(BleEvent(kind = BleEventKind.FRAME, linkId = linkId, frame = data))

    fun error(
        code: BleErrorCode,
        message: String,
        linkId: String? = null
    ) = emit(
        BleEvent(
            kind = BleEventKind.ERROR,
            errorCode = code,
            message = message,
            linkId = linkId
        )
    )

    private fun emit(event: BleEvent) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            deliver(event)
        } else {
            main.post { deliver(event) }
        }
    }

    private fun deliver(event: BleEvent) {
        val target = sink
        if (target == null) {
            // Drop the oldest rather than grow without bound: if Dart never
            // subscribes, stale link events are worthless anyway.
            if (pending.size >= MAX_PENDING) pending.removeFirst()
            pending.addLast(event)
            return
        }
        target.success(event)
    }

    fun dispose() {
        sink = null
        pending.clear()
    }

    private companion object {
        const val MAX_PENDING = 256
    }
}
