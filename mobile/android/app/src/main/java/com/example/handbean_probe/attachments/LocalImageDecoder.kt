package com.example.handbean_probe.attachments

import android.graphics.Bitmap
import android.graphics.BitmapFactory

object LocalImageDecoder {
    fun decode(src: String?, maxEdge: Int, uploadOnly: Boolean = false): Bitmap? {
        val file =
            if (uploadOnly) LocalImageSource.fileForAuthorizedUpload(src)
            else LocalImageSource.fileForPreview(src)
        if (file == null) return null
        if (!file.isFile) return null
        return try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(file.absolutePath, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
            val opts = BitmapFactory.Options().apply {
                inSampleSize = LocalImageSource.sampleSize(bounds.outWidth, bounds.outHeight, maxEdge)
            }
            BitmapFactory.decodeFile(file.absolutePath, opts)
        } catch (_: SecurityException) {
            null
        }
    }
}
