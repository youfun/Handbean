package com.example.handbean_probe.attachments

import android.app.Activity
import android.content.ActivityNotFoundException
import android.database.Cursor
import android.net.Uri
import android.provider.OpenableColumns
import androidx.lifecycle.Lifecycle
import com.example.handbean_probe.BridgeIds
import org.json.JSONObject
import java.io.File
import java.io.FileInputStream
import java.lang.ref.WeakReference
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class FileImportSource(
    private val file: File,
    override val displayName: String = file.name,
    override val declaredMime: String? = null,
    override val declaredSize: Long? = file.length(),
) : ImportSource {
    override fun openStream() = FileInputStream(file)
}

class UriImportSource(
    private val activity: Activity,
    private val uri: Uri,
    override val displayName: String,
    override val declaredMime: String?,
    override val declaredSize: Long?,
) : ImportSource {
    override fun openStream() =
        activity.contentResolver.openInputStream(uri) ?: throw IllegalStateException("no_stream")

    companion object {
        fun fromResolver(activity: Activity, uri: Uri): UriImportSource {
            var name = "attachment"
            var size: Long? = null
            val cursor: Cursor? = activity.contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
                null,
                null,
                null,
            )
            cursor?.use {
                if (it.moveToFirst()) {
                    val nameIdx = it.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val sizeIdx = it.getColumnIndex(OpenableColumns.SIZE)
                    if (nameIdx >= 0) name = it.getString(nameIdx) ?: name
                    if (sizeIdx >= 0 && !it.isNull(sizeIdx)) size = it.getLong(sizeIdx)
                }
            }
            val mime = activity.contentResolver.getType(uri)
            return UriImportSource(activity, uri, name, mime, size)
        }
    }
}

data class HostSession(
    val requestId: String,
    val generation: Int,
    val cancelled: AtomicBoolean = AtomicBoolean(false),
    val completion: RequestCompletion = RequestCompletion(),
    val launchGate: LaunchGate = LaunchGate(),
    @Volatile var lateFile: File? = null,
    @Volatile var snapshotId: String? = null,
    @Volatile var snapshotOwner: String? = null,
)

object PlatformHost {
    private val lock = Any()
    private var bound: Bound? = null

    fun attach(activity: Activity) {
        synchronized(lock) {
            if (bound == null) bound = Bound(activity.cacheDir)
            bound?.attachActivity(activity)
        }
    }

    fun detach(activity: Activity) {
        synchronized(lock) { bound }?.detachActivity(activity)
    }

    fun command(requestId: String, payloadJson: String, generation: Int) {
        val host = synchronized(lock) { bound } ?: run {
            deliver(requestId, generation, null, "host_unbound")
            return
        }
        host.command(requestId, payloadJson, generation)
    }

    fun cancel(requestId: String) {
        synchronized(lock) { bound }?.cancel(requestId)
    }

    fun importContentUri(requestId: String, generation: Int, uri: Uri) {
        synchronized(lock) { bound }?.importContentUri(requestId, generation, uri)
    }

    fun onCreateDocument(requestId: String?, uri: Uri?) {
        synchronized(lock) { bound }?.onCreateDocument(requestId, uri)
    }

    fun completeExternal(requestId: String, generation: Int, result: String?, error: String?) {
        synchronized(lock) { bound }?.completeExternal(requestId, generation, result, error)
            ?: deliver(requestId, generation, result, error)
    }

    fun currentSaveRequestId(): String? = synchronized(lock) { bound }?.currentSaveRequestId()

    private fun deliver(requestId: String, generation: Int, result: String?, error: String?) {
        com.example.handbean_probe.BrowserEngine.nativeDeliver(
            0L,
            ByteArray(0),
            requestId.toByteArray(Charsets.UTF_8),
            generation,
            result?.toByteArray(Charsets.UTF_8),
            error?.toByteArray(Charsets.UTF_8),
            null,
        )
    }

    private class Bound(private val cacheDir: File) {
        private var activityRef = WeakReference<Activity>(null)
        private val importRoot = File(cacheDir, "controlled_import")
        private val importer = ControlledImport(
            stagingRoot = importRoot,
            imageRewriter = { file, mime -> ImageNormalizer.normalize(file, mime) },
        )
        private val exporter = ExportSnapshotHandler(cacheRoot = cacheDir)
        private val io: Executor = Executors.newCachedThreadPool()
        private val sessions = ConcurrentHashMap<String, HostSession>()
        private val saveSlot = SaveResultSlot()

        fun attachActivity(activity: Activity) {
            activityRef = WeakReference(activity)
            exporter.attach(activity)
        }

