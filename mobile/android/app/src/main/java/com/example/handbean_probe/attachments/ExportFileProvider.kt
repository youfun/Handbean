package com.example.handbean_probe.attachments

import android.net.Uri
import androidx.core.content.FileProvider

class ExportFileProvider : FileProvider() {
    override fun getType(uri: Uri): String = mimeForDisplayName(uri.getQueryParameter(DISPLAY_NAME_QUERY))

    companion object {
        // androidx.core.content.FileProvider DISPLAYNAME_FIELD
        const val DISPLAY_NAME_QUERY = "displayName"

        fun mimeForDisplayName(displayName: String?): String {
            if (displayName.isNullOrBlank()) return "application/octet-stream"
            return IntentBuilder.mimeForName(IntentBuilder.safeBasename(displayName))
        }
    }
}
