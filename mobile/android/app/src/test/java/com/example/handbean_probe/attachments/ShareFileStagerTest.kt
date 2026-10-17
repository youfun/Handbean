package com.example.handbean_probe.attachments

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.io.ByteArrayInputStream

class ShareFileStagerTest {
    @Test
    fun safeDisplayNameSanitizesTraversalAndUnicode() {
        assertEquals("secret_.txt", ShareFileStager.safeDisplayName("../secret/.txt", 0))
        assertEquals("shared_file_2", ShareFileStager.safeDisplayName("../", 1))
        val unicodeName = ShareFileStager.safeDisplayName("🙂".repeat(100) + ".txt", 2)
        assertEquals(true, unicodeName.toByteArray(Charsets.UTF_8).size <= 200)
    }

    @Test
    fun copyBoundedRejectsOverflow() {
        assertThrows(ShareFileStager.TooLarge::class.java) {
            ShareFileStager.copyBounded(ByteArrayInputStream(ByteArray(6)), java.io.ByteArrayOutputStream(), 5)
        }
    }

    @Test
    fun copyBoundedAcceptsExactLimit() {
        val bytes = ByteArray(5) { 1 }
        val output = java.io.ByteArrayOutputStream()
        assertEquals(5, ShareFileStager.copyBounded(ByteArrayInputStream(bytes), output, 5))
    }
}
