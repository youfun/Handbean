package com.example.handbean_probe.attachments

import java.io.File

/** Path gate for composer previews. Never accepts remote or URI schemes. */
object LocalImageSource {
    fun fileForPreview(src: String?): File? {
        if (src.isNullOrBlank()) return null
        val trimmed = src.trim()
        val lower = trimmed.lowercase()
        if (lower.startsWith("http://") || lower.startsWith("https://")) return null
        if (trimmed.contains("://")) return null
        if (trimmed.contains('\u0000')) return null
        val file = File(trimmed)
        if (!file.isAbsolute) return null
        return file
    }

    fun fileForAuthorizedUpload(src: String?): File? {
        val file = fileForPreview(src) ?: return null
        if (!authorizedUpload(file.absolutePath)) return null
        return file
    }

    fun authorizedUpload(path: String): Boolean {
        val parts = path.split('/').filter { it.isNotEmpty() }
        val idx = parts.indexOfLast { it == "uploads" }
        if (idx < 1 || parts[idx - 1] != ".handbean") return false
        if (idx + 2 != parts.lastIndex) return false
        val conversationId = parts[idx + 1]
        val fileName = parts[idx + 2]
        if (conversationId.isEmpty() || fileName.isEmpty()) return false
        if (conversationId.contains("..") || fileName.contains("..")) return false
        return true
    }

    fun sampleSize(width: Int, height: Int, maxEdge: Int): Int {
        if (width <= 0 || height <= 0) return 1
        val cap = maxEdge.coerceAtLeast(1)
        var sample = 1
        while (width / sample > cap || height / sample > cap) {
            sample *= 2
        }
        return sample
    }
}
