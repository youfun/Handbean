package com.example.handbean_probe.attachments

import android.app.Activity
import android.content.Intent
import android.net.Uri
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * App-private pending share intake. Kotlin owns Intent/URI I/O.
 * Manifests never store external URIs. UI thread only allocates IDs.
 */
object ShareIntake {
    const val MAX_PENDING = 8
    const val DIR_NAME = "share_intake"
    const val INTERRUPTED = "interrupted"
    const val OVERFLOW = "too_many_pending"
    const val STORAGE_ERROR = "storage_error"
    const val CONSUMPTION_STRUCTURED = "structured_attachments"
    const val CONSUMPTION_WORKSPACE = "workspace_copy"
    const val RECEIPTS_DIR = "receipts"
    const val SEQ_FILE = "seq"

    enum class ResumeAction { RETRY_IMPORT, NOTIFY, TERMINAL }

    private val terminalStates = setOf("acknowledged", "cancelled")

    @Volatile
    var io: Executor = Executors.newSingleThreadExecutor()
    private val lock = Any()
    private val cancelled = ConcurrentHashMap<String, AtomicBoolean>()
    private val bootRecovered = AtomicBoolean(false)
    private val seq = AtomicLong(0)

    @Volatile
    var nowMs: () -> Long = { System.currentTimeMillis() }

    @Volatile
    var nextSeq: () -> Long = { seq.incrementAndGet() }

    val shareImageRewriter: (File, String) -> File = { file, mime ->
        ImageNormalizer.normalize(file, mime)
    }

    var deliverReady: (String, String) -> Unit = { intakeId, status ->
        com.example.handbean_probe.BrowserEngine.nativeShareIntakeReady(intakeId, status)
    }

    var writeProbe: ((File, JSONObject) -> Unit)? = null
    var atomicRename: (File, File) -> Boolean = { from, to -> from.renameTo(to) }

    fun resetBootRecoverForTest() {
        bootRecovered.set(false)
        seq.set(0)
        cancelled.clear()
        nowMs = { System.currentTimeMillis() }
        nextSeq = { seq.incrementAndGet() }
    }

    fun root(filesDir: File): File = File(filesDir, DIR_NAME)

    fun receiptsDir(filesDir: File): File = File(root(filesDir), RECEIPTS_DIR)

    fun allocateSeq(filesDir: File): Long {
        synchronized(lock) {
            val persisted = readPersistedSeq(filesDir)
            val scanned = maxManifestSeq(filesDir)
            val next = maxOf(seq.get(), persisted, scanned) + 1
            seq.set(next)
            writePersistedSeq(filesDir, next)
            return next
        }
    }

    fun writeReceipt(filesDir: File, intakeId: String, state: String) {
        val file = File(receiptsDir(filesDir), "$intakeId.json")
        writeAtomic(
            file,
            JSONObject()
                .put("intake_id", intakeId)
                .put("state", state)
                .put("terminal", true),
        )
    }

    fun readReceipt(filesDir: File, intakeId: String): JSONObject? =
        readJson(File(receiptsDir(filesDir), "$intakeId.json"))

    fun resumeAction(filesDir: File, intakeId: String): ResumeAction {
        val receipt = readReceipt(filesDir, intakeId)
        if (receipt != null && receipt.optString("state") in terminalStates) {
            return ResumeAction.TERMINAL
        }
        val json = readJson(manifestFile(filesDir, intakeId))
        if (json == null) return ResumeAction.RETRY_IMPORT
        return if (json.optString("state") in terminalStates) {
            ResumeAction.TERMINAL
        } else {
            ResumeAction.NOTIFY
        }
    }

    fun cancellation(intakeId: String): AtomicBoolean =
        cancelled.getOrPut(intakeId) { AtomicBoolean(false) }

    fun requestCancel(intakeId: String) {
        cancellation(intakeId).set(true)
    }

    fun scheduleRecover(filesDir: File) {
        io.execute { ensureBootRecover(filesDir) }
    }

