package com.example.handbean_probe

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import org.json.JSONObject
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Run-lifecycle notifications. The FGS channel stays silent and ongoing.
 * Completion uses a separate channel and id so it never covers the FGS.
 */
object AgentNotify {
    const val RUNNING_CHANNEL_ID = AgentKeepAliveService.CHANNEL_ID
    const val ENDED_CHANNEL_ID = "sigil_agent_ended"
    const val RUNNING_NOTIFICATION_ID = AgentKeepAliveService.NOTIFICATION_ID
    private const val ENDED_NOTIFICATION_BASE = 2000

    private val appVisible = AtomicBoolean(true)
    @Volatile private var appContext: Context? = null

    @JvmStatic
    fun attach(context: Context) {
        appContext = context.applicationContext
        nativeInitClass()
        ensureChannels(context.applicationContext)
    }

    @JvmStatic private external fun nativeInitClass()

    // JNI carries UTF-8 bytes ([B), not java.lang.String: NewStringUTF /
    // GetStringUTFChars use modified UTF-8 and corrupt non-BMP text (emoji).
    @JvmStatic private external fun nativeOpenConversation(json: ByteArray): Boolean

    /** Deliver a notification-tap payload to the running Mob screen. */
    @JvmStatic
    fun openConversation(json: String): Boolean =
        nativeOpenConversation(json.toByteArray(Charsets.UTF_8))

    @JvmStatic
    fun setAppVisible(visible: Boolean) {
        appVisible.set(visible)
    }

    @JvmStatic
    fun appVisible(): Boolean = appVisible.get()

    /** Called from handbean_notify.c; [json] is UTF-8 encoded JSON. */
    @JvmStatic
    fun updateRunning(json: ByteArray) {
        val context = appContext ?: MobBridge.activity()?.applicationContext ?: return
        val payload = runCatching { JSONObject(String(json, Charsets.UTF_8)) }.getOrNull() ?: return
        val running = payload.optInt("running_count", 0)
        val waiting = payload.optInt("waiting_count", 0)
        val tasks = payload.optJSONArray("tasks")
        val first = tasks?.optJSONObject(0)
        val activeRunIds = activeRunIds(payload)
        ensureChannels(context)

        if (running + waiting <= 0) {
            AgentKeepAliveService.update(context, runningCopy(0, 0), null, activeRunIds)
            return
        }

        val tap =
            first?.let { task ->
                openConversationIntent(
                    context,
                    task.optString("workspace_id", ""),
                    task.optString("conversation_id", ""),
                    0,
                )
            }
        AgentKeepAliveService.update(context, runningCopy(running, waiting), tap, activeRunIds)
    }

    internal fun activeRunIds(json: ByteArray): Set<String> =
        runCatching { activeRunIds(JSONObject(String(json, Charsets.UTF_8))) }.getOrDefault(emptySet())

    private fun activeRunIds(payload: JSONObject): Set<String> {
        val tasks = payload.optJSONArray("tasks")
        val activeRunIds = mutableSetOf<String>()
        for (index in 0 until (tasks?.length() ?: 0)) {
            tasks?.optJSONObject(index)
                ?.optString("run_id", "")
                ?.takeIf { it.isNotBlank() }
                ?.let(activeRunIds::add)
        }
        return activeRunIds
    }

    /** Called from handbean_notify.c; [json] is UTF-8 encoded JSON. */
    @JvmStatic
    fun showEnded(json: ByteArray) {
        val context = appContext ?: MobBridge.activity()?.applicationContext ?: return
        if (appVisible.get()) return
        val payload = runCatching { JSONObject(String(json, Charsets.UTF_8)) }.getOrNull() ?: return
        val reason = payload.optString("reason", "completed")
        if (reason == "cancelled") return
        val task = payload.optJSONObject("task") ?: return
        val conversationId = task.optString("conversation_id", "")
        if (conversationId.isEmpty()) return
        val workspaceId = task.optString("workspace_id", "")
        ensureChannels(context)

        val nm = context.getSystemService(NotificationManager::class.java) ?: return
        val zh = Locale.getDefault().language == "zh"
        val title = if (zh) "Handbean" else "Handbean"
        val text =
            when (reason) {
                "failed" -> if (zh) "本次执行已结束" else "This run ended"
                else -> if (zh) "Agent 已回复" else "Agent replied"
            }
        val tap =
            PendingIntent.getActivity(
                context,
                conversationId.hashCode(),
                openConversationIntent(context, workspaceId, conversationId, 1),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        val notif =
            NotificationCompat.Builder(context, ENDED_CHANNEL_ID)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle(title)
                .setContentText(text)
                .setContentIntent(tap)
                .setAutoCancel(true)
                .build()
        nm.notify(ENDED_NOTIFICATION_BASE + conversationId.hashCode().and(0xffff), notif)
    }

    private fun runningCopy(running: Int, waiting: Int): Pair<String, String> {
        val zh = Locale.getDefault().language == "zh"
        val title = if (zh) "Handbean 运行中" else "Handbean running"
        val text =
            when {
                waiting > 0 && running > 0 ->
                    if (zh) "正在执行 $running 个任务 · 等待确认 $waiting"
                    else "Running $running · waiting $waiting"
                waiting > 0 ->
                    if (zh) "需要确认" else "Needs confirmation"
                running == 1 ->
                    if (zh) "正在执行 1 个任务" else "Running 1 task"
                running > 1 ->
                    if (zh) "正在执行 $running 个任务" else "Running $running tasks"
                else -> if (zh) "Handbean 运行中" else "Handbean running"
            }
        return title to text
    }

    private fun openConversationIntent(
        context: Context,
        workspaceId: String,
        conversationId: String,
        extra: Int,
    ): Intent {
        return Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            if (workspaceId.isNotEmpty() && conversationId.isNotEmpty()) {
                putExtra("sigil_workspace_id", workspaceId)
                putExtra("sigil_conversation_id", conversationId)
                val json =
                    JSONObject()
                        .put("id", "handbean-run-$conversationId")
                        .put("title", "Handbean")
                        .put("body", "")
                        .put("source", "local")
                        .put(
                            "data",
                            JSONObject()
                                .put("workspace_id", workspaceId)
                                .put("conversation_id", conversationId),
                        )
                        .toString()
                putExtra("mob_notification_json", json)
            }
            putExtra("handbean_notify_kind", extra)
        }
    }

    private fun ensureChannels(context: Context) {
        if (Build.VERSION.SDK_INT < 26) return
        val nm = context.getSystemService(NotificationManager::class.java) ?: return
        val zh = Locale.getDefault().language == "zh"
        val ended =
            NotificationChannel(
                ENDED_CHANNEL_ID,
                if (zh) "Agent 回复" else "Agent replies",
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                setShowBadge(true)
            }
        nm.createNotificationChannel(ended)
    }
}
