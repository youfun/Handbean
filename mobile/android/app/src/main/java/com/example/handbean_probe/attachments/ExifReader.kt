package com.example.handbean_probe.attachments

object ExifReader {
    fun orientation(jpeg: ByteArray): Int {
        if (jpeg.size < 4 || jpeg[0] != 0xFF.toByte() || jpeg[1] != 0xD8.toByte()) return 1
        var i = 2
        while (i + 4 < jpeg.size) {
            if (jpeg[i] != 0xFF.toByte()) return 1
            val marker = jpeg[i + 1].toInt() and 0xFF
            val len = ((jpeg[i + 2].toInt() and 0xFF) shl 8) or (jpeg[i + 3].toInt() and 0xFF)
            if (marker == 0xE1 && i + 4 + 6 < jpeg.size) {
                val head = jpeg.copyOfRange(i + 4, minOf(i + 10, jpeg.size))
                if (head.toString(Charsets.US_ASCII).startsWith("Exif")) {
                    return tiffOrientation(jpeg, i + 10, i + 2 + len)
                }
            }
            i += 2 + len
            if (marker == 0xDA) break
        }
        return 1
    }

    private fun tiffOrientation(bytes: ByteArray, start: Int, end: Int): Int {
        if (start + 8 >= bytes.size) return 1
        val le = bytes[start] == 'I'.code.toByte()
        fun u16(at: Int): Int {
            if (at + 1 >= bytes.size) return 0
            val a = bytes[at].toInt() and 0xFF
            val b = bytes[at + 1].toInt() and 0xFF
            return if (le) a or (b shl 8) else (a shl 8) or b
        }
        fun u32(at: Int): Long {
            if (at + 3 >= bytes.size) return 0
            val a = bytes[at].toInt() and 0xFF
            val b = bytes[at + 1].toInt() and 0xFF
            val c = bytes[at + 2].toInt() and 0xFF
            val d = bytes[at + 3].toInt() and 0xFF
            return if (le) {
                a.toLong() or (b.toLong() shl 8) or (c.toLong() shl 16) or (d.toLong() shl 24)
            } else {
                (a.toLong() shl 24) or (b.toLong() shl 16) or (c.toLong() shl 8) or d.toLong()
            }
        }
        val ifd0 = start + u32(start + 4).toInt()
        if (ifd0 < start || ifd0 + 2 >= end) return 1
        val count = u16(ifd0)
        for (n in 0 until count) {
            val entry = ifd0 + 2 + n * 12
            if (entry + 12 > bytes.size) break
            if (u16(entry) == 0x0112) {
                val value = u16(entry + 8)
                return if (value in 1..8) value else 1
            }
        }
        return 1
    }
}