        fun currentSaveRequestId(): String? = saveSlot.requestId()

        fun newSession(requestId: String, generation: Int): HostSession? {
            if (requestId.isBlank()) return null
            val created = HostSession(requestId, generation)
            return if (sessions.putIfAbsent(requestId, created) == null) created else null
        }

        fun detachActivity(activity: Activity) {
            if (activityRef.get() !== activity) return
            if (activity.isFinishing) {
                sessions.keys.toList().forEach(::cancel)
                saveSlot.clearAfterActivityFinish()
            }
            exporter.detach(activity)
            activityRef = WeakReference(null)
        }

        fun cancel(requestId: String) {
            val session = sessions[requestId] ?: return
            session.cancelled.set(true)
            if (!session.launchGate.cancelBeforeLaunch()) {
                return
            }
            session.lateFile?.delete()
            session.lateFile = null
            session.snapshotId?.let { id ->
                exporter.cancelOwned(id, session.snapshotOwner ?: requestId)
            }
            saveSlot.cancel(requestId)
            PhotoPickerHost.cancel(requestId)
            finish(session, """{"outcome":"cancelled_before_launch"}""", null)
        }

        fun completeExternal(requestId: String, generation: Int, result: String?, error: String?) {
            val session = sessions[requestId]
            if (session == null) {
                deliver(requestId, generation, result, error)
                return
            }
            finish(session, result, error)
        }

        private fun pickPhotos(session: HostSession) {
            if (!PhotoPickerHost.launch(session.requestId, session.generation)) {
                finish(session, null, "picker_busy")
            }
        }

        fun command(requestId: String, payloadJson: String, generation: Int) {
            val payload = JSONObject(payloadJson)
            val op = payload.optString("op")
            val session = newSession(requestId, generation) ?: run {
                deliver(requestId, generation, null, "invalid_request_id")
                return
            }
            when (op) {
                BridgeIds.PlatformOps.IMPORT -> importLocal(session, payload)
                BridgeIds.PlatformOps.EXPORT -> export(session, payload)
                BridgeIds.PlatformOps.SHARE_SNAPSHOT -> share(session, payload)
                BridgeIds.PlatformOps.OPEN_SNAPSHOT -> open(session, payload)
                BridgeIds.PlatformOps.OPEN_URL -> openUrl(session, payload)
                BridgeIds.PlatformOps.SHARE_TEXT -> shareText(session, payload)
                BridgeIds.PlatformOps.DEVICE_CALENDAR -> deviceCalendar(session, payload)
                BridgeIds.PlatformOps.DEVICE_ALARM -> deviceAlarm(session, payload)
                BridgeIds.PlatformOps.APP_SETTINGS -> appSettings(session, payload)
                BridgeIds.PlatformOps.SAVE_SNAPSHOT -> save(session, payload)
                BridgeIds.PlatformOps.CLEANUP -> {
                    val snapId = payload.optString("snapshot_id")
                    val owner = payload.optString("owner_request_id").ifEmpty { requestId }
                    exporter.cancelOwned(snapId, owner)
                    finish(session, """{"ok":true}""", null)
                }
                BridgeIds.PlatformOps.CANCEL -> {
                    val target = PlatformCancelCommand.targetRequestId(
                        requestId,
                        payload.optString("target_request_id").ifEmpty { null },
                    )
                    if (target != null) {
                        cancel(target)
                    }
                    finish(session, """{"ok":true}""", null)
                }
                BridgeIds.PlatformOps.PICK_PHOTOS -> pickPhotos(session)
                BridgeIds.PlatformOps.SHARE_DISCARD -> {
                    val intakeId = payload.optString("intake_id")
                    val activity = activityRef.get()
                    if (intakeId.isNotBlank() && activity != null) {
                        ShareIntake.discard(activity.filesDir, intakeId)
                    } else if (intakeId.isNotBlank()) {
                        ShareIntake.requestCancel(intakeId)
                    }
                    finish(session, """{"ok":true}""", null)
                }
                else -> finish(session, null, "unknown_op")
            }
        }

        fun importContentUri(requestId: String, generation: Int, uri: Uri) {
            val activity = activityRef.get() ?: run {
                deliver(requestId, generation, null, "needs_foreground")
                return
            }
            val session = newSession(requestId, generation) ?: run {
                deliver(requestId, generation, null, "invalid_request_id")
                return
            }
            io.execute {
                try {
                    val source = UriImportSource.fromResolver(activity, uri)
                    runImport(session, source, "picker")
                } catch (_: SecurityException) {
                    finish(session, null, "security")
                } catch (_: IllegalArgumentException) {
                    finish(session, null, "invalid_uri")
                } catch (_: IllegalStateException) {
                    finish(session, null, "resolver_failed")
                }
            }
        }