    fun classifyConsumption(uriStrings: List<String>, mimeOf: (String) -> String?): String {
        if (uriStrings.isEmpty()) return CONSUMPTION_STRUCTURED
        val allImages = uriStrings.all { raw ->
            val mime = mimeOf(raw) ?: ""
            mime.startsWith("image/")
        }
        return if (allImages) CONSUMPTION_STRUCTURED else CONSUMPTION_WORKSPACE
    }

    fun classifyConsumption(parsed: ParsedShare, mimeOf: (Uri) -> String?): String =
        classifyConsumption(parsed.contentUris.map { it.toString() }) { raw ->
            mimeOf(Uri.parse(raw))
        }

    fun submit(activity: Activity, intent: Intent, savedIntakeId: String?): String? =
        submit(activity, intent, savedIntakeId, false)

    fun submit(
        activity: Activity,
        intent: Intent,
        savedIntakeId: String?,
        recreate: Boolean,
    ): String? {
        if (!ShareIntentParser.isShare(intent)) return null
        val filesDir = activity.filesDir
        val parsed = ShareIntentParser.parse(intent)
        val consumption = classifyConsumption(parsed) { uri ->
            runCatching { activity.contentResolver.getType(uri) }.getOrNull() ?: intent.type
        }

        if (recreate && !savedIntakeId.isNullOrBlank()) {
            io.execute {
                try {
                    resumeSaved(activity, filesDir, savedIntakeId, parsed, consumption)
                } catch (e: IOException) {
                    markStorageError(filesDir, savedIntakeId)
                }
            }
            return savedIntakeId
        }

        val intakeId = UUID.randomUUID().toString()
        io.execute {
            try {
                admitAndImport(activity, filesDir, intakeId, parsed, consumption)
            } catch (e: IOException) {
                markStorageError(filesDir, intakeId)
            }
        }
        return intakeId
    }

    fun discard(filesDir: File, intakeId: String) {
        requestCancel(intakeId)
        io.execute {
            try {
                writeReceipt(filesDir, intakeId, "cancelled")
            } catch (_: IOException) {
            }
            deleteIntakeDir(filesDir, intakeId)
        }
    }

    fun ensureBootRecover(filesDir: File) {
        if (bootRecovered.compareAndSet(false, true)) {
            recoverAfterDeath(filesDir)
        }
    }

    fun recoverAfterDeath(filesDir: File) {
        val root = root(filesDir)
        if (!root.isDirectory) return
        root.listFiles()?.forEach { dir ->
            if (!dir.isDirectory || dir.name == RECEIPTS_DIR) return@forEach
            val manifest = File(dir, "manifest.json")
            val json = readJson(manifest) ?: return@forEach
            try {
                when (json.optString("state")) {
                    "merged_current_process" -> {
                        json.put("state", "pending_review")
                        writeAtomic(manifest, json)
                    }
                    "received", "importing" -> {
                        val errors = json.optJSONArray("errors") ?: JSONArray()
                        errors.put(JSONObject().put("reason", INTERRUPTED))
                        json.put("errors", errors)
                        val attachments = json.optJSONArray("attachments")
                        val files = json.optJSONArray("files")
                        val hasFiles =
                            (attachments != null && attachments.length() > 0) ||
                                (files != null && (0 until files.length()).any {
                                    files.optJSONObject(it)?.optString("status") == "ready"
                                })
                        val hasText = json.optString("text").isNotBlank() ||
                            json.optString("subject").isNotBlank()
                        json.put("state", if (hasFiles || hasText) "pending_review" else "failed")
                        writeAtomic(manifest, json)
                    }
                }
            } catch (_: IOException) {
                markStorageError(filesDir, json.optString("intake_id", dir.name))
            }
        }
    }

    fun countActive(filesDir: File): Int {
        val root = root(filesDir)
        if (!root.isDirectory) return 0
        return root.listFiles()?.count { dir ->
            if (!dir.isDirectory || dir.name == RECEIPTS_DIR) return@count false
            val json = readJson(File(dir, "manifest.json")) ?: return@count false
            json.optString("state") !in terminalStates
        } ?: 0
    }

