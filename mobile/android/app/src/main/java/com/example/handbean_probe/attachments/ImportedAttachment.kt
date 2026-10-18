package com.example.handbean_probe.attachments

import java.io.File

data class ImportedAttachment(
    val attachmentId: String,
    val source: String,
    val displayName: String,
    val canonicalType: String,
    val sourceMime: String?,
    val sizeBytes: Long,
    val controlledPath: String,
    val state: String = "staged",
) {
    fun toSmallJson(): String {
        val stagingRoot = File(controlledPath).parentFile?.parentFile?.absolutePath ?: ""
        return """{"attachment_id":${json(attachmentId)},"source":${json(source)},"display_name":${json(displayName)},"canonical_type":${json(canonicalType)},"source_mime":${sourceMime?.let { json(it) } ?: "null"},"size_bytes":$sizeBytes,"controlled_path":${json(controlledPath)},"staging_root":${json(stagingRoot)},"state":${json(state)}}"""
    }

    companion object {
        fun json(value: String): String {
            val escaped = value.replace("\\", "\\\\").replace("\"", "\\\"")
            return "\"$escaped\""
        }
    }
}

sealed class ImportResult {
    data class Ok(val attachment: ImportedAttachment) : ImportResult()
    data object Cancelled : ImportResult()
    data class Error(val reason: String) : ImportResult()
}

interface ImportSource {
    val displayName: String
    val declaredMime: String?
    val declaredSize: Long?
    fun openStream(): java.io.InputStream
}