        fun onCreateDocument(requestId: String?, uri: Uri?) {
            val id = saveSlot.consume(requestId) ?: return
            val session = sessions[id] ?: return
            val snapId = session.snapshotId
            val owner = session.snapshotOwner ?: return
            if (uri == null) {
                snapId?.let { exporter.cancelOwned(it, owner) }
                finish(session, """{"outcome":"cancelled"}""", null)
                return
            }
            io.execute {
                try {
                    if (session.cancelled.get()) {
                        snapId?.let { exporter.cancelOwned(it, owner) }
                        finish(session, """{"outcome":"cancelled"}""", null)
                        return@execute
                    }
                    val outcome = exporter.streamTo(uri, snapId ?: "", owner, session.cancelled)
                    exporter.cancelOwned(snapId ?: "", owner)
                    finish(session, """{"outcome":"$outcome"}""", null)
                } catch (_: java.util.concurrent.CancellationException) {
                    snapId?.let { exporter.cancelOwned(it, owner) }
                    finish(session, """{"outcome":"cancelled"}""", null)
                } catch (e: IllegalStateException) {
                    snapId?.let { exporter.cancelOwned(it, owner) }
                    finish(session, null, e.message ?: "save_failed")
                } catch (e: java.io.IOException) {
                    snapId?.let { exporter.cancelOwned(it, owner) }
                    finish(session, null, e.message ?: "save_failed")
                }
            }
        }

        private fun importLocal(session: HostSession, payload: JSONObject) {
            val path = payload.optString("path")
            if (path.isEmpty() || !trustedImportFile(File(path))) {
                finish(session, null, "missing_source")
                return
            }
            val source = FileImportSource(
                File(path),
                payload.optString("display_name", File(path).name),
                payload.optString("mime").ifEmpty { null },
            )
            runImport(session, source, "picker")
        }

        private fun runImport(session: HostSession, source: ImportSource, origin: String) {
            importer.importAsync(
                session.requestId,
                source,
                origin,
                session.generation,
                session.cancelled,
            ) { _, _, result ->
                when (result) {
                    is ImportResult.Ok -> {
                        val produced = File(result.attachment.controlledPath)
                        if (session.cancelled.get()) {
                            produced.delete()
                            finish(session, """{"cancelled":true}""", null)
                        } else {
                            session.lateFile = produced
                            finish(session, result.attachment.toSmallJson(), null)
                            session.lateFile = null
                        }
                    }
                    ImportResult.Cancelled -> finish(session, """{"cancelled":true}""", null)
                    is ImportResult.Error -> finish(session, null, result.reason)
                }
            }
        }

        private fun trustedImportFile(file: File): Boolean {
            val resolved = file.canonicalFile
            return listOf(importRoot, File(cacheDir, "camera_capture")).any { allowed ->
                val root = allowed.canonicalFile
                resolved.isFile && resolved.path.startsWith(root.path + File.separator)
            }
        }

        private fun export(session: HostSession, payload: JSONObject) {
            val workspace = payload.optString("workspace_path")
            if (workspace.isEmpty()) {
                finish(session, null, "workspace_required")
                return
            }
            exporter.prepareAsync(
                session.requestId,
                payload.optString("path"),
                workspace,
                session.cancelled,
            ) { _, snap, error ->
                if (session.cancelled.get()) {
                    snap?.let { exporter.cancelOwned(it.snapshotId, it.ownerRequestId) }
                    finish(session, """{"outcome":"cancelled"}""", null)
                } else if (snap != null) {
                    session.snapshotId = snap.snapshotId
                    finish(
                        session,
                        """{"snapshot_id":${ImportedAttachment.json(snap.snapshotId)},"display_name":${ImportedAttachment.json(snap.displayName)},"size_bytes":${snap.sizeBytes},"state":${ImportedAttachment.json(snap.state)},"owner_request_id":${ImportedAttachment.json(snap.ownerRequestId)}}""",
                        null,
                    )
                } else {
                    finish(session, null, error)
                }
            }
        }

        private fun share(session: HostSession, payload: JSONObject) {
            launchExternal(session, payload) { activity, snapId ->
                val owner = payload.optString("owner_request_id").ifEmpty { session.requestId }
                activity.startActivity(
                    android.content.Intent.createChooser(
                        exporter.shareIntent(snapId, owner),
                        "Share",
                    ),
                )
                exporter.markHandedOff(snapId)
                """{"outcome":"chooser_presented"}"""
            }
        }