    fun admit(filesDir: File): Boolean = countActive(filesDir) < MAX_PENDING

    fun shareImporter(dir: File): ControlledImport =
        ControlledImport(
            stagingRoot = dir,
            imageRewriter = shareImageRewriter,
        )

    fun listReviewIds(filesDir: File): List<String> {
        val root = root(filesDir)
        if (!root.isDirectory) return emptyList()
        return root.listFiles().orEmpty()
            .mapNotNull { dir ->
                if (!dir.isDirectory || dir.name == RECEIPTS_DIR) return@mapNotNull null
                val json = readJson(File(dir, "manifest.json")) ?: return@mapNotNull null
                val state = json.optString("state")
                if (state !in setOf("pending_review", "failed", "outcome_unknown")) return@mapNotNull null
                Triple(
                    json.optString("intake_id", dir.name),
                    json.optLong("created_at", Long.MAX_VALUE),
                    json.optLong("created_seq", Long.MAX_VALUE),
                )
            }
            .sortedWith(compareBy({ it.second }, { it.third }))
            .map { it.first }
            .take(MAX_PENDING)
    }

    private fun resumeSaved(
        activity: Activity,
        filesDir: File,
        intakeId: String,
        parsed: ParsedShare,
        consumption: String,
    ) {
        ensureBootRecover(filesDir)
        when (resumeAction(filesDir, intakeId)) {
            ResumeAction.TERMINAL -> return
            ResumeAction.RETRY_IMPORT ->
                admitAndImport(activity, filesDir, intakeId, parsed, consumption)
            ResumeAction.NOTIFY -> {
                val json = readJson(manifestFile(filesDir, intakeId)) ?: return
                deliverReady(intakeId, json.optString("state"))
            }
        }
    }

    private fun admitAndImport(
        activity: Activity,
        filesDir: File,
        intakeId: String,
        parsed: ParsedShare,
        consumption: String,
    ) {
        ensureBootRecover(filesDir)
        if (!admit(filesDir)) {
            deliverReady(intakeId, OVERFLOW)
            return
        }
        if (cancellation(intakeId).get()) return
        val dir = File(root(filesDir), intakeId)
        dir.mkdirs()
        val createdAt = nowMs()
        val createdSeq = allocateSeq(filesDir)
        val initial = JSONObject()
            .put("intake_id", intakeId)
            .put("state", "received")
            .put("consumption", consumption)
            .put("created_at", createdAt)
            .put("created_seq", createdSeq)
            .put("subject", parsed.subject ?: JSONObject.NULL)
            .put("text", parsed.texts.joinToString("\n\n"))
            .put("text_truncated", parsed.textTruncated)
            .put("errors", JSONArray(parsed.errors))
            .put("attachments", JSONArray())
            .put("files", JSONArray())
        writeAtomic(File(dir, "manifest.json"), initial)
        if (cancellation(intakeId).get()) {
            deleteIntakeDir(filesDir, intakeId)
            return
        }
        importPayload(activity, filesDir, intakeId, parsed, consumption)
    }

    private fun importPayload(
        activity: Activity,
        filesDir: File,
        intakeId: String,
        parsed: ParsedShare,
        consumption: String,
    ) {
        if (consumption == CONSUMPTION_WORKSPACE) {
            importWorkspaceFiles(activity, filesDir, intakeId, parsed.contentUris)
        } else {
            importStreams(activity, filesDir, intakeId, parsed.contentUris)
        }
    }

