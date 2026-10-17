package com.example.handbean_probe.attachments

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ShareIntentParserTest {
    @Test
    fun extraTextAndSubjectDoNotFetch() {
        val parsed = ShareIntentParser.assembleRaw(
            extraText = "https://example.com/a",
            subject = "title",
            streamUris = emptyList(),
        )
        assertEquals(listOf("https://example.com/a"), parsed.texts)
        assertEquals("title", parsed.subject)
        assertTrue(parsed.contentUris.isEmpty())
    }

    @Test
    fun streamAndClipDataDedupPreserveOrder() {
        val first = "content://one/a"
        val second = "content://two/b"
        val third = "content://three/c"
        val parsed = ShareIntentParser.assembleRaw(
            extraText = null,
            subject = null,
            streamUris = listOf(first, second, first),
            clipUris = listOf(first, second, third),
        )
        assertEquals(listOf(first, second, third), parsed.contentUris)
    }

    @Test
    fun mergeStopsAtStoreAndScanLimitsInsteadOfTraversingThenTruncating() {
        val streams = (1..20).map { "content://stream/$it" }
        val clips = (1..20).map { "content://clip/$it" }
        val parsed = ShareIntentParser.assembleRaw(
            extraText = "a".repeat(ShareIntentParser.MAX_TEXT_CHARS + 50),
            subject = "title",
            streamUris = streams,
            clipUris = clips,
            maxStoreUris = 4,
            maxTextChars = ShareIntentParser.MAX_TEXT_CHARS,
            maxScan = 16,
        )
        assertEquals(4, parsed.contentUris.size)
        assertEquals((1..4).map { "content://stream/$it" }, parsed.contentUris)
        assertTrue(parsed.errors.contains("too_many_attachments") || parsed.errors.contains("clip_scan_limit"))
        assertTrue(parsed.textTruncated)
        assertEquals(ShareIntentParser.MAX_TEXT_CHARS, parsed.texts.joinToString("").length)
    }

    @Test
    fun fileUriIsRejected() {
        val parsed = ShareIntentParser.assembleRaw(
            extraText = "note",
            subject = null,
            streamUris = listOf("file:///sdcard/secret.jpg"),
        )
        assertTrue(parsed.contentUris.isEmpty())
        assertEquals(listOf("file_uri"), parsed.errors)
        assertEquals(listOf("note"), parsed.texts)
    }
}
