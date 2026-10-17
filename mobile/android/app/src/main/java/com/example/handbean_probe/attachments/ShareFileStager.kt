package com.example.handbean_probe.attachments

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import org.json.JSONObject
import java.io.File
import java.io.InputStream
import java.io.OutputStream

/** Bounded staging for general/mixed share files. Not ControlledImport. */
object ShareFileStager {
    const val MAX_ITEM_BYTES = 20L * 1024L * 1024L

    class TooLarge : Exception()

    sealed class StageResult {
        data class Ready(
            val name: String,
            val mime: String,
            val size: Long,
            val path: String,
        ) : StageResult()

        data class Rejected(
            val name: String,
            val mime: String,
            val reason: String,
        ) : StageResult()
    }

    fun stage(
        context: Context,
        uri: Uri,
        destDir: File,
        index: Int,
        remainingBatch: Long,
    ): StageResult {
        val meta = metadata(context, uri, index)
        val name = meta.first
        val mime = meta.second
        val declared = meta.third

        if (uri.scheme != "content") {
            return StageResult.Rejected(name, mime, "unsupported_uri")
        }
        if (declared != null && declared > MAX_ITEM_BYTES) {
            return StageResult.Rejected(name, mime, "file_too_large")
        }
        if (remainingBatch <= 0L) {
            return StageResult.Rejected(name, mime, "batch_too_large")
        }

        val destination = uniqueFile(destDir, name)
        return try {
            destDir.mkdirs()
            val input = context.contentResolver.openInputStream(uri)
                ?: throw IllegalStateException("stream unavailable")
            val size = input.use { source ->
                destination.outputStream().use { target ->
                    copyBounded(source, target, minOf(MAX_ITEM_BYTES, remainingBatch))
                }
            }
            StageResult.Ready(destination.name, mime, size, destination.absolutePath)
        } catch (error: Exception) {
            destination.delete()
            val reason = when {
                error !is TooLarge -> "copy_failed"
                remainingBatch < MAX_ITEM_BYTES -> "batch_too_large"
                else -> "file_too_large"
            }
            StageResult.Rejected(name, mime, reason)
        }
    }

    fun toJson(result: StageResult): JSONObject =
        when (result) {
            is StageResult.Ready ->
                JSONObject()
                    .put("name", result.name)
                    .put("mime", result.mime)
                    .put("size", result.size)
                    .put("path", result.path)
                    .put("status", "ready")
            is StageResult.Rejected ->
                JSONObject()
                    .put("name", result.name)
                    .put("mime", result.mime)
                    .put("status", "rejected")
                    .put("reason", result.reason)
        }

    internal fun safeDisplayName(raw: String?, index: Int): String {
        val sanitized = raw
            ?.replace(Regex("[\\\\/\\u0000-\\u001F\\u007F]"), "_")
            ?.trim('.', ' ', '_')
            .orEmpty()
        return takeUtf8(sanitized, 200).ifEmpty { "shared_file_${index + 1}" }
    }

    internal fun copyBounded(input: InputStream, output: OutputStream, limit: Long): Long {
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        var total = 0L
        while (true) {
            val count = input.read(buffer)
            if (count < 0) return total
            if (total + count > limit) throw TooLarge()
            output.write(buffer, 0, count)
            total += count
        }
    }

    internal fun uniqueFile(root: File, name: String): File {
        var candidate = File(root, name)
        var suffix = 2
        while (candidate.exists()) {
            val dot = name.lastIndexOf('.')
            val stem = if (dot > 0) name.substring(0, dot) else name
            val extension = if (dot > 0) name.substring(dot) else ""
            candidate = File(root, "${stem}_$suffix$extension")
            suffix += 1
        }
        return candidate
    }

    private fun metadata(context: Context, uri: Uri, index: Int): Triple<String, String, Long?> {
        var displayName: String? = null
        var size: Long? = null
        runCatching {
            context.contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (nameIndex >= 0) displayName = cursor.getString(nameIndex)
                    if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) size = cursor.getLong(sizeIndex)
                }
            }
        }
        return Triple(
            safeDisplayName(displayName, index),
            runCatching { context.contentResolver.getType(uri) }.getOrNull()
                ?: "application/octet-stream",
            size,
        )
    }

    private fun takeUtf8(value: String, maxBytes: Int): String {
        var end = value.length
        while (end > 0 && value.substring(0, end).toByteArray(Charsets.UTF_8).size > maxBytes) {
            end -= 1
            if (end > 0 && Character.isHighSurrogate(value[end - 1])) end -= 1
        }
        return value.substring(0, end)
    }

}
