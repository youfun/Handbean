package com.example.handbean_probe.attachments

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import java.io.File
import java.io.FileInputStream
import java.lang.ref.WeakReference
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class ExportSnapshotHandler(
    private val cacheRoot: File,
    private val executor: Executor = Executors.newSingleThreadExecutor(),
) {
    private val snapshots = ConcurrentHashMap<String, ExportSnapshot>()
    private var activityRef: WeakReference<Activity>? = null

    fun attach(activity: Activity) {
        activityRef = WeakReference(activity)
        executor.execute {
            ExportSnapshotCopy.cleanupOrphans(snapshotDir(), System.currentTimeMillis())
        }
    }

    fun detach(activity: Activity) {
        if (activityRef?.get() !== activity) return
        snapshots.entries.removeIf { (_, snap) ->
            if (snap.state == "handed_off" || snap.state == "save_pending") {
                false
            } else {
                ExportSnapshotCopy.cleanup(File(snap.path))
                true
            }
        }
        activityRef = null
    }

    fun snapshotDir(): File = File(cacheRoot, "export_snapshots")

    fun prepareAsync(
        requestId: String,
        sourcePath: String,
        authorizedRoot: String,
        cancelled: AtomicBoolean,
        onResult: (requestId: String, ExportSnapshot?, String?) -> Unit,
    ) {
        executor.execute {
            try {
                if (cancelled.get()) {
                    onResult(requestId, null, "cancelled")
                    return@execute
                }
                if (authorizedRoot.isBlank()) {
                    onResult(requestId, null, "workspace_required")
                    return@execute
                }
                val source = File(sourcePath)
                if (!contained(source, File(authorizedRoot))) {
                    onResult(requestId, null, "outside_workspace")
                    return@execute
                }
                val snap = ExportSnapshotCopy.copyChecked(source, snapshotDir(), ownerRequestId = requestId)
                if (cancelled.get()) {
                    ExportSnapshotCopy.cleanup(File(snap.path))
                    onResult(requestId, null, "cancelled")
                    return@execute
                }
                snapshots[snap.snapshotId] = snap
                onResult(requestId, snap, null)
            } catch (e: IllegalStateException) {
                onResult(requestId, null, e.message ?: "export_failed")
            } catch (e: java.io.IOException) {
                onResult(requestId, null, e.message ?: "export_failed")
            }
        }
    }

    fun get(id: String, requestId: String): ExportSnapshot? {
        val snap = snapshots[id] ?: return null
        if (snap.ownerRequestId.isNotEmpty() && snap.ownerRequestId != requestId) return null
        return snap
    }

    fun cancelOwned(id: String, requestId: String) {
        val snap = snapshots[id] ?: return
        if (snap.ownerRequestId.isNotEmpty() && snap.ownerRequestId != requestId) return
        snapshots.remove(id)
        ExportSnapshotCopy.cleanup(File(snap.path))
    }

    fun shareIntent(id: String, requestId: String): Intent {
        val snap = get(id, requestId) ?: throw IllegalStateException("unknown_snapshot")
        val activity = activityRef?.get() ?: throw IllegalStateException("no_activity")
        val uri = uriFor(activity, File(snap.path), snap.displayName)
        return Intent(Intent.ACTION_SEND).apply {
            type = snap.mime ?: "application/octet-stream"
            putExtra(Intent.EXTRA_STREAM, uri)
            clipData = ClipData.newRawUri(IntentBuilder.safeBasename(snap.displayName), uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
    }

    fun openIntent(id: String, requestId: String): Intent {
        val snap = get(id, requestId) ?: throw IllegalStateException("unknown_snapshot")
        val activity = activityRef?.get() ?: throw IllegalStateException("no_activity")
        val uri = uriFor(activity, File(snap.path), snap.displayName)
        return Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, snap.mime ?: "*/*")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
    }

    fun streamTo(uri: Uri, id: String, requestId: String, cancelled: AtomicBoolean): String {
        val snap = get(id, requestId) ?: throw IllegalStateException("unknown_snapshot")
        val activity = activityRef?.get() ?: throw IllegalStateException("no_activity")
        val out = activity.contentResolver.openOutputStream(uri)
            ?: throw IllegalStateException("null_stream")
        FileInputStream(File(snap.path)).use { input ->
            out.use { output ->
                val buf = ByteArray(64 * 1024)
                var total = 0L
                while (true) {
                    if (cancelled.get()) throw java.util.concurrent.CancellationException("cancelled")
                    val n = input.read(buf)
                    if (n < 0) break
                    total += n
                    if (total > snap.sizeBytes || total > ExportLimits.MAX_BYTES) {
                        throw IllegalStateException("too_large")
                    }
                    output.write(buf, 0, n)
                }
            }
        }
        return "saved"
    }

    fun markHandedOff(id: String) {
        snapshots[id]?.let { snapshots[id] = it.copy(state = "handed_off") }
    }

    fun markSavePending(id: String) {
        snapshots[id]?.let { snapshots[id] = it.copy(state = "save_pending") }
    }

    fun cancel(id: String) {
        snapshots.remove(id)?.let { ExportSnapshotCopy.cleanup(File(it.path)) }
    }

    private fun uriFor(activity: Activity, file: File, displayName: String): Uri {
        return FileProvider.getUriForFile(
            activity,
            "${activity.packageName}.exportprovider",
            file,
            IntentBuilder.safeBasename(displayName),
        )
    }

    private fun contained(file: File, root: File): Boolean {
        val resolved = file.canonicalFile
        val rootResolved = root.canonicalFile
        return resolved == rootResolved || resolved.path.startsWith(rootResolved.path + File.separator)
    }
}
