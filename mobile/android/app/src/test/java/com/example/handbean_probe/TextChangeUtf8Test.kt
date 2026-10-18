package com.example.handbean_probe

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class TextChangeUtf8Test {
    @Test
    fun nonBmpAndMultilingualInputUsesStandardUtf8() {
        val text = "中文 👩🏽‍💻 café"
        val bytes = TextChangeEncoding.utf8(text)

        assertArrayEquals(
            byteArrayOf(
                0xE4.toByte(), 0xB8.toByte(), 0xAD.toByte(),
                0xE6.toByte(), 0x96.toByte(), 0x87.toByte(),
                0x20,
                0xF0.toByte(), 0x9F.toByte(), 0x91.toByte(), 0xA9.toByte(),
                0xF0.toByte(), 0x9F.toByte(), 0x8F.toByte(), 0xBD.toByte(),
                0xE2.toByte(), 0x80.toByte(), 0x8D.toByte(),
                0xF0.toByte(), 0x9F.toByte(), 0x92.toByte(), 0xBB.toByte(),
                0x20, 0x63, 0x61, 0x66, 0xC3.toByte(), 0xA9.toByte(),
            ),
            bytes,
        )
        assertEquals(text, String(bytes, Charsets.UTF_8))
    }

    @Test
    fun embeddedNulIsReplacedInsteadOfTruncatingTheCString() {
        val bytes = TextChangeEncoding.utf8("a\u0000b")

        assertArrayEquals(
            byteArrayOf(0x61, 0xEF.toByte(), 0xBF.toByte(), 0xBD.toByte(), 0x62),
            bytes,
        )
        assertEquals("a\uFFFDb", String(bytes, Charsets.UTF_8))
    }
}
