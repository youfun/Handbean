package com.example.handbean_probe

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class CloseCycleGateTest {
    @Test
    fun oneObservedRunSetClosesOnceAndEmptyUpdateReleasesTheClaim() {
        val gate = CloseCycleGate()
        val closes = AtomicInteger(0)
        gate.observeActiveRuns(setOf("run-a"))

        assertTrue(gate.runOnce { closes.incrementAndGet() })
        assertFalse(gate.runOnce { closes.incrementAndGet() })
        gate.observeActiveRuns(setOf("run-a"))
        gate.observeActiveRuns(emptySet())
        assertTrue(gate.runOnce { closes.incrementAndGet() })
        assertEquals(2, closes.get())
    }

    @Test
    fun unknownEmptyRunSetNeverBecomesAPermanentLatch() {
        val gate = CloseCycleGate()
        val closes = AtomicInteger(0)

        assertTrue(gate.runOnce { closes.incrementAndGet() })
        assertTrue(gate.runOnce { closes.incrementAndGet() })
        assertEquals(2, closes.get())
    }

    @Test
    fun aNewRunIdOpensTheNextCloseCycle() {
        val gate = CloseCycleGate()
        val closes = AtomicInteger(0)
        gate.observeActiveRuns(setOf("run-a"))
        assertTrue(gate.runOnce { closes.incrementAndGet() })

        gate.observeActiveRuns(setOf("run-b"))

        assertTrue(gate.runOnce { closes.incrementAndGet() })
        assertFalse(gate.runOnce { closes.incrementAndGet() })
        assertEquals(2, closes.get())
    }

    @Test
    fun aFailedCloseCanBeRetriedWithoutWaitingForANewRun() {
        val gate = CloseCycleGate()
        gate.observeActiveRuns(setOf("run-a"))
        var failed = false

        try {
            gate.runOnce { throw IllegalStateException("native cancel failed") }
        } catch (_: IllegalStateException) {
            failed = true
        }

        assertTrue(failed)
        assertTrue(gate.runOnce {})
        assertFalse(gate.runOnce {})
    }

    @Test
    fun concurrentCloseSignalsExecuteOnlyOneAction() {
        val gate = CloseCycleGate()
        gate.observeActiveRuns(setOf("run-a"))
        val workers = 16
        val ready = CountDownLatch(workers)
        val start = CountDownLatch(1)
        val done = CountDownLatch(workers)
        val closes = AtomicInteger(0)
        val executor = Executors.newFixedThreadPool(workers)

        try {
            repeat(workers) {
                executor.execute {
                    ready.countDown()
                    start.await()
                    gate.runOnce { closes.incrementAndGet() }
                    done.countDown()
                }
            }
            assertTrue(ready.await(5, TimeUnit.SECONDS))
            start.countDown()
            assertTrue(done.await(5, TimeUnit.SECONDS))
            assertEquals(1, closes.get())
        } finally {
            executor.shutdownNow()
        }
    }
}
