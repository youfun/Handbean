package com.example.handbean_probe

import android.app.Activity
import android.net.Uri
import androidx.documentfile.provider.DocumentFile
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.ConcurrentHashMap

/**
 * Copies a SAF tree into filesDir/imported_workspaces using a staging directory.
 * Tools never read the tree URI. This does not persist URI grants.
 */
object WorkspaceImport {
    const val MAX_FILES = 10_000
    const val MAX_BYTES = 500L * 1024L * 1024L
    const val MAX_FILE_BYTES = 100L * 1024L * 1024L

    @Volatile
    var activeRequestId: String? = null

    private val cancelledRequests = ConcurrentHashMap.newKeySet<String>()

    fun requestIdFromTypes(typesJson: String): String? {
        return try {
            val array = JSONArray(typesJson)
            for (i in 0 until array.length()) {
                val obj = array.optJSONObject(i) ?: continue
                val id = obj.optString(BridgeIds.FilePick.REQUEST_ID)
                if (id.isNotBlank()) return id
            }
            null
        } catch (_: Exception) {
            Regex("\"${BridgeIds.FilePick.REQUEST_ID}\"\\s*:\\s*\"([^\"]+)\"").find(typesJson)?.groupValues?.getOrNull(1)
        }
    }

    fun isDirectoryPick(typesJson: String): Boolean =
        typesJson.contains("\"${BridgeIds.FilePick.KIND}\":\"${BridgeIds.FilePick.KIND_DIRECTORY}\"") ||
            typesJson.contains("\"${BridgeIds.FilePick.KIND}\": \"${BridgeIds.FilePick.KIND_DIRECTORY}\"")

    fun isCancellation(typesJson: String): Boolean =
        typesJson.contains("\"${BridgeIds.FilePick.KIND_CANCEL_DIRECTORY}\"")

    fun cancel(requestId: String) {
        cancelledRequests.add(requestId)
    }

    fun cancelled(requestId: String?): Boolean =
        requestId != null && cancelledRequests.contains(requestId)

    fun finish(requestId: String) { cancelledRequests.remove(requestId) }

    fun safeName(raw: String?): Result<String> {
        val name = raw.orEmpty()
        if (name.isBlank() || name == "." || name == "..") return Result.failure(UnsafeName())
        if (name.contains('/') || name.contains('\\') || name.contains('\u0000')) {
            return Result.failure(UnsafeName())
        }
        return Result.success(name)
    }

    fun destRoot(activity: Activity): File = File(activity.filesDir, "imported_workspaces")

    fun copyTree(activity: Activity, treeUri: Uri, requestId: String): Result<File> {
        if (cancelled(requestId)) return Result.failure(Cancelled())
        val tree = DocumentFile.fromTreeUri(activity, treeUri)
            ?: return Result.failure(IOException("not a tree uri"))
        return stageTree(destRoot(activity), requestId) { staging ->
            copyDocumentTree(activity, tree, staging, Counters(), requestId).getOrThrow()
        }
    }

    @Synchronized
    internal fun stageTree(root: File, requestId: String, copy: (File) -> Unit): Result<File> {
        if (!Regex("imp_[A-Za-z0-9_-]+").matches(requestId)) return Result.failure(UnsafeName())
        val staging = File(root, ".staging/$requestId")
        val dest = File(root, requestId)
        if (dest.exists() || staging.exists()) return Result.failure(IOException("destination exists"))
        if (!staging.mkdirs()) return Result.failure(IOException("staging"))

        return try {
            if (cancelled(requestId)) throw Cancelled()
            copy(staging)
            if (cancelled(requestId)) {
                staging.deleteRecursively()
                return Result.failure(Cancelled())
            }
            if (dest.exists() || !staging.renameTo(dest)) throw IOException("commit import")
            Result.success(dest)
        } catch (e: Exception) {
            staging.deleteRecursively()
            Result.failure(e)
        }
    }

    private fun copyDocumentTree(
        activity: Activity,
        src: DocumentFile,
        destDir: File,
        counters: Counters,
        requestId: String,
    ): Result<Unit> {
        if (cancelled(requestId)) return Result.failure(Cancelled())
        if (!src.isDirectory || !src.canRead()) return Result.failure(IOException("read directory"))
        for (child in src.listFiles()) {
            if (cancelled(requestId)) return Result.failure(Cancelled())
            val name = safeName(child.name).getOrElse { return Result.failure(it) }
            counters.files += 1
            if (counters.files > MAX_FILES) return Result.failure(TooLarge())
            if (File(destDir, name).exists()) return Result.failure(IOException("duplicate name"))
            if (child.isDirectory) {
                val nested = File(destDir, name)
                if (!nested.mkdirs() && !nested.isDirectory) {
                    return Result.failure(IOException("mkdir"))
                }
                copyDocumentTree(activity, child, nested, counters, requestId).getOrThrow()
            } else if (child.isFile) {
                val out = File(destDir, name)
                activity.contentResolver.openInputStream(child.uri)?.use { input ->
                    out.outputStream().use { output ->
                        copyBounded(input, output, counters, requestId)
                    }
                } ?: return Result.failure(IOException("read"))
            } else {
                return Result.failure(IOException("unsupported document"))
            }
        }
        return Result.success(Unit)
    }

    internal fun copyBounded(input: InputStream, output: OutputStream, counters: Counters,
                             requestId: String, maxFile: Long = MAX_FILE_BYTES,
                             maxTotal: Long = MAX_BYTES) {
        val buffer = ByteArray(8192)
        var fileBytes = 0L
        while (true) {
            if (cancelled(requestId)) throw Cancelled()
            val count = input.read(buffer)
            if (cancelled(requestId)) throw Cancelled()
            if (count < 0) return
            fileBytes += count
            counters.bytes += count
            if (fileBytes > maxFile || counters.bytes > maxTotal) throw TooLarge()
            output.write(buffer, 0, count)
        }
    }

    fun errorJson(requestId: String, reason: String): String =
        JSONArray().put(JSONObject().put("request_id", requestId).put("error", reason)).toString()

    fun resultJson(dest: File, requestId: String, displayName: String): String {
        val obj = JSONObject()
            .put("path", dest.absolutePath)
            .put("name", displayName)
            .put("mime", "inode/directory")
            .put("size", 0)
            .put("request_id", requestId)
        return JSONArray().put(obj).toString()
    }

    class Cancelled : IOException("cancelled")
    class TooLarge : IOException("too_large")
    class UnsafeName : IOException("unsafe_name")

    internal class Counters {
        var files: Int = 0
        var bytes: Long = 0
    }
}
