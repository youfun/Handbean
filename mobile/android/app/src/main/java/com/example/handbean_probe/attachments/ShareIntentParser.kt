package com.example.handbean_probe.attachments

import android.content.Intent
import android.net.Uri

data class ParsedShare(
    val texts: List<String>,
    val subject: String?,
    val contentUris: List<Uri>,
    val errors: List<String>,
    val textTruncated: Boolean = false,
    val scannedItems: Int = 0,
) {
    val isEmpty: Boolean
        get() = texts.isEmpty() && contentUris.isEmpty() && errors.isEmpty()
}

object ShareIntentParser {
    const val MAX_SCAN = 16
    const val MAX_STORE_URIS = AttachmentLimits.MAX_COUNT
    const val MAX_TEXT_CHARS = AttachmentLimits.MAX_SHARE_TEXT_CHARS

    fun isShare(intent: Intent?): Boolean {
        val action = intent?.action ?: return false
        return action == Intent.ACTION_SEND || action == Intent.ACTION_SEND_MULTIPLE
    }

    fun parse(intent: Intent): ParsedShare {
        if (!isShare(intent)) {
            return ParsedShare(emptyList(), null, emptyList(), emptyList())
        }

        val clip = intent.clipData
        val clipCount = clip?.itemCount ?: 0
        val clipScan = minOf(clipCount, MAX_SCAN)
        val clipTexts = ArrayList<String>(clipScan)
        val clipUris = ArrayList<String>(clipScan)
        var scanned = 0
        if (clip != null) {
            for (index in 0 until clipScan) {
                scanned += 1
                val item = clip.getItemAt(index)
                item.text?.toString()?.takeIf { it.isNotBlank() }?.let { clipTexts.add(it) }
                item.uri?.let { clipUris.add(it.toString()) }
            }
        }

        val streams = streamUrisBounded(intent)
        scanned += streams.scanned

        val extraErrors = ArrayList<String>()
        if (clipCount > MAX_SCAN || streams.truncated) {
            extraErrors.add("clip_scan_limit")
        }

        return assembleRaw(
            extraText = intent.getStringExtra(Intent.EXTRA_TEXT),
            subject = intent.getStringExtra(Intent.EXTRA_SUBJECT),
            streamUris = streams.uris,
            clipTexts = clipTexts,
            clipUris = clipUris,
        ).let { raw ->
            ParsedShare(
                raw.texts,
                raw.subject,
                raw.contentUris.map(Uri::parse),
                raw.errors + extraErrors,
                raw.textTruncated,
                scanned,
            )
        }
    }

    data class ParsedShareRaw(
        val texts: List<String>,
        val subject: String?,
        val contentUris: List<String>,
        val errors: List<String>,
        val textTruncated: Boolean = false,
    )

    fun assembleRaw(
        extraText: String?,
        subject: String?,
        streamUris: List<String>,
        clipTexts: List<String> = emptyList(),
        clipUris: List<String> = emptyList(),
        maxStoreUris: Int = MAX_STORE_URIS,
        maxTextChars: Int = MAX_TEXT_CHARS,
        maxScan: Int = MAX_SCAN,
    ): ParsedShareRaw {
        val textParts = ArrayList<String>()
        var used = 0
        var textTruncated = false
        fun addText(raw: String?) {
            val value = raw?.takeIf { it.isNotBlank() } ?: return
            if (used >= maxTextChars) {
                textTruncated = true
                return
            }
            val remaining = maxTextChars - used
            if (value.length > remaining) {
                textParts.add(value.take(remaining))
                used = maxTextChars
                textTruncated = true
            } else {
                textParts.add(value)
                used += value.length
            }
        }
        addText(extraText)
        clipTexts.forEach(::addText)

        val uris = ArrayList<String>()
        val seen = linkedSetOf<String>()
        val errors = ArrayList<String>()
        var scanned = 0
        var storeFull = false
        fun consider(raw: String?) {
            if (scanned >= maxScan) {
                if ("clip_scan_limit" !in errors) errors.add("clip_scan_limit")
                return
            }
            scanned += 1
            if (storeFull) {
                if ("too_many_attachments" !in errors) errors.add("too_many_attachments")
                return
            }
            addRaw(raw, uris, seen, errors, maxStoreUris) { storeFull = true }
        }
        streamUris.forEach(::consider)
        clipUris.forEach(::consider)
        return ParsedShareRaw(
            textParts,
            subject?.takeIf { it.isNotBlank() }?.take(500),
            uris,
            errors,
            textTruncated,
        )
    }

    private fun addRaw(
        raw: String?,
        uris: MutableList<String>,
        seen: MutableSet<String>,
        errors: MutableList<String>,
        maxStoreUris: Int,
        onStoreFull: () -> Unit,
    ) {
        if (raw.isNullOrBlank()) return
        val scheme = raw.substringBefore(':', "").lowercase()
        when (scheme) {
            "content" -> {
                if (!seen.add(raw)) return
                if (uris.size >= maxStoreUris) {
                    onStoreFull()
                    if ("too_many_attachments" !in errors) errors.add("too_many_attachments")
                    return
                }
                uris.add(raw)
            }
            "file" -> errors.add("file_uri")
            "" -> errors.add("missing_uri_scheme")
            else -> errors.add("unsupported_uri")
        }
    }

    data class BoundedStreams(
        val uris: List<String>,
        val scanned: Int,
        val truncated: Boolean,
    )

    @Suppress("DEPRECATION")
    private fun streamUrisBounded(intent: Intent): BoundedStreams {
        val extra =
            if (intent.action == Intent.ACTION_SEND_MULTIPLE) {
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
            } else {
                intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let { arrayListOf(it) }
            }
        if (extra.isNullOrEmpty()) return BoundedStreams(emptyList(), 0, false)
        val limit = minOf(extra.size, MAX_SCAN)
        val uris = ArrayList<String>(limit)
        for (index in 0 until limit) {
            extra[index]?.toString()?.let(uris::add)
        }
        return BoundedStreams(uris, limit, extra.size > MAX_SCAN)
    }
}
