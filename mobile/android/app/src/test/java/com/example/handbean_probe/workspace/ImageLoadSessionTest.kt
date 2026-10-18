package com.example.handbean_probe.workspace

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ImageLoadSessionTest {
    @Test
    fun lateResultAfterInvalidateIsRecycledAndNotDelivered() {
        val recycled = mutableListOf<String>()
        val session = ImageLoadSession<String>(recycle = { recycled.add(it) })
        val token = session.nextToken()
        session.invalidate()
        assertNull(session.accept(token, "stale"))
        assertEquals(listOf("stale"), recycled)
    }

    @Test
    fun matchingTokenIsDelivered() {
        val recycled = mutableListOf<String>()
        val session = ImageLoadSession<String>(recycle = { recycled.add(it) })
        val token = session.nextToken()
        assertEquals("ok", session.accept(token, "ok"))
        assertEquals(emptyList<String>(), recycled)
    }

    @Test
    fun newerTokenDropsThePreviousDecode() {
        val recycled = mutableListOf<String>()
        val session = ImageLoadSession<String>(recycle = { recycled.add(it) })
        val first = session.nextToken()
        session.nextToken()
        assertNull(session.accept(first, "old"))
        assertEquals(listOf("old"), recycled)
    }
}
