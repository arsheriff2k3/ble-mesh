package dev.blemesh.ble_mesh

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat

/**
 * Runtime permission handling for the two very different Android worlds.
 *
 * API 31+ has dedicated Bluetooth permissions, and `neverForLocation` on the
 * scan permission means we never have to ask for location — every extra prompt
 * costs a host app users. API 30 and below have no such split: scanning implies
 * location access, so we must ask for it.
 */
object BlePermissions {
    const val REQUEST_CODE = 0x4D45 // "ME"

    fun required(): Array<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_ADVERTISE,
                Manifest.permission.BLUETOOTH_CONNECT
            )
        } else {
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    fun granted(context: Context): Boolean =
        required().all {
            ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
        }

    fun missing(context: Context): Array<String> =
        required()
            .filter {
                ContextCompat.checkSelfPermission(context, it) != PackageManager.PERMISSION_GRANTED
            }.toTypedArray()

    /**
     * Distinguishes "denied" from "denied permanently".
     *
     * This is a heuristic: `shouldShowRequestPermissionRationale` only returns
     * false-after-denial once the user has actually denied at least once, so
     * treat a `permanentlyDenied` result as "send them to settings" advice
     * rather than gospel.
     */
    fun classifyDenial(
        activity: Activity,
        denied: List<String>
    ): BlePermissionState =
        if (denied.any { !ActivityCompat.shouldShowRequestPermissionRationale(activity, it) }) {
            BlePermissionState.PERMANENTLY_DENIED
        } else {
            BlePermissionState.DENIED
        }
}
