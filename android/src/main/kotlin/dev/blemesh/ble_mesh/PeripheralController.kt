package dev.blemesh.ble_mesh

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.ParcelUuid
import android.util.Log
import java.io.ByteArrayOutputStream
import java.util.UUID

/**
 * The advertising / GATT-server half of the mesh.
 *
 * A peer that finds our advertisement connects in and subscribes to the mesh
 * characteristic; from then on we push frames to it as notifications and it
 * pushes frames to us as writes. Main thread only, same as the central side.
 */
@SuppressLint("MissingPermission")
class PeripheralController(
    private val context: Context,
    private val adapter: BluetoothAdapter,
    private val registry: LinkRegistry,
    private val events: BleEventBus,
    private val handler: Handler
) {
    private var config: BleConfig? = null
    private var running = false
    private var server: BluetoothGattServer? = null
    private var characteristic: BluetoothGattCharacteristic? = null

    private lateinit var serviceUuid: UUID
    private lateinit var characteristicUuid: UUID

    private val queues = mutableMapOf<String, GattQueue>()

    /** Long-write reassembly buffers, keyed by device address. */
    private val preparedWrites = mutableMapOf<String, ByteArrayOutputStream>()

    val supported: Boolean
        get() = adapter.isMultipleAdvertisementSupported

    fun start(config: BleConfig) {
        if (running) return
        this.config = config
        serviceUuid = UUID.fromString(config.serviceUuid)
        characteristicUuid = UUID.fromString(config.characteristicUuid)

        if (!supported) {
            // Scan-only devices can still receive from the mesh, but they are
            // invisible to it. Say so instead of pretending the mesh is healthy.
            events.error(
                BleErrorCode.UNSUPPORTED,
                "this device cannot advertise; it can receive but not be discovered"
            )
            return
        }

        val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        if (manager == null) {
            events.error(BleErrorCode.INTERNAL_ERROR, "no BluetoothManager")
            return
        }

        running = true
        if (!openServer(manager)) {
            running = false
            return
        }
        startAdvertising(config)
    }

    fun stop() {
        running = false
        stopAdvertising()

        queues.values.forEach { it.cancelAll("transport stopped") }
        queues.clear()
        preparedWrites.clear()

        server?.let { gattServer ->
            registry.all().filter { it.role == BleLinkRole.PERIPHERAL }.forEach {
                runCatching { gattServer.cancelConnection(it.device) }
            }
            runCatching { gattServer.clearServices() }
            runCatching { gattServer.close() }
        }
        server = null
        characteristic = null
    }

    fun notify(
        link: MeshLink,
        frame: ByteArray,
        done: (Throwable?) -> Unit
    ) {
        val gattServer = server
        val char = characteristic
        if (gattServer == null || char == null) {
            done(GattOperationException("GATT server is not running"))
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
            name = "notify",
            start = { issueNotify(gattServer, link.device, char, frame) },
            done = done
        )
    }

    fun disconnect(link: MeshLink) {
        server?.let { runCatching { it.cancelConnection(link.device) } }
        dropLink(link.address, "disconnect requested")
    }

    // ------------------------------------------------------------ gatt server

    private fun openServer(manager: BluetoothManager): Boolean {
        val gattServer = manager.openGattServer(context, serverCallback)
        if (gattServer == null) {
            events.error(BleErrorCode.INTERNAL_ERROR, "openGattServer returned null")
            return false
        }
        server = gattServer

        val meshCharacteristic =
            BluetoothGattCharacteristic(
                characteristicUuid,
                BluetoothGattCharacteristic.PROPERTY_WRITE or
                    BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE or
                    BluetoothGattCharacteristic.PROPERTY_NOTIFY,
                BluetoothGattCharacteristic.PERMISSION_WRITE
            )
        // Android needs the CCCD spelled out; CoreBluetooth adds it implicitly.
        meshCharacteristic.addDescriptor(
            BluetoothGattDescriptor(
                CCCD_UUID,
                BluetoothGattDescriptor.PERMISSION_READ or
                    BluetoothGattDescriptor.PERMISSION_WRITE
            )
        )
        characteristic = meshCharacteristic

        val service =
            BluetoothGattService(serviceUuid, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        service.addCharacteristic(meshCharacteristic)

        if (!gattServer.addService(service)) {
            events.error(BleErrorCode.INTERNAL_ERROR, "addService was refused")
            return false
        }
        return true
    }

    private val serverCallback =
        object : BluetoothGattServerCallback() {
            override fun onConnectionStateChange(
                device: BluetoothDevice,
                status: Int,
                newState: Int
            ) {
                handler.post {
                    if (newState != BluetoothProfile.STATE_CONNECTED) {
                        dropLink(device.address, "peer disconnected (status $status)")
                    }
                    // A connected-but-unsubscribed peer is not a usable link,
                    // so linkUp waits for the CCCD write below.
                }
            }

            override fun onMtuChanged(
                device: BluetoothDevice,
                mtu: Int
            ) {
                handler.post {
                    val usable = (mtu - ATT_HEADER_BYTES).toLong()
                    pendingFrameSize[device.address] = usable
                    registry.find(BleLinkRole.PERIPHERAL, device.address)?.maxFrameSize = usable
                }
            }

            override fun onDescriptorWriteRequest(
                device: BluetoothDevice,
                requestId: Int,
                descriptor: BluetoothGattDescriptor,
                preparedWrite: Boolean,
                responseNeeded: Boolean,
                offset: Int,
                value: ByteArray
            ) {
                val enabled =
                    value.contentEquals(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
                handler.post {
                    if (descriptor.uuid == CCCD_UUID) {
                        if (enabled) {
                            registerLink(device)
                        } else {
                            dropLink(device.address, "peer unsubscribed")
                        }
                    }
                    if (responseNeeded) {
                        server?.sendResponse(
                            device,
                            requestId,
                            BluetoothGatt.GATT_SUCCESS,
                            offset,
                            null
                        )
                    }
                }
            }

            override fun onCharacteristicWriteRequest(
                device: BluetoothDevice,
                requestId: Int,
                characteristic: BluetoothGattCharacteristic,
                preparedWrite: Boolean,
                responseNeeded: Boolean,
                offset: Int,
                value: ByteArray
            ) {
                val copy = value.copyOf()
                handler.post {
                    if (preparedWrite) {
                        // Long writes only happen if a peer ignores maxFrameSize,
                        // but dropping them silently would be a miserable bug to
                        // chase, so reassemble and cap.
                        val buffer =
                            preparedWrites.getOrPut(device.address) { ByteArrayOutputStream() }
                        if (buffer.size() + copy.size <= MAX_PREPARED_BYTES) {
                            buffer.write(copy)
                        } else {
                            preparedWrites.remove(device.address)
                            events.error(
                                BleErrorCode.WRITE_FAILED,
                                "prepared write from ${device.address} exceeded $MAX_PREPARED_BYTES bytes"
                            )
                        }
                    } else {
                        deliver(device.address, copy)
                    }
                    if (responseNeeded) {
                        server?.sendResponse(
                            device,
                            requestId,
                            BluetoothGatt.GATT_SUCCESS,
                            offset,
                            null
                        )
                    }
                }
            }

            override fun onExecuteWrite(
                device: BluetoothDevice,
                requestId: Int,
                execute: Boolean
            ) {
                handler.post {
                    val buffer = preparedWrites.remove(device.address)
                    if (execute && buffer != null) {
                        deliver(device.address, buffer.toByteArray())
                    }
                    server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
                }
            }

            override fun onNotificationSent(
                device: BluetoothDevice,
                status: Int
            ) {
                handler.post {
                    queueFor(device.address).complete(
                        if (status == BluetoothGatt.GATT_SUCCESS) {
                            null
                        } else {
                            GattOperationException("notification failed with $status")
                        }
                    )
                }
            }
        }

    private val pendingFrameSize = mutableMapOf<String, Long>()

    private fun deliver(
        address: String,
        value: ByteArray
    ) {
        val link = registry.find(BleLinkRole.PERIPHERAL, address)
        if (link == null) {
            // A write before the CCCD subscription is legal but useless to us:
            // we would have no way to reply.
            Log.w(TAG, "frame from unsubscribed peer $address dropped")
            return
        }
        events.frame(link.linkId, value)
    }

    private fun registerLink(device: BluetoothDevice) {
        if (registry.find(BleLinkRole.PERIPHERAL, device.address) != null) return
        val current = config ?: return
        if (registry.size >= current.maxConcurrentLinks) {
            runCatching { server?.cancelConnection(device) }
            return
        }
        val link =
            MeshLink(
                linkId = MeshLink.idFor(BleLinkRole.PERIPHERAL, device.address),
                role = BleLinkRole.PERIPHERAL,
                device = device,
                connectedAtMs = System.currentTimeMillis()
            ).apply {
                maxFrameSize =
                    pendingFrameSize[device.address] ?: MeshLink.DEFAULT_MAX_FRAME_SIZE
            }
        registry.put(link)
        events.linkUp(link.toPigeon())
    }

    private fun dropLink(
        address: String,
        reason: String
    ) {
        preparedWrites.remove(address)
        pendingFrameSize.remove(address)
        queues.remove(address)?.cancelAll(reason)
        registry.remove(MeshLink.idFor(BleLinkRole.PERIPHERAL, address))?.let {
            events.linkDown(it.linkId, reason)
        }
    }

    private fun queueFor(address: String): GattQueue =
        queues.getOrPut(address) { GattQueue(handler, "peripheral/$address") }

    // ------------------------------------------------------------ advertising

    private fun startAdvertising(config: BleConfig) {
        val advertiser = adapter.bluetoothLeAdvertiser
        if (advertiser == null) {
            events.error(BleErrorCode.ADVERTISING_FAILED, "no advertiser; adapter is off")
            return
        }
        // Note: we deliberately do NOT set `adapter.name` to the configured
        // advertised name. That would rename the user's whole phone for every
        // Bluetooth device they own. Android therefore advertises the system
        // Bluetooth name, and `config.advertisedName` only takes effect on
        // Apple platforms — peer identity comes from the post-connect ANNOUNCE
        // either way, so the advertised name is cosmetic.
        val settings =
            AdvertiseSettings
                .Builder()
                .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_BALANCED)
                .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
                .setConnectable(true)
                .setTimeout(0)
                .build()

        // The advertisement budget is 31 bytes and a 128-bit service UUID eats
        // 18 of them, so the name goes in the scan response or nothing fits.
        val data =
            AdvertiseData
                .Builder()
                .setIncludeDeviceName(false)
                .setIncludeTxPowerLevel(false)
                .addServiceUuid(ParcelUuid(serviceUuid))
                .build()
        val scanResponse =
            AdvertiseData
                .Builder()
                .setIncludeDeviceName(true)
                .build()

        runCatching { advertiser.startAdvertising(settings, data, scanResponse, advertiseCallback) }
            .onFailure {
                events.error(
                    BleErrorCode.ADVERTISING_FAILED,
                    "startAdvertising threw: ${it.message}"
                )
            }
    }

    private fun stopAdvertising() {
        runCatching { adapter.bluetoothLeAdvertiser?.stopAdvertising(advertiseCallback) }
    }

    private val advertiseCallback =
        object : AdvertiseCallback() {
            override fun onStartFailure(errorCode: Int) {
                handler.post {
                    events.error(
                        BleErrorCode.ADVERTISING_FAILED,
                        "advertising failed with code $errorCode"
                    )
                }
            }
        }

    private fun issueNotify(
        gattServer: BluetoothGattServer,
        device: BluetoothDevice,
        char: BluetoothGattCharacteristic,
        frame: ByteArray
    ): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            gattServer.notifyCharacteristicChanged(
                device,
                char,
                /* confirm = */ false,
                frame
            ) == BluetoothStatusCodes.SUCCESS
        } else {
            @Suppress("DEPRECATION")
            run {
                char.value = frame
                gattServer.notifyCharacteristicChanged(device, char, false)
            }
        }

    private companion object {
        const val TAG = "BleMesh"
        const val ATT_HEADER_BYTES = 3
        const val MAX_PREPARED_BYTES = 8 * 1024

        val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }
}
