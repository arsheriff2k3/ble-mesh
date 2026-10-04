package dev.blemesh.ble_mesh

import android.os.Handler
import org.junit.jupiter.api.Test
import org.mockito.Mockito.mock
import kotlin.test.assertEquals

class GattQueueTest {
    @Test
    fun duplicateMtuCallbackCannotCompleteServiceDiscovery() {
        val queue = GattQueue(mock(Handler::class.java), "test")
        val completed = mutableListOf<String>()
        queue.enqueue("requestMtu", { true }) {
            completed.add("mtu")
            queue.enqueue("discoverServices", { true }) { completed.add("discovery") }
        }
        queue.complete(expectedName = "requestMtu")
        queue.complete(expectedName = "requestMtu")
        assertEquals(listOf("mtu"), completed)
        queue.complete(expectedName = "discoverServices")
        assertEquals(listOf("mtu", "discovery"), completed)
    }

    @Test
    fun unrelatedCallbackCannotCompleteAnOutstandingWrite() {
        val queue = GattQueue(mock(Handler::class.java), "test")
        var completed = 0
        queue.enqueue("write", { true }) { completed++ }
        queue.complete(expectedName = "writeCccd")
        queue.complete(expectedName = "requestMtu")
        assertEquals(0, completed)
        queue.complete(expectedName = "write")
        assertEquals(1, completed)
    }
}
