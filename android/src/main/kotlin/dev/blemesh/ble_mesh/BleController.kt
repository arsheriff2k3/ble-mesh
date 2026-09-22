package dev.blemesh.ble_mesh

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine

/**
 * Orchestrates both radio roles and owns the link registry.
 *
 * Every mesh device runs as central *and* peripheral simultaneously: it scans
 * and connects out while advertising and serving connections in. That is the
 * whole reason this plugin exists instead of an off-the-shelf package.
 */
class BleController(
    private val context: Context,
    private val events: BleEventBus
) {
    private val handler = Handler(Looper.getMainLooper())
    private val registry = LinkRegistry()

    private val manager: BluetoothManager? =
        context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private val adapter: BluetoothAdapter? = manager?.adapter

    private var central: CentralController? = null
    private var peripheral: PeripheralController? = null

    /**
     * What Dart asked for, which outlives the radios: if Bluetooth is switched
     * off mid-session we tear the radios down but keep this, so the mesh comes
     * back by itself when the user switches Bluetooth on again.
     */
    private var desiredConfig: BleConfig? = null
    private var radiosRunning = false
    private var receiverRegistered = false

    fun capabilities(): BleCapabilities {
        val hasLe =
            context.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)
        // Local val, because a property's smart cast does not reach inside the
        // lambda below.
        val bluetoothAdapter = adapter
        val canAdvertise =
            hasLe &&
                bluetoothAdapter != null &&
                runCatching { bluetoothAdapter.isMultipleAdvertisementSupported }
                    .getOrDefault(false)
        return BleCapabilities(
            supportsCentral = hasLe && bluetoothAdapter != null,
            supportsPeripheral = canAdvertise,
            platformName = "android"
        )
    }

    fun adapterState(): BleAdapterState =
        when {
            adapter == null ||
                !context.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE) ->
                BleAdapterState.UNSUPPORTED

            !BlePermissions.granted(context) -> BleAdapterState.UNAUTHORIZED
            !adapter.isEnabled -> BleAdapterState.POWERED_OFF
            else -> BleAdapterState.POWERED_ON
        }

    /** Idempotent by contract: Dart restarts on lifecycle and adapter changes. */
    fun start(config: BleConfig) {
        if (adapter == null) {
            throw FlutterError("unsupported", "no Bluetooth adapter", null)
        }
        if (!BlePermissions.granted(context)) {
            throw FlutterError("permission_denied", "Bluetooth permissions are not granted", null)
        }
        if (!adapter.isEnabled) {
            throw FlutterError("bluetooth_off", "Bluetooth is switched off", null)
        }

        desiredConfig = config
        registerAdapterReceiver()

        if (config.enableBackground) {
            MeshForegroundService.start(
                context,
                config.backgroundNotificationTitle,
                config.backgroundNotificationBody
            )
        }
        startRadios(config)
        events.adapterState(BleAdapterState.POWERED_ON)
    }

    fun stop() {
        val previous = desiredConfig
        desiredConfig = null
        stopRadios("transport stopped")
        if (previous?.enableBackground == true) {
            MeshForegroundService.stop(context)
        }
        unregisterAdapterReceiver()
    }

    suspend fun send(
        linkId: String,
        frame: ByteArray
    ) = suspendCancellableCoroutine<Unit> { continuation ->
        val link = registry[linkId]
        if (link == null) {
            continuation.resumeWithException(
                FlutterError("unknown_link", "no live link $linkId", null)
            )
            return@suspendCancellableCoroutine
        }
        val done: (Throwable?) -> Unit = { error ->
            if (continuation.isActive) {
                if (error == null) {
                    continuation.resume(Unit)
                } else {
                    continuation.resumeWithException(
                        FlutterError("write_failed", error.message ?: "write failed", linkId)
                    )
                }
            }
        }

        val transport: (() -> Unit)? =
            when (link.role) {
                BleLinkRole.CENTRAL ->
                    central?.let { controller -> { controller.write(link, frame, done) } }

                BleLinkRole.PERIPHERAL ->
                    peripheral?.let { controller -> { controller.notify(link, frame, done) } }
            }
        if (transport == null) {
            done(GattOperationException("transport is not running"))
        } else {
            transport()
        }
    }

    fun disconnect(linkId: String) {
        val link = registry[linkId] ?: return
        when (link.role) {
            BleLinkRole.CENTRAL -> central?.disconnect(link)
            BleLinkRole.PERIPHERAL -> peripheral?.disconnect(link)
        }
    }

    fun links(): List<BleLink> = registry.all().map { it.toPigeon() }

    fun dispose() = stop()

    // ------------------------------------------------------------------ radios

    private fun startRadios(config: BleConfig) {
        if (radiosRunning) return
        val bluetoothAdapter = adapter ?: return
        radiosRunning = true

        // Peripheral first: a peer that discovers us mid-handshake should find
        // a GATT server that is already able to answer.
        peripheral =
            PeripheralController(context, bluetoothAdapter, registry, events, handler)
                .also { it.start(config) }
        central =
            CentralController(context, bluetoothAdapter, registry, events, handler)
                .also { it.start(config) }
    }

    private fun stopRadios(reason: String) {
        if (!radiosRunning) return
        radiosRunning = false

        central?.stop()
        peripheral?.stop()
        central = null
        peripheral = null

        // The controllers drop their own links, but anything still registered
        // here would otherwise be invisible garbage to Dart.
        registry.clear().forEach { events.linkDown(it.linkId, reason) }
    }

    // ------------------------------------------------------- adapter lifecycle

    private val adapterReceiver =
        object : BroadcastReceiver() {
            override fun onReceive(
                context: Context?,
                intent: Intent?
            ) {
                if (intent?.action != BluetoothAdapter.ACTION_STATE_CHANGED) return
                when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)) {
                    BluetoothAdapter.STATE_OFF -> {
                        // The radio going away invalidates every link at once,
                        // and the platform does not reliably report them one
                        // by one.
                        stopRadios("bluetooth switched off")
                        events.adapterState(BleAdapterState.POWERED_OFF)
                    }

                    BluetoothAdapter.STATE_ON -> {
                        events.adapterState(BleAdapterState.POWERED_ON)
                        desiredConfig?.let { startRadios(it) }
                    }
                }
            }
        }

    private fun registerAdapterReceiver() {
        if (receiverRegistered) return
        context.registerReceiver(
            adapterReceiver,
            IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED)
        )
        receiverRegistered = true
    }

    private fun unregisterAdapterReceiver() {
        if (!receiverRegistered) return
        runCatching { context.unregisterReceiver(adapterReceiver) }
        receiverRegistered = false
    }
}
