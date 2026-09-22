package dev.blemesh.ble_mesh

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.ParcelUuid
import android.os.SystemClock
import android.util.Log
import java.util.UUID
import kotlin.math.min
import kotlin.random.Random

/**
 * The scanning / GATT-client half of the mesh.
 *
 * Everything here runs on the main thread. GATT callbacks arrive on a binder
 * thread, so each one hops back via [handler] before touching any state.
 */
@SuppressLint("MissingPermission")
class CentralController(
    private val context: Context,
    private val adapter: BluetoothAdapter,
    private val registry: LinkRegistry,
    private val events: BleEventBus,
    private val handler: Handler
) {
    private var config: BleConfig? = null
    private var running = false
    private var scanning = false

    private lateinit var serviceUuid: UUID
    private lateinit var characteristicUuid: UUID

    /** Addresses with a connection attempt in flight. */
    private val connecting = mutableSetOf<String>()

    /** Consecutive failures per address, for the backoff ladder. */
    private val failures = mutableMapOf<String, Int>()

    /** Addresses we refuse to retry until this uptime millisecond. */
    private val cooldownUntil = mutableMapOf<String, Long>()

    private val gatts = mutableMapOf<String, BluetoothGatt>()
    private val queues = mutableMapOf<String, GattQueue>()
    private val connectTimeouts = mutableMapOf<String, Runnable>()

    fun start(config: BleConfig) {
        if (running) return
        this.config = config
        serviceUuid = UUID.fromString(config.serviceUuid)
        characteristicUuid = UUID.fromString(config.characteristicUuid)
        running = true
        startScanWindow()
    }

    fun stop() {
        running = false
        stopScan()
        handler.removeCallbacks(scanWindowElapsed)
        handler.removeCallbacks(scanRestElapsed)
        connectTimeouts.values.forEach { handler.removeCallbacks(it) }
        connectTimeouts.clear()

        gatts.values.forEach { gatt ->
            runCatching { gatt.disconnect() }
            runCatching { gatt.close() }
        }
        gatts.clear()
        queues.values.forEach { it.cancelAll("transport stopped") }
        queues.clear()
        connecting.clear()
        failures.clear()
        cooldownUntil.clear()
    }

    fun write(
        link: MeshLink,
        frame: ByteArray,
        done: (Throwable?) -> Unit
    ) {
        val gatt = link.gatt
        val characteristic = link.characteristic
        if (gatt == null || characteristic == null) {
            done(GattOperationException("link ${link.linkId} has no GATT client"))
            return
        }
        if (frame.size > link.maxFrameSize) {
            done(
                GattOperationException(
                    "frame of ${frame.size}B exceeds maxFrameSize ${link.maxFrameSize} on ${link.linkId}"
                )
            )
            return
        }
        queueFor(link.address).enqueue(
            name = "write",
            start = { issueWrite(gatt, characteristic, frame) },
            done = done
        )
    }

    fun disconnect(link: MeshLink) {
        gatts[link.address]?.let { runCatching { it.disconnect() } }
    }

    // ---------------------------------------------------------------- scanning

    private val scanWindowElapsed =
        Runnable {
            stopScan()
            config?.let { handler.postDelayed(scanRestElapsed, it.scanRestMs) }
        }

    private val scanRestElapsed = Runnable { startScanWindow() }

    /**
     * Android throttles an app to 5 `startScan` calls in any 30s window and
     * then silently stops delivering results, so the duty cycle has to stay
     * well clear of that. A full-time scan would also be the single largest
     * battery draw in the app.
     */
    private fun startScanWindow() {
        if (!running) return
        val current = config ?: return
        val scanner = adapter.bluetoothLeScanner
        if (scanner == null) {
            events.error(BleErrorCode.BLUETOOTH_OFF, "no scanner; adapter is off")
            return
        }
        if (!scanning) {
            val filters =
                listOf(
                    ScanFilter
                        .Builder()
                        .setServiceUuid(ParcelUuid(serviceUuid))
                        .build()
                )
            val settings =
                ScanSettings
                    .Builder()
                    .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
                    .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
                    .setMatchMode(ScanSettings.MATCH_MODE_AGGRESSIVE)
                    .setNumOfMatches(ScanSettings.MATCH_NUM_MAX_ADVERTISEMENT)
                    .setReportDelay(0)
                    .build()
            runCatching { scanner.startScan(filters, settings, scanCallback) }
                .onFailure {
                    events.error(BleErrorCode.SCAN_FAILED, "startScan threw: ${it.message}")
                    return
                }
            scanning = true
        }
        handler.postDelayed(scanWindowElapsed, current.scanWindowMs)
    }

    private fun stopScan() {
        if (!scanning) return
        scanning = false
        runCatching { adapter.bluetoothLeScanner?.stopScan(scanCallback) }
    }

    private val scanCallback =
        object : ScanCallback() {
            override fun onScanResult(
                callbackType: Int,
                result: ScanResult
            ) {
                handler.post { considerPeer(result) }
            }

            override fun onBatchScanResults(results: MutableList<ScanResult>) {
                handler.post { results.forEach { considerPeer(it) } }
            }

            override fun onScanFailed(errorCode: Int) {
                handler.post {
                    scanning = false
                    events.error(BleErrorCode.SCAN_FAILED, "scan failed with code $errorCode")
                }
            }
        }

    private fun considerPeer(result: ScanResult) {
        if (!running) return
        val current = config ?: return
        val address = result.device.address

        registry.find(BleLinkRole.CENTRAL, address)?.let { existing ->
            existing.rssi = result.rssi.toLong()
            return
        }
        if (address in connecting) return
        cooldownUntil[address]?.let { until ->
            if (SystemClock.elapsedRealtime() < until) return
            cooldownUntil.remove(address)
        }
        // The cap counts every link, inbound included: the radio, not the role,
        // is the scarce resource.
        if (registry.size >= current.maxConcurrentLinks) return

        connecting.add(address)
        val gatt =
            result.device.connectGatt(
                context,
                /* autoConnect = */ false,
                gattCallback,
                BluetoothDevice.TRANSPORT_LE
            )
        if (gatt == null) {
            connecting.remove(address)
            noteFailure(address, "connectGatt returned null")
            return
        }
        gatts[address] = gatt
        scheduleConnectTimeout(address, current.connectionTimeoutMs)
    }

    private fun scheduleConnectTimeout(
        address: String,
        timeoutMs: Long
    ) {
        val timeout =
            Runnable {
                connectTimeouts.remove(address)
                if (registry.find(BleLinkRole.CENTRAL, address) != null) return@Runnable
                Log.w(TAG, "connection to $address timed out")
                teardown(address, "connection timed out", countAsFailure = true)
            }
        connectTimeouts[address] = timeout
        handler.postDelayed(timeout, timeoutMs)
    }

    // ------------------------------------------------------------ gatt client

    private val gattCallback =
        object : BluetoothGattCallback() {
            override fun onConnectionStateChange(
                gatt: BluetoothGatt,
                status: Int,
                newState: Int
            ) {
                val address = gatt.device.address
                handler.post {
                    if (status != BluetoothGatt.GATT_SUCCESS ||
                        newState != BluetoothProfile.STATE_CONNECTED
                    ) {
                        teardown(
                            address,
                            "connection state $newState with status $status",
                            countAsFailure = status != BluetoothGatt.GATT_SUCCESS
                        )
                        return@post
                    }
                    negotiateMtu(gatt)
                }
            }

            override fun onMtuChanged(
                gatt: BluetoothGatt,
                mtu: Int,
                status: Int
            ) {
                val address = gatt.device.address
                handler.post {
                    val usable =
                        if (status == BluetoothGatt.GATT_SUCCESS) {
                            (mtu - ATT_HEADER_BYTES).toLong()
                        } else {
                            MeshLink.DEFAULT_MAX_FRAME_SIZE
                        }
                    pendingFrameSize[address] = usable
                    queueFor(address).complete()
                }
            }

            override fun onServicesDiscovered(
                gatt: BluetoothGatt,
                status: Int
            ) {
                handler.post {
                    queueFor(gatt.device.address).complete(
                        if (status == BluetoothGatt.GATT_SUCCESS) {
                            null
                        } else {
                            GattOperationException("service discovery failed with $status")
                        }
                    )
                }
            }

            override fun onDescriptorWrite(
                gatt: BluetoothGatt,
                descriptor: BluetoothGattDescriptor,
                status: Int
            ) {
                handler.post {
                    queueFor(gatt.device.address).complete(
                        if (status == BluetoothGatt.GATT_SUCCESS) {
                            null
                        } else {
                            GattOperationException("descriptor write failed with $status")
                        }
                    )
                }
            }

            override fun onCharacteristicWrite(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                status: Int
            ) {
                handler.post {
                    queueFor(gatt.device.address).complete(
                        if (status == BluetoothGatt.GATT_SUCCESS) {
                            null
                        } else {
                            GattOperationException("write failed with $status")
                        }
                    )
                }
            }

            // API 33+ delivers the value directly; below that it lives on the
            // characteristic and must be copied before we leave the callback.
            override fun onCharacteristicChanged(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                value: ByteArray
            ) {
                deliverInbound(gatt.device.address, value.copyOf())
            }

            @Deprecated("Superseded by the API 33 overload that passes the value")
            @Suppress("DEPRECATION")
            override fun onCharacteristicChanged(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic
            ) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) return
                val value = characteristic.value ?: return
                deliverInbound(gatt.device.address, value.copyOf())
            }

            override fun onReadRemoteRssi(
                gatt: BluetoothGatt,
                rssi: Int,
                status: Int
            ) {
                handler.post {
                    registry.find(BleLinkRole.CENTRAL, gatt.device.address)?.rssi = rssi.toLong()
                }
            }
        }

    private val pendingFrameSize = mutableMapOf<String, Long>()

    private fun deliverInbound(
        address: String,
        value: ByteArray
    ) {
        handler.post {
            val link = registry.find(BleLinkRole.CENTRAL, address) ?: return@post
            events.frame(link.linkId, value)
        }
    }

    /**
     * Connection bring-up, one queued step at a time: MTU, then discovery,
     * then notification subscription. Only when the CCCD write lands is the
     * link actually usable in both directions, so that is where we report it.
     */
    private fun negotiateMtu(gatt: BluetoothGatt) {
        val address = gatt.device.address
        val queue = queueFor(address)
        queue.enqueue(
            name = "requestMtu",
            start = { gatt.requestMtu(PREFERRED_MTU) },
            done = { discoverServices(gatt) }
        )
    }

    private fun discoverServices(gatt: BluetoothGatt) {
        queueFor(gatt.device.address).enqueue(
            name = "discoverServices",
            start = { gatt.discoverServices() },
            done = { error ->
                if (error != null) {
                    teardown(gatt.device.address, error.message, countAsFailure = true)
                } else {
                    subscribe(gatt)
                }
            }
        )
    }

    private fun subscribe(gatt: BluetoothGatt) {
        val address = gatt.device.address
        val characteristic =
            gatt.getService(serviceUuid)?.getCharacteristic(characteristicUuid)
        if (characteristic == null) {
            teardown(address, "peer does not expose the mesh characteristic", countAsFailure = false)
            return
        }
        if (!gatt.setCharacteristicNotification(characteristic, true)) {
            teardown(address, "could not enable notifications", countAsFailure = true)
            return
        }
        val descriptor = characteristic.getDescriptor(CCCD_UUID)
        if (descriptor == null) {
            teardown(address, "mesh characteristic has no CCCD", countAsFailure = false)
            return
        }
        queueFor(address).enqueue(
            name = "writeCccd",
            start = { issueDescriptorWrite(gatt, descriptor) },
            done = { error ->
                if (error != null) {
                    teardown(address, error.message, countAsFailure = true)
                } else {
                    registerLink(gatt, characteristic)
                }
            }
        )
    }

    private fun registerLink(
        gatt: BluetoothGatt,
        characteristic: BluetoothGattCharacteristic
    ) {
        val address = gatt.device.address
        connecting.remove(address)
        connectTimeouts.remove(address)?.let { handler.removeCallbacks(it) }
        failures.remove(address)
        cooldownUntil.remove(address)

        val link =
            MeshLink(
                linkId = MeshLink.idFor(BleLinkRole.CENTRAL, address),
                role = BleLinkRole.CENTRAL,
                device = gatt.device,
                connectedAtMs = System.currentTimeMillis()
            ).apply {
                this.gatt = gatt
                this.characteristic = characteristic
                this.maxFrameSize =
                    pendingFrameSize[address] ?: MeshLink.DEFAULT_MAX_FRAME_SIZE
            }
        registry.put(link)
        gatt.readRemoteRssi()
        events.linkUp(link.toPigeon())
    }

    private fun teardown(
        address: String,
        reason: String?,
        countAsFailure: Boolean
    ) {
        connecting.remove(address)
        connectTimeouts.remove(address)?.let { handler.removeCallbacks(it) }
        pendingFrameSize.remove(address)

        queues.remove(address)?.cancelAll(reason ?: "link closed")

        gatts.remove(address)?.let { gatt ->
            runCatching { gatt.disconnect() }
            // Closing is not optional: a leaked client interface is the single
            // most common cause of the infamous status 133 on the next attempt.
            runCatching { gatt.close() }
        }

        registry.remove(MeshLink.idFor(BleLinkRole.CENTRAL, address))?.let { link ->
            events.linkDown(link.linkId, reason)
        }

        if (countAsFailure) noteFailure(address, reason)
    }

    private fun noteFailure(
        address: String,
        reason: String?
    ) {
        val count = (failures[address] ?: 0) + 1
        failures[address] = count
        // Cap the shift before the multiply: a peer that fails 64 times in a
        // row would otherwise overflow into a negative backoff.
        val backoff = min(BASE_BACKOFF_MS shl min(count - 1, 6), MAX_BACKOFF_MS)
        val jitter = Random.nextLong(backoff / 4 + 1)
        cooldownUntil[address] = SystemClock.elapsedRealtime() + backoff + jitter
        Log.w(TAG, "peer $address failed ($count): $reason; cooling down ${backoff}ms")
    }

    private fun queueFor(address: String): GattQueue =
        queues.getOrPut(address) { GattQueue(handler, "central/$address") }

    // ----------------------------------------------------- API level plumbing

    private fun issueWrite(
        gatt: BluetoothGatt,
        characteristic: BluetoothGattCharacteristic,
        frame: ByteArray
    ): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            gatt.writeCharacteristic(
                characteristic,
                frame,
                BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
            ) == BluetoothStatusCodes.SUCCESS
        } else {
            @Suppress("DEPRECATION")
            run {
                characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
                characteristic.value = frame
                gatt.writeCharacteristic(characteristic)
            }
        }

    private fun issueDescriptorWrite(
        gatt: BluetoothGatt,
        descriptor: BluetoothGattDescriptor
    ): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            gatt.writeDescriptor(
                descriptor,
                BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            ) == BluetoothStatusCodes.SUCCESS
        } else {
            @Suppress("DEPRECATION")
            run {
                descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                gatt.writeDescriptor(descriptor)
            }
        }

    private companion object {
        const val TAG = "BleMesh"

        /** ATT opcode + handle overhead that is not available to the payload. */
        const val ATT_HEADER_BYTES = 3

        /** Ask for the maximum; peers negotiate down to whatever they support. */
        const val PREFERRED_MTU = 517

        const val BASE_BACKOFF_MS = 500L
        const val MAX_BACKOFF_MS = 30_000L

        val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }
}
