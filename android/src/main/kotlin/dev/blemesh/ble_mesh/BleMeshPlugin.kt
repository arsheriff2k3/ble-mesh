package dev.blemesh.ble_mesh

import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import androidx.core.app.ActivityCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.PluginRegistry
import kotlin.coroutines.resume
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.suspendCancellableCoroutine

/** Android entry point. Everything interesting lives in [BleController]. */
class BleMeshPlugin :
    FlutterPlugin,
    ActivityAware,
    BleMeshHostApi,
    PluginRegistry.RequestPermissionsResultListener {
    private var context: Context? = null
    private var events: BleEventBus? = null
    private var controller: BleController? = null

    private var activityBinding: ActivityPluginBinding? = null
    private var permissionRequest: CancellableContinuation<BlePermissionState>? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val applicationContext = binding.applicationContext
        val eventBus = BleEventBus()

        context = applicationContext
        events = eventBus
        controller = BleController(applicationContext, eventBus)

        EventsStreamHandler.register(binding.binaryMessenger, eventBus)
        BleMeshHostApi.setUp(binding.binaryMessenger, this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        BleMeshHostApi.setUp(binding.binaryMessenger, null)
        controller?.dispose()
        controller = null
        events?.dispose()
        events = null
        context = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onDetachedFromActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        // The mesh deliberately keeps running: losing the activity is exactly
        // the moment a backgrounded device still needs to relay.
    }

    // -------------------------------------------------------------- host API

    override fun capabilities(): BleCapabilities = requireController().capabilities()

    override fun adapterState(): BleAdapterState = requireController().adapterState()

    override suspend fun requestPermissions(): BlePermissionState {
        val applicationContext =
            context ?: throw FlutterError("detached", "plugin is not attached", null)
        if (BlePermissions.missing(applicationContext).isEmpty()) {
            return BlePermissionState.GRANTED
        }
        val activity =
            activityBinding?.activity
                ?: throw FlutterError(
                    "no_activity",
                    "permissions can only be requested from a foreground activity",
                    null
                )

        return suspendCancellableCoroutine { continuation ->
            // A second request while one is outstanding would leave the first
            // coroutine hanging forever.
            permissionRequest?.let { pending ->
                if (pending.isActive) pending.resume(BlePermissionState.DENIED)
            }
            permissionRequest = continuation
            ActivityCompat.requestPermissions(
                activity,
                BlePermissions.missing(applicationContext),
                BlePermissions.REQUEST_CODE
            )
        }
    }

    override suspend fun start(config: BleConfig) = requireController().start(config)

    override suspend fun stop() = requireController().stop()

    override suspend fun send(
        linkId: String,
        frame: ByteArray
    ) = requireController().send(linkId, frame)

    override suspend fun disconnect(linkId: String) = requireController().disconnect(linkId)

    override fun links(): List<BleLink> = requireController().links()

    // ------------------------------------------------------------ permissions

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ): Boolean {
        if (requestCode != BlePermissions.REQUEST_CODE) return false
        val continuation = permissionRequest ?: return true
        permissionRequest = null

        val denied =
            permissions.filterIndexed { index, _ ->
                grantResults.getOrNull(index) != PackageManager.PERMISSION_GRANTED
            }
        val activity: Activity? = activityBinding?.activity
        val state =
            when {
                denied.isEmpty() -> BlePermissionState.GRANTED
                activity != null -> BlePermissions.classifyDenial(activity, denied)
                else -> BlePermissionState.DENIED
            }
        if (continuation.isActive) continuation.resume(state)
        return true
    }

    private fun requireController(): BleController =
        controller ?: throw FlutterError("detached", "plugin is not attached", null)
}
