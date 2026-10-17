package com.example.handbean_probe.attachments

object AttachmentLimits {
    const val MAX_COUNT = 4
    const val MAX_IMAGE_BYTES = 5_000_000L
    const val MAX_TEXT_BYTES = 20L * 1024L * 1024L
    const val MAX_BATCH_BYTES = 25L * 1024L * 1024L
    const val MAX_SHARE_TEXT_CHARS = 100_000
    const val MAX_PIXELS = 2560 * 2560
    const val MAX_EDGE = 2560
    const val JPEG_QUALITY = 88
}

object ExportLimits {
    const val MAX_BYTES = 80L * 1024L * 1024L
    const val TTL_MS = 24L * 60L * 60L * 1000L
}
