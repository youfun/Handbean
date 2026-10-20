package com.example.handbean_probe

import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import androidx.core.app.NotificationCompat

// Keep this class/package name: the manifest and scheduled intents resolve it.
// Receives alarms from AlarmManager and posts the notification to the system tray.
class NotificationReceiver : BroadcastReceiver() {
    override fun onReceive(context: android.content.Context, intent: android.content.Intent) {
        val title   = intent.getStringExtra("title") ?: ""
        val body    = intent.getStringExtra("body")  ?: ""
        val id      = intent.getStringExtra("id")    ?: "mob"
        val dataStr = intent.getStringExtra("data")  ?: "{}"

        // Payload MainActivity.onCreate / onNewIntent expect under this key; they
        // forward it to the BEAM (delivered now if running, else on next boot).
        val json = """{"id":"$id","title":"$title","body":"$body","source":"local","data":$dataStr}"""

        // Tap action: bring MainActivity (singleTop) to the foreground carrying
        // the payload. Without a content intent the tap is a no-op.
        val tapIntent = android.content.Intent(context, MainActivity::class.java).apply {
            flags = android.content.Intent.FLAG_ACTIVITY_NEW_TASK or
                android.content.Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra("mob_notification_json", json)
        }
        val contentPi = PendingIntent.getActivity(
            context, id.hashCode(), tapIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

        val nm = context.getSystemService(android.content.Context.NOTIFICATION_SERVICE) as NotificationManager
        val notif = NotificationCompat.Builder(context, io.mob.plugin.MobNotifyHub.CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle(title)
            .setContentText(body)
            .setContentIntent(contentPi)
            .setAutoCancel(true)
            .build()
        nm.notify(id.hashCode(), notif)
    }
}
