package dev.blemesh.ble_mesh

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/**
 * Keeps the process alive while the mesh is on.
 *
 * The service does no Bluetooth work itself — the controllers live with the
 * Flutter engine. Its only job is to stop Android from freezing or killing the
 * process the moment the app is backgrounded, which would silently take the
 * mesh down the instant a user pockets their phone.
 *
 * The notification is deliberately not dismissable: running the radio in the
 * background without telling the user is not something this plugin will do
 * quietly. Host apps set the title and body through `BleConfig`.
 */
class MeshForegroundService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(
        intent: Intent?,
        flags: Int,
        startId: Int
    ): Int {
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "Mesh active"
        val body = intent?.getStringExtra(EXTRA_BODY) ?: "Relaying messages to nearby devices."

        createChannel()
        val notification =
            NotificationCompat
                .Builder(this, CHANNEL_ID)
                .setContentTitle(title)
                .setContentText(body)
                .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
                .setOngoing(true)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setCategory(NotificationCompat.CATEGORY_SERVICE)
                .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        // Restarting without the Flutter engine would give a notification with
        // no mesh behind it, which is worse than being stopped.
        return START_NOT_STICKY
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel =
            NotificationChannel(
                CHANNEL_ID,
                "Bluetooth mesh",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shown while this device is relaying mesh messages."
                setShowBadge(false)
            }
        manager.createNotificationChannel(channel)
    }

    companion object {
        private const val CHANNEL_ID = "ble_mesh_service"
        private const val NOTIFICATION_ID = 0x524D
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_BODY = "body"

        fun start(
            context: Context,
            title: String,
            body: String
        ) {
            val intent =
                Intent(context, MeshForegroundService::class.java)
                    .putExtra(EXTRA_TITLE, title)
                    .putExtra(EXTRA_BODY, body)
            ContextCompat.startForegroundService(context, intent)
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, MeshForegroundService::class.java))
        }
    }
}
