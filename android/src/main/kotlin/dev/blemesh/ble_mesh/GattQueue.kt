package dev.blemesh.ble_mesh

import android.os.Handler
import android.util.Log

/** Raised when a queued GATT operation fails or never reports back. */
class GattOperationException(
    message: String
) : Exception(message)

/**
 * Serializes GATT operations for one connection.
 *
 * Android allows exactly one outstanding GATT operation per connection. Issue
 * a second one and it is silently dropped — no exception, no callback, just a
 * write that never happened. Every MTU request, descriptor write, and
 * characteristic write therefore goes through here, and the next one starts
 * only when the previous one's callback arrives.
 *
 * Operations that never call back are failed by a timeout, because a wedged
 * queue is indistinguishable from a dead link from Dart's point of view and
 * the mesh must be able to route around it.
 */
class GattQueue(
    private val handler: Handler,
    private val label: String,
    private val timeoutMs: Long = DEFAULT_TIMEOUT_MS
) {
    private class Operation(
        val name: String,
        val start: () -> Boolean,
        val done: (Throwable?) -> Unit
    )

    private val queue = ArrayDeque<Operation>()
    private var active: Operation? = null
    private var timedOut: Runnable? = null

    /**
     * [start] issues the platform call and returns false if the platform
     * refused it outright; [done] is invoked exactly once, with null on
     * success.
     */
    fun enqueue(
        name: String,
        start: () -> Boolean,
        done: (Throwable?) -> Unit
    ) {
        queue.addLast(Operation(name, start, done))
        pump()
    }

    /** Called from the GATT callback that corresponds to the active operation. */
    fun complete(error: Throwable? = null) {
        val operation = active ?: return
        active = null
        timedOut?.let { handler.removeCallbacks(it) }
        timedOut = null
        try {
            operation.done(error)
        } catch (throwable: Throwable) {
            Log.e(TAG, "$label: completion handler for ${operation.name} threw", throwable)
        }
        pump()
    }

    fun cancelAll(reason: String) {
        val error = GattOperationException(reason)
        // Drain the queue *before* completing the active operation: otherwise
        // `complete` pumps the next one back into flight, timeout and all,
        // while we are trying to shut down.
        val abandoned = queue.toList()
        queue.clear()
        complete(error)
        abandoned.forEach { it.done(error) }
    }

    private fun pump() {
        if (active != null) return
        val next = queue.removeFirstOrNull() ?: return
        active = next

        val timeout =
            Runnable {
                Log.w(TAG, "$label: ${next.name} timed out after ${timeoutMs}ms")
                complete(GattOperationException("${next.name} timed out"))
            }
        timedOut = timeout
        handler.postDelayed(timeout, timeoutMs)

        val accepted =
            try {
                next.start()
            } catch (throwable: Throwable) {
                Log.e(TAG, "$label: ${next.name} threw on start", throwable)
                false
            }
        if (!accepted) {
            complete(GattOperationException("${next.name} was refused by the platform"))
        }
    }

    private companion object {
        const val TAG = "BleMesh"
        const val DEFAULT_TIMEOUT_MS = 10_000L
    }
}
