package com.example.handbean_probe

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Visible foreground service so Android will not freeze the BEAM after the
 * activity leaves the screen. Stop from the notification action — not a
 * silent keep-alive.
 */
class AgentKeepAliveService : Service() {

    companion object {
        const val CHANNEL_ID = "sigil_agent"
        const val NOTIFICATION_ID = 1001
        const val ACTION_STOP = "com.example.handbean_probe.STOP_AGENT"
        private const val EXTRA_TITLE = "sigil_running_title"
        private const val EXTRA_TEXT = "sigil_running_text"
        private const val EXTRA_TAP = "sigil_running_tap"
        private const val EXTRA_ACTIVE_RUN_IDS = "sigil_active_run_ids"

        private val running = AtomicBoolean(false)

        @JvmStatic
        fun isRunning(): Boolean = running.get()

        @JvmStatic
        fun start(context: Context) {
            val intent = Intent(context, AgentKeepAliveService::class.java)
            ContextCompat.startForegroundService(context, intent)
        }

        @JvmStatic
        fun update(
            context: Context,
            copy: Pair<String, String>,
            tap: Intent?,
            activeRunIds: Collection<String>,
        ) {
            val intent =
                Intent(context, AgentKeepAliveService::class.java).apply {
                    putExtra(EXTRA_TITLE, copy.first)
                    putExtra(EXTRA_TEXT, copy.second)
                    putStringArrayListExtra(EXTRA_ACTIVE_RUN_IDS, ArrayList(activeRunIds))
                    if (tap != null) putExtra(EXTRA_TAP, tap)
                }
            ContextCompat.startForegroundService(context, intent)
        }

        @JvmStatic
        fun stop(context: Context) {
            val intent = Intent(context, AgentKeepAliveService::class.java).setAction(ACTION_STOP)
            context.startService(intent)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
        startAsForeground()
        running.set(true)
    }

    private var title: String? = null
    private var text: String? = null
    private var tap: Intent? = null
    private val commandController = AgentServiceCommandController(HandbeanServiceRunStopBridge)

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val activeRunIds = intent?.getStringArrayListExtra(EXTRA_ACTIVE_RUN_IDS)
        if (commandController.handle(intent?.action, activeRunIds)) {
            shutdown()
            return START_NOT_STICKY
        }
        intent?.getStringExtra(EXTRA_TITLE)?.let { title = it }
        intent?.getStringExtra(EXTRA_TEXT)?.let { text = it }
        if (Build.VERSION.SDK_INT >= 33) {
            intent?.getParcelableExtra(EXTRA_TAP, Intent::class.java)?.let { tap = it }
        } else {
            @Suppress("DEPRECATION")
            intent?.getParcelableExtra<Intent>(EXTRA_TAP)?.let { tap = it }
        }
        startAsForeground()
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running.set(false)
        super.onDestroy()
    }

    private fun shutdown() {
        running.set(false)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun startAsForeground() {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun buildNotification(): Notification {
        val openIntent =
            tap
                ?: Intent(this, MainActivity::class.java).setFlags(
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP,
                )
        val open =
            PendingIntent.getActivity(
                this,
                0,
                openIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        val stop =
            PendingIntent.getService(
                this,
                1,
                Intent(this, AgentKeepAliveService::class.java).setAction(ACTION_STOP),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        val zh = Locale.getDefault().language == "zh"
        val contentTitle = title ?: if (zh) "Handbean 运行中" else "Handbean running"
        val contentText = text
        val stopLabel = if (zh) "停止" else "Stop"
        val builder =
            NotificationCompat.Builder(this, CHANNEL_ID)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle(contentTitle)
                .setContentIntent(open)
                .setOngoing(true)
                .setSilent(true)
                .setOnlyAlertOnce(true)
                .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
                .addAction(0, stopLabel, stop)
        if (!contentText.isNullOrEmpty()) builder.setContentText(contentText)
        return builder.build()
    }

    private fun ensureChannel() {
        val nm = getSystemService(NotificationManager::class.java) ?: return
        val name = if (Locale.getDefault().language == "zh") "Agent" else "Agent"
        val channel =
            NotificationChannel(CHANNEL_ID, name, NotificationManager.IMPORTANCE_LOW).apply {
                setShowBadge(false)
                setSound(null, null)
                enableVibration(false)
            }
        nm.createNotificationChannel(channel)
    }
}

internal object HandbeanServiceRunStopBridge : AgentRunStopBridge {
    override fun observeActiveRuns(runIds: Collection<String>) {
        HandbeanBridge.observeActiveRuns(runIds)
    }

    override fun recordClose() {
        HandbeanBridge.recordClose()
    }
}

/** Pure command boundary shared by Service.onStartCommand and JVM regression tests. */
internal class AgentServiceCommandController(
    private val bridge: AgentRunStopBridge,
) {
    /** Returns true when the service should remove its foreground notification and stop. */
    fun handle(action: String?, activeRunIds: Collection<String>?): Boolean {
        if (action == AgentKeepAliveService.ACTION_STOP) {
            bridge.recordClose()
            return true
        }

        activeRunIds?.let(bridge::observeActiveRuns)
        return false
    }
}
