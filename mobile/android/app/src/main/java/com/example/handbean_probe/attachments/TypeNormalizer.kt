package com.example.handbean_probe.attachments

object TypeNormalizer {
    private val imageTypes = setOf("image/png", "image/jpeg", "image/gif", "image/webp")
    private val textTypes = setOf(
        "text/plain",
        "text/markdown",
        "application/json",
        "text/csv",
        "text/x-source",
    )
    private val textExts = setOf(
        ".txt", ".md", ".markdown", ".json", ".csv", ".ex", ".exs", ".erl", ".hrl",
        ".js", ".ts", ".tsx", ".jsx", ".py", ".rb", ".go", ".rs", ".c", ".h",
        ".cpp", ".hpp", ".java", ".kt", ".kts", ".swift", ".sh", ".xml", ".yml",
        ".yaml", ".toml", ".html", ".css", ".sql",
    )

    fun normalize(declaredMime: String?, displayName: String, head: ByteArray?): String? {
        val ext = displayName.substringAfterLast('.', missingDelimiterValue = "")
            .lowercase()
            .let { if (it.isEmpty()) "" else ".$it" }
        if (binaryMagic(head)) return null
        val magic = magicType(head)
        if (magic != null) return magic
        if (utf8Prefix(head) && ext in textExts) return textCanonical(ext)
        return null
    }

    fun image(type: String) = type in imageTypes
    fun text(type: String) = type in textTypes

    private fun magicType(head: ByteArray?): String? {
        if (head == null || head.size < 3) return null
        if (head[0] == 0x89.toByte() && head.size >= 4 &&
            head[1] == 0x50.toByte() && head[2] == 0x4E.toByte() && head[3] == 0x47.toByte()
        ) {
            return "image/png"
        }
        if (head[0] == 0xFF.toByte() && head[1] == 0xD8.toByte() && head[2] == 0xFF.toByte()) {
            return "image/jpeg"
        }
        if (head.size >= 4 &&
            head[0] == 'G'.code.toByte() &&
            head[1] == 'I'.code.toByte() &&
            head[2] == 'F'.code.toByte() &&
            head[3] == '8'.code.toByte()
        ) {
            return "image/gif"
        }
        if (head.size >= 12 &&
            head.copyOfRange(0, 4).toString(Charsets.US_ASCII) == "RIFF" &&
            head.copyOfRange(8, 12).toString(Charsets.US_ASCII) == "WEBP"
        ) {
            return "image/webp"
        }
        return null
    }

    private fun binaryMagic(head: ByteArray?): Boolean {
        if (head == null || head.size < 4) return false
        if (head.copyOfRange(0, 4).toString(Charsets.US_ASCII) == "%PDF") return true
        if (head[0] == 'P'.code.toByte() && head[1] == 'K'.code.toByte()) return true
        if (head[0] == 0xD0.toByte() && head[1] == 0xCF.toByte() &&
            head[2] == 0x11.toByte() && head[3] == 0xE0.toByte()
        ) {
            return true
        }
        if (head[0] == 0x7F.toByte() && head.copyOfRange(1, 4).toString(Charsets.US_ASCII) == "ELF") {
            return true
        }
        return false
    }

    private fun utf8Prefix(head: ByteArray?): Boolean {
        if (head == null || head.isEmpty()) return false
        if (head.contains(0)) return false
        var i = 0
        while (i < head.size) {
            val b = head[i].toInt() and 0xFF
            when {
                b <= 0x7F -> i += 1
                b in 0xC2..0xDF -> {
                    if (i + 1 >= head.size) return true
                    if (head[i + 1].toInt() and 0xC0 != 0x80) return false
                    i += 2
                }
                b in 0xE0..0xEF -> {
                    if (i + 1 >= head.size) return true
                    if (head[i + 1].toInt() and 0xC0 != 0x80) return false
                    if (i + 2 >= head.size) return true
                    if (head[i + 2].toInt() and 0xC0 != 0x80) return false
                    i += 3
                }
                b in 0xF0..0xF4 -> {
                    if (i + 1 >= head.size) return true
                    if (head[i + 1].toInt() and 0xC0 != 0x80) return false
                    if (i + 2 >= head.size) return true
                    if (head[i + 2].toInt() and 0xC0 != 0x80) return false
                    if (i + 3 >= head.size) return true
                    if (head[i + 3].toInt() and 0xC0 != 0x80) return false
                    i += 4
                }
                else -> return false
            }
        }
        return true
    }

    private fun textCanonical(ext: String): String {
        return when (ext) {
            ".md", ".markdown" -> "text/markdown"
            ".json" -> "application/json"
            ".csv" -> "text/csv"
            ".txt" -> "text/plain"
            else -> "text/x-source"
        }
    }
}
