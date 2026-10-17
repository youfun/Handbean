package com.example.handbean_probe.attachments

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class PlatformHostStateTest {
    @Test
    fun cancellationAfterPickerDispatchKeepsTombstoneUntilMatchingResult() {
        val slot = SaveResultSlot()
        assertTrue(slot.reserve("save-1"))
        assertTrue(slot.beginDispatch("save-1"))
        assertTrue(slot.accepted("save-1"))

        assertTrue(slot.cancel("save-1"))
        assertFalse(slot.reserve("save-2"))
        assertNull(slot.consume("save-2"))
        assertEquals("save-1", slot.consume("save-1"))
        assertTrue(slot.reserve("save-2"))
    }

    @Test
    fun oldOrMissingCallbackNeverFallsBackToCurrentSave() {
        val slot = SaveResultSlot()
        assertTrue(slot.reserve("save-new"))
        assertTrue(slot.beginDispatch("save-new"))
        assertTrue(slot.accepted("save-new"))

        assertNull(slot.consume(null))
        assertNull(slot.consume("save-old"))
        assertEquals("save-new", slot.requestId())
    }

    @Test
    fun pendingCancellationDoesNotClaimPickerWasLaunched() {
        val slot = SaveResultSlot()
        assertTrue(slot.reserve("save-1"))
        assertFalse(slot.cancel("save-1"))
        assertNull(slot.requestId())
    }

    @Test
    fun platformCancelUsesTargetNotCommandId() {
        assertEquals("import-1", PlatformCancelCommand.targetRequestId("cancel-9", "import-1"))
        assertNull(PlatformCancelCommand.targetRequestId("import-1", "import-1"))
        assertNull(PlatformCancelCommand.targetRequestId("cancel-9", ""))
        assertNull(PlatformCancelCommand.targetRequestId("cancel-9", "   "))
        assertNull(PlatformCancelCommand.targetRequestId("cancel-9", null))
    }

    @Test
    fun completionCallbackWinsOnlyOnceAcrossExecutorRace() {
        val completion = RequestCompletion()
        val delivered = AtomicInteger()
        val start = CountDownLatch(1)
        val done = CountDownLatch(2)
        val executor = Executors.newFixedThreadPool(2)
        repeat(2) {
            executor.execute {
                start.await()
                if (completion.finishOnce()) delivered.incrementAndGet()
                done.countDown()
            }
        }
        start.countDown()
        assertTrue(done.await(5, TimeUnit.SECONDS))
        executor.shutdownNow()
        assertEquals(1, delivered.get())
    }
}