        private fun open(session: HostSession, payload: JSONObject) {
            launchExternal(session, payload) { activity, snapId ->
                val owner = payload.optString("owner_request_id").ifEmpty { session.requestId }
                activity.startActivity(exporter.openIntent(snapId, owner))
                exporter.markHandedOff(snapId)
                """{"outcome":"ui_presented"}"""
            }
        }

        private fun openUrl(session: HostSession, payload: JSONObject) {
            launchExternal(session, payload) { activity, _ ->
                activity.startActivity(IntentBuilder.viewHttp(payload.optString("url")))
                """{"outcome":"ui_presented"}"""
            }
        }

        private fun appSettings(session: HostSession, payload: JSONObject) {
            val activity = activityRef.get()
            if (activity == null) {
                finish(session, """{"outcome":"needs_foreground"}""", null)
                return
            }
            when (payload.optString("settings_action")) {
                "calendar_status" -> {
                    val read = DeviceCalendar.readGranted(activity)
                    val write = DeviceCalendar.writeGranted(activity)
                    finish(
                        session,
                        """{"outcome":"listed","calendar_read":$read,"calendar_write":$write}""",
                        null,
                    )
                }
                "request_calendar" -> {
                    CalendarAccess.ensure(activity) { granted ->
                        val read = DeviceCalendar.readGranted(activity)
                        val write = DeviceCalendar.writeGranted(activity)
                        val outcome = if (granted) "granted" else "permission_denied"
                        finish(
                            session,
                            """{"outcome":"$outcome","calendar_read":$read,"calendar_write":$write}""",
                            null,
                        )
                    }
                }
                "open_app_settings" -> {
                    launchExternal(session, payload) { current, _ ->
                        val intent = android.content.Intent(
                            android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            android.net.Uri.fromParts("package", current.packageName, null),
                        )
                        current.startActivity(intent)
                        """{"outcome":"ui_presented"}"""
                    }
                }
                else -> finish(session, """{"outcome":"invalid_input"}""", null)
            }
        }

        private fun deviceCalendar(session: HostSession, payload: JSONObject) {
            val activity = activityRef.get()
            if (activity == null || activity.isFinishing) {
                finish(session, """{"outcome":"needs_foreground"}""", null)
                return
            }
            CalendarAccess.ensure(activity) { granted ->
                if (!granted) {
                    finish(session, """{"outcome":"permission_denied"}""", null)
                    return@ensure
                }
                io.execute {
                    if (session.cancelled.get()) {
                        finish(session, """{"outcome":"cancelled_before_launch"}""", null)
                        return@execute
                    }
                    try {
                        val result = when (payload.optString("action")) {
                            "list_calendars" -> DeviceCalendar.listCalendars(activity)
                            "list_events" -> DeviceCalendar.listEvents(activity, payload)
                            "insert_event" -> DeviceCalendar.insertEvent(activity, payload)
                            else -> throw IllegalArgumentException("invalid_action")
                        }
                        finish(session, result.toString(), null)
                    } catch (_: SecurityException) {
                        finish(session, """{"outcome":"permission_denied"}""", null)
                    } catch (e: IllegalArgumentException) {
                        finish(session, outcomeJson(e.message ?: "invalid_input"), null)
                    } catch (e: IllegalStateException) {
                        finish(session, outcomeJson(e.message ?: "no_calendar"), null)
                    }
                }
            }
        }

        private fun outcomeJson(outcome: String): String {
            val safe = when (outcome) {
                "invalid_time", "invalid_title", "invalid_action", "invalid_input",
                "no_calendar", "insert_failed", "permission_denied",
                -> outcome
                else -> "invalid_input"
            }
            return """{"outcome":"$safe"}"""
        }

        private fun deviceAlarm(session: HostSession, payload: JSONObject) {
            launchExternal(session, payload) { activity, _ ->
                val intent = DeviceAlarm.intent(payload)
                activity.startActivity(intent)
                val hour = payload.optInt("hour")
                val minute = payload.optInt("minute")
                """{"outcome":"alarm_prefilled","hour":$hour,"minute":$minute}"""
            }
        }

        private fun shareText(session: HostSession, payload: JSONObject) {
            launchExternal(session, payload) { activity, _ ->
                val text = payload.optString("text")
                if (text.isBlank()) {
                    throw IllegalArgumentException("empty")
                }
                val intent = android.content.Intent(android.content.Intent.ACTION_SEND).apply {
                    type = "text/plain"
                    putExtra(android.content.Intent.EXTRA_TEXT, text)
                }
                activity.startActivity(android.content.Intent.createChooser(intent, null))
                """{"outcome":"chooser_presented"}"""
            }
        }

