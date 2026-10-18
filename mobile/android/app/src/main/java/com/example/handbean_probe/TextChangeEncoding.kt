package com.example.handbean_probe

/** Standard UTF-8 boundary for text changes sent through a NUL-terminated C API. */
internal object TextChangeEncoding {
    fun utf8(value: String): ByteArray =
        value.replace('\u0000', '\uFFFD').toByteArray(Charsets.UTF_8)
}