    private fun importStreams(
        activity: Activity,
        filesDir: File,
        intakeId: String,
        uris: List<Uri>,
    ) {
        val cancelledFlag = cancellation(intakeId)
        if (cancelledFlag.get()) return
        val dir = File(root(filesDir), intakeId)
        val manifest = File(dir, "manifest.json")
        val json = readJson(manifest) ?: return
        json.put("state", "importing")
        writeAtomic(manifest, json)

        val importer = shareImporter(dir)
        val attachments = json.optJSONArray("attachments") ?: JSONArray()
        val errors = json.optJSONArray("errors") ?: JSONArray()
        var batchBytes = 0L
        for (i in 0 until attachments.length()) {
            batchBytes += attachments.optJSONObject(i)?.optLong("size_bytes") ?: 0L
        }

        uris.take(AttachmentLimits.MAX_COUNT).forEach { uri ->
            if (cancelledFlag.get()) return
            try {
                val source = UriImportSource.fromResolver(activity, uri)
                if (batchBytes + (source.declaredSize ?: 0L) > AttachmentLimits.MAX_BATCH_BYTES &&
                    source.declaredSize != null
                ) {
                    errors.put(JSONObject().put("reason", "batch_too_large"))
                    return@forEach
                }
                when (val result = importer.importNow(source, "share", cancelledFlag)) {
                    is ImportResult.Ok -> {
                        val next = batchBytes + result.attachment.sizeBytes
                        if (attachments.length() >= AttachmentLimits.MAX_COUNT || next > AttachmentLimits.MAX_BATCH_BYTES) {
                            File(result.attachment.controlledPath).delete()
                            errors.put(
                                JSONObject().put(
                                    "reason",
                                    if (attachments.length() >= AttachmentLimits.MAX_COUNT) {
                                        "too_many_attachments"
                                    } else {
                                        "batch_too_large"
                                    },
                                ),
                            )
                        } else {
                            batchBytes = next
                            attachments.put(JSONObject(result.attachment.toSmallJson()))
                        }
                    }
                    ImportResult.Cancelled -> return
                    is ImportResult.Error -> errors.put(JSONObject().put("reason", result.reason))
                }
            } catch (_: SecurityException) {
                errors.put(JSONObject().put("reason", "no_grant"))
            } catch (_: IllegalArgumentException) {
                errors.put(JSONObject().put("reason", "invalid_uri"))
            } catch (_: IllegalStateException) {
                errors.put(JSONObject().put("reason", "resolver_failed"))
            } catch (_: IOException) {
                errors.put(JSONObject().put("reason", "stream_failed"))
            }
        }

        if (cancelledFlag.get()) {
            deleteIntakeDir(filesDir, intakeId)
            return
        }

        if (uris.size > AttachmentLimits.MAX_COUNT) {
            errors.put(JSONObject().put("reason", "too_many_attachments"))
        }

        finishImport(filesDir, intakeId, json, attachments, json.optJSONArray("files") ?: JSONArray(), errors)
    }

    private fun importWorkspaceFiles(
        activity: Activity,
        filesDir: File,
        intakeId: String,
        uris: List<Uri>,
    ) {
        val cancelledFlag = cancellation(intakeId)
        if (cancelledFlag.get()) return
        val dir = File(root(filesDir), intakeId)
        val destDir = File(dir, "files")
        val manifest = File(dir, "manifest.json")
        val json = readJson(manifest) ?: return
        json.put("state", "importing")
        writeAtomic(manifest, json)

        val files = json.optJSONArray("files") ?: JSONArray()
        val errors = json.optJSONArray("errors") ?: JSONArray()
        var copiedBytes = 0L
        for (i in 0 until files.length()) {
            copiedBytes += files.optJSONObject(i)?.optLong("size") ?: 0L
        }

        uris.take(AttachmentLimits.MAX_COUNT).forEachIndexed { index, uri ->
            if (cancelledFlag.get()) return
            val remaining = AttachmentLimits.MAX_BATCH_BYTES - copiedBytes
            when (val staged = ShareFileStager.stage(activity, uri, destDir, index, remaining)) {
                is ShareFileStager.StageResult.Ready -> {
                    copiedBytes += staged.size
                    files.put(ShareFileStager.toJson(staged))
                }
                is ShareFileStager.StageResult.Rejected -> {
                    files.put(ShareFileStager.toJson(staged))
                    errors.put(JSONObject().put("reason", staged.reason))
                }
            }
        }

        if (cancelledFlag.get()) {
            deleteIntakeDir(filesDir, intakeId)
            return
        }

        if (uris.size > AttachmentLimits.MAX_COUNT) {
            errors.put(JSONObject().put("reason", "too_many_files"))
        }

        finishImport(filesDir, intakeId, json, json.optJSONArray("attachments") ?: JSONArray(), files, errors)
    }

