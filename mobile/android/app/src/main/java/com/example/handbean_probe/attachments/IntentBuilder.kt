package com.example.handbean_probe.attachments

import android.content.Intent
import android.net.Uri

object IntentBuilder {
    fun viewHttp(url: String): Intent {
        return Intent(Intent.ACTION_VIEW, httpUri(url))
    }

    fun httpUri(url: String): Uri {
        val uri = Uri.parse(url)
        val scheme = uri.scheme?.lowercase()
        require(scheme == "http" || scheme == "https") { "invalid_scheme" }
        require(uri.userInfo.isNullOrEmpty()) { "userinfo" }
        require(!uri.host.isNullOrBlank()) { "missing_host" }
        require(uri.isAbsolute) { "not_absolute" }
        return uri
    }

    /**
     * Basename shown to other apps via FileProvider's displayName query
     * (`OpenableColumns.DISPLAY_NAME`). On-disk snapshot files stay UUID names.
     */
    fun safeBasename(name: String): String {
        val base = name.replace('\\', '/').substringAfterLast('/').trim()
        return if (base.isEmpty() || base == "." || base == "..") "file" else base
    }

    fun mimeForName(name: String): String {
        return when (name.substringAfterLast('.', "").lowercase()) {
            "pdf" -> "application/pdf"
            "png" -> "image/png"
            "jpg", "jpeg" -> "image/jpeg"
            "gif" -> "image/gif"
            "webp" -> "image/webp"
            "txt", "md", "markdown" -> "text/plain"
            "json" -> "application/json"
            "csv" -> "text/csv"
            "zip" -> "application/zip"
            "gz", "tgz" -> "application/gzip"
            else -> "application/octet-stream"
        }
    }
}