        private fun launchExternal(
            session: HostSession,
            payload: JSONObject,
            start: (Activity, String) -> String,
        ) {
            val deadline = payload.optLong("deadline_ms", 0L)
            val expired = deadline > 0 && System.currentTimeMillis() > deadline
            if (session.cancelled.get() || expired) {
                if (session.launchGate.cancelBeforeLaunch()) {
                    finish(session, """{"outcome":"cancelled_before_launch"}""", null)
                }
                return
            }
            val activity = activityRef.get()
            if (activity == null) {
                finish(session, """{"outcome":"needs_foreground"}""", null)
                return
            }
            activity.runOnUiThread {
                if (session.cancelled.get() ||
                    (deadline > 0 && System.currentTimeMillis() > deadline)
                ) {
                    if (session.launchGate.cancelBeforeLaunch()) {
                        finish(session, """{"outcome":"cancelled_before_launch"}""", null)
                    }
                    return@runOnUiThread
                }
                val current = com.example.handbean_probe.MobBridge.activity()
                val owner = activity as? androidx.lifecycle.LifecycleOwner
                val resumed = current === activity &&
                    !activity.isFinishing &&
                    owner != null &&
                    owner.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)
                if (!resumed) {
                    finish(session, """{"outcome":"needs_foreground"}""", null)
                    return@runOnUiThread
                }
                if (!session.launchGate.beginDispatch()) {
                    finish(session, """{"outcome":"cancelled_before_launch"}""", null)
                    return@runOnUiThread
                }
                if (session.cancelled.get() ||
                    (deadline > 0 && System.currentTimeMillis() > deadline)
                ) {
                    finish(session, """{"outcome":"cancelled_before_launch"}""", null)
                    return@runOnUiThread
                }
                try {
                    val result = start(activity, payload.optString("snapshot_id"))
                    session.launchGate.markLaunched()
                    finish(session, result, null)
                } catch (_: ActivityNotFoundException) {
                    finish(session, """{"outcome":"no_handler"}""", null)
                } catch (_: IllegalArgumentException) {
                    finish(session, """{"outcome":"invalid_input"}""", null)
                } catch (_: SecurityException) {
                    finish(session, """{"outcome":"launch_failed"}""", null)
                } catch (_: IllegalStateException) {
                    finish(session, """{"outcome":"file_unavailable"}""", null)
                }
            }
        }

        private fun save(session: HostSession, payload: JSONObject) {
            val activity = activityRef.get() as? com.example.handbean_probe.MainActivity
            val snapshotId = payload.optString("snapshot_id")
            val owner = payload.optString("owner_request_id").ifEmpty { session.requestId }
            val snap = exporter.get(snapshotId, owner)
            if (snap == null) {
                finish(session, null, "unknown_snapshot")
                return
            }
            if (activity == null || com.example.handbean_probe.MobBridge.activity() !== activity || activity.isFinishing) {
                finish(session, null, "needs_foreground")
                return
            }
            if (session.cancelled.get()) {
                finish(session, """{"outcome":"cancelled"}""", null)
                return
            }
            if (!saveSlot.reserve(session.requestId)) {
                finish(session, null, "save_busy")
                return
            }
            session.snapshotId = snapshotId
            session.snapshotOwner = owner
            exporter.markSavePending(snapshotId)
            activity.runOnUiThread {
                if (session.cancelled.get()) {
                    exporter.cancelOwned(snapshotId, owner)
                    saveSlot.cancel(session.requestId)
                    finish(session, """{"outcome":"cancelled"}""", null)
                    return@runOnUiThread
                }
                if (!saveSlot.beginDispatch(session.requestId)) return@runOnUiThread
                try {
                    activity.launchCreateDocument(
                        session.requestId,
                        snap.displayName,
                        snap.mime ?: "application/octet-stream",
                    )
                    saveSlot.accepted(session.requestId)
                } catch (_: IllegalStateException) {
                    saveSlot.cancel(session.requestId)
                    exporter.cancelOwned(snapshotId, owner)
                    finish(session, null, "needs_foreground")
                }
            }
        }

        private fun finish(session: HostSession, result: String?, error: String?) {
            if (!session.completion.finishOnce()) return
            sessions.remove(session.requestId, session)
            deliver(session.requestId, session.generation, result, error)
        }
    }
}
