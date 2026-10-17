package com.example.handbean_probe.attachments

import java.io.File
import java.util.UUID

data class FileFingerprint(val size: Long, val mtime: Long)

data class ExportSnapshot(
    val snapshotId: String,
    val path: String,
    val displayName: String,
    val sizeBytes: Long,
    val mime: String?,
    val state: String,
    val ownerRequestId: String = "",
)

object ExportSnapshotCopy {
    fun fingerprint(file: File): FileFingerprint {
        if (!file.isFile || file.isDirectory) throw IllegalStateException("not_regular")
        return FileFingerprint(file.length(), file.lastModified())
    }

    fun copyChecked(
        source: File,
        destDir: File,
        maxBytes: Long = ExportLimits.MAX_BYTES,
        ownerRequestId: String = "",
    ): ExportSnapshot {
        if (!source.isFile) throw IllegalStateException("not_regular")
        val before = fingerprint(source)
        if (before.size > maxBytes) throw IllegalStateException("too_large")
        destDir.mkdirs()
        val id = UUID.randomUUID().toString()
        val dest = File(destDir, id)
        source.inputStream().use { input ->
            BoundedCopy.copy(input, destDir, maxBytes, id).getOrThrow()
        }
        val after = fingerprint(source)
        if (after != before) {
            dest.delete()
            throw IllegalStateException("source_changed")
        }
        return ExportSnapshot(
            snapshotId = id,
            path = dest.absolutePath,
            displayName = source.name,
            sizeBytes = dest.length(),
            mime = IntentBuilder.mimeForName(source.name),
            state = "held",
            ownerRequestId = ownerRequestId,
        )
    }

    fun cleanup(file: File) {
        file.delete()
    }

    fun cleanupOrphans(dir: File, now: Long, ttlMs: Long = ExportLimits.TTL_MS) {
        dir.listFiles()?.forEach { file ->
            if (file.isFile && now - file.lastModified() > ttlMs) file.delete()
        }
    }
}
