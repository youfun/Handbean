package com.example.handbean_probe.attachments

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import java.io.File

object ImageNormalizer {
    fun normalize(file: File, mime: String): File {
        val bytes = file.readBytes()
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        val w = bounds.outWidth
        val h = bounds.outHeight
        if (w <= 0 || h <= 0) throw IllegalStateException("undecodable_image")
        val sample = sampleSize(w, h)
        val opts = BitmapFactory.Options().apply { inSampleSize = sample }
        val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, opts)
            ?: throw IllegalStateException("undecodable_image")
        val oriented = applyOrientation(bitmap, if (mime == "image/jpeg") ExifReader.orientation(bytes) else 1)
        val scaled = scale(oriented)
        val out = File(file.parentFile, file.name + ".norm")
        out.outputStream().use { stream ->
            val format = if (mime == "image/png") Bitmap.CompressFormat.PNG else Bitmap.CompressFormat.JPEG
            val quality = if (format == Bitmap.CompressFormat.JPEG) AttachmentLimits.JPEG_QUALITY else 100
            scaled.compress(format, quality, stream)
        }
        if (scaled !== bitmap) scaled.recycle()
        if (oriented !== bitmap && oriented !== scaled) oriented.recycle()
        bitmap.recycle()
        file.delete()
        val dest = File(file.parentFile, file.name)
        out.renameTo(dest)
        if (dest.length() > AttachmentLimits.MAX_IMAGE_BYTES) {
            dest.delete()
            throw IllegalStateException("too_large")
        }
        return dest
    }

    private fun sampleSize(width: Int, height: Int): Int {
        var sample = 1
        var pixels = width.toLong() * height
        var w = width
        var h = height
        while (pixels > AttachmentLimits.MAX_PIXELS || w > AttachmentLimits.MAX_EDGE || h > AttachmentLimits.MAX_EDGE) {
            sample *= 2
            w /= 2
            h /= 2
            pixels = w.toLong() * h
        }
        return sample
    }

    private fun applyOrientation(bitmap: Bitmap, orientation: Int): Bitmap {
        val matrix = Matrix()
        when (orientation) {
            2 -> matrix.preScale(-1f, 1f)
            3 -> matrix.postRotate(180f)
            4 -> matrix.preScale(1f, -1f)
            5 -> {
                matrix.postRotate(90f)
                matrix.preScale(-1f, 1f)
            }
            6 -> matrix.postRotate(90f)
            7 -> {
                matrix.postRotate(270f)
                matrix.preScale(-1f, 1f)
            }
            8 -> matrix.postRotate(270f)
            else -> return bitmap
        }
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
    }

    private fun scale(bitmap: Bitmap): Bitmap {
        val edge = maxOf(bitmap.width, bitmap.height)
        if (edge <= AttachmentLimits.MAX_EDGE) return bitmap
        val ratio = AttachmentLimits.MAX_EDGE.toFloat() / edge
        return Bitmap.createScaledBitmap(
            bitmap,
            (bitmap.width * ratio).toInt().coerceAtLeast(1),
            (bitmap.height * ratio).toInt().coerceAtLeast(1),
            true,
        )
    }
}
