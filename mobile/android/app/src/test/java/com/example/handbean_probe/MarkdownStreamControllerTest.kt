package com.example.handbean_probe

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MarkdownStreamControllerTest {
    private val fast = MarkdownStreamConfig(
        startDelayMs = 80,
        maxCommitFps = 30,
        minGraphemesPerSecond = 1_000.0,
        maxGraphemesPerSecond = 1_000.0,
        maxGraphemesPerCommit = 1,
    )

    @Test fun prefixBurstsDoNotRestartTheInitialDelayOrStarve() {
        val stream = MarkdownStreamController(fast)
        assertEquals("", stream.update("a", true, 0))
        assertEquals("", stream.update("ab", true, 30))
        assertEquals("", stream.update("abc", true, 60))
        assertEquals("a", stream.tick(80))
        assertEquals("a", stream.update("abcd", true, 90))
        assertEquals("ab", stream.tick(114))
    }

    @Test fun anInitiallyEmptyStreamStillBuffersItsFirstRealChunk() {
        val stream = MarkdownStreamController(fast)
        stream.update("", true, 0)
        stream.update("first", true, 10)
        assertEquals("", stream.tick(80))
        assertEquals("f", stream.tick(90))
    }

    @Test fun aLaterChunkDoesNotPayTheFirstChunkDelayAgain() {
        val stream = MarkdownStreamController(fast)
        stream.update("a", true, 0)
        assertEquals("a", stream.tick(80))
        stream.update("ab", true, 200)
        assertEquals("ab", stream.tick(233))
    }

    @Test fun sustainedHighFrequencyInputStillCommitsAtMostThirtyTimesPerSecond() {
        val stream = MarkdownStreamController(fast.copy(maxGraphemesPerCommit = 80))
        var changes = 0
        var previous = stream.update("", true, 0)
        for (now in 1L..1_000L) {
            stream.update("x".repeat(now.toInt()), true, now)
            val next = stream.tick(now)
            if (next != previous) changes++
            previous = next
        }
        assertTrue("commits=$changes", changes in 1..30)
    }

    @Test fun replacementAndShorteningResetInsteadOfAppendingOldText() {
        val stream = MarkdownStreamController(fast)
        stream.update("old", true, 0)
        assertEquals("o", stream.tick(80))
        assertEquals("", stream.update("new", true, 81))
        assertEquals("n", stream.tick(161))
        assertEquals("", stream.update("n", true, 162))
        assertEquals("n", stream.tick(242))
    }

    @Test fun completionFlushesTheExactReceivedSource() {
        val stream = MarkdownStreamController(fast)
        stream.update("partially visible", true, 0)
        assertEquals("p", stream.tick(80))
        assertEquals("partially visible", stream.update("partially visible", false, 81))
        assertFalse(stream.hasPending())
    }

    @Test fun graphemeCommitsNeverSplitCombiningSurrogateOrZwjSequences() {
        val clusters = listOf("中", "🙂", "e\u0301", "👩‍💻", "👨‍👩‍👧‍👦")
        val stream = MarkdownStreamController(fast)
        stream.update(clusters.joinToString(""), true, 0)
        var expected = ""
        clusters.forEachIndexed { index, cluster ->
            expected += cluster
            assertEquals(expected, stream.tick(80L + index * 34L))
        }
    }

    @Test fun aDisposedMessageCannotOverwriteAnotherController() {
        val old = MarkdownStreamController(fast)
        val replacement = MarkdownStreamController(fast)
        old.update("old message", true, 0)
        replacement.update("new message", true, 50)
        assertEquals("o", old.tick(80))
        assertEquals("n", replacement.tick(130))
        assertEquals("n", replacement.visible)
    }

    @Test fun finalIdentityHandoffIsImmediateAndDoesNotReplay() {
        val temporary = MarkdownStreamController(fast)
        temporary.update("complete answer", true, 0)
        assertEquals("c", temporary.tick(80))

        val persisted = MarkdownStreamController(fast)
        assertEquals("complete answer", persisted.update("complete answer", false, 81))
        assertFalse(persisted.streaming)
    }
}