    private fun finishImport(
        filesDir: File,
        intakeId: String,
        json: JSONObject,
        attachments: JSONArray,
        files: JSONArray,
        errors: JSONArray,
    ) {
        if (cancellation(intakeId).get() || readReceipt(filesDir, intakeId) != null) {
            deleteIntakeDir(filesDir, intakeId)
            return
        }
        val readyFiles = (0 until files.length()).any {
            files.optJSONObject(it)?.optString("status") == "ready"
        }
        val empty = attachments.length() == 0 &&
            !readyFiles &&
            json.optString("text").isBlank() &&
            json.optString("subject").isBlank()
        json.put("attachments", attachments)
        json.put("files", files)
        json.put("errors", errors)
        json.put("state", if (empty && errors.length() > 0) "failed" else "pending_review")
        writeAtomic(manifestFile(filesDir, intakeId), json)
        deliverReady(intakeId, json.optString("state"))
        cancelled.remove(intakeId)
    }

    private fun deleteIntakeDir(filesDir: File, intakeId: String) {
        val dir = File(root(filesDir), intakeId)
        val root = root(filesDir).canonicalFile
        val resolved = dir.canonicalFile
        if (!resolved.path.startsWith(root.path + File.separator) && resolved != root) return
        if (resolved.path.startsWith(root.path + File.separator)) {
            resolved.deleteRecursively()
        }
    }

    private fun manifestFile(filesDir: File, intakeId: String) =
        File(File(root(filesDir), intakeId), "manifest.json")

    private fun readJson(file: File): JSONObject? {
        if (!file.isFile) return null
        return try {
            JSONObject(file.readText())
        } catch (_: JSONException) {
            null
        } catch (_: IOException) {
            null
        }
    }

    private fun markStorageError(filesDir: File, intakeId: String) {
        try {
            val manifest = manifestFile(filesDir, intakeId)
            val json = readJson(manifest) ?: JSONObject().put("intake_id", intakeId)
            val errors = json.optJSONArray("errors") ?: JSONArray()
            errors.put(JSONObject().put("reason", STORAGE_ERROR))
            json.put("errors", errors)
            json.put("state", "failed")
            writeAtomic(manifest, json)
        } catch (_: IOException) {
        }
        deliverReady(intakeId, STORAGE_ERROR)
    }

    private fun writeAtomic(file: File, json: JSONObject) {
        writeProbe?.invoke(file, json)
        synchronized(lock) {
            val parent = file.parentFile ?: throw IOException("missing parent")
            if (!parent.isDirectory && !parent.mkdirs() && !parent.isDirectory) {
                throw IOException("mkdir failed")
            }
            val partial = File(parent, file.name + ".partial")
            partial.writeText(json.toString())
            if (!atomicRename(partial, file)) {
                partial.delete()
                throw IOException("rename failed")
            }
        }
    }

    private fun readPersistedSeq(filesDir: File): Long {
        val file = File(root(filesDir), SEQ_FILE)
        if (!file.isFile) return 0L
        return file.readText().trim().toLongOrNull() ?: 0L
    }

    private fun writePersistedSeq(filesDir: File, value: Long) {
        val root = root(filesDir)
        root.mkdirs()
        File(root, SEQ_FILE).writeText(value.toString())
    }

    private fun maxManifestSeq(filesDir: File): Long {
        val root = root(filesDir)
        if (!root.isDirectory) return 0L
        return root.listFiles()?.maxOfOrNull { dir ->
            if (!dir.isDirectory || dir.name == RECEIPTS_DIR) 0L
            else readJson(File(dir, "manifest.json"))?.optLong("created_seq") ?: 0L
        } ?: 0L
    }
}
