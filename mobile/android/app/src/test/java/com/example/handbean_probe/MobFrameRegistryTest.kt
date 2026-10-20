package com.example.handbean_probe

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CyclicBarrier
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class MobFrameRegistryTest {
    @Test
    fun navigationDropsOldFramesAndRejectsOutgoingTrackers() {
        val registry = MobFrameRegistry()
        val outgoing = registry.currentGeneration()
        registry.record("old", outgoing, 1f, 2f, 3f, 4f)
        assertTrue(registry.frames.containsKey("old"))

        registry.advanceNavigation()
        assertTrue(registry.frames.isEmpty())
        registry.record("stale", outgoing, 1f, 2f, 3f, 4f)
        assertFalse(registry.frames.containsKey("stale"))
        registry.record("new", registry.currentGeneration(), 1f, 2f, 3f, 4f)
        assertEquals(setOf("new"), registry.frames.keys)

        registry.advanceNavigation()
        assertTrue(registry.frames.isEmpty())
        registry.record("new", registry.currentGeneration(), 5f, 6f, 7f, 8f)
        assertEquals(setOf("new"), registry.frames.keys)
    }

    @Test
    fun concurrentNavigationAndLayoutNeverLeaveAnOutgoingFrame() {
        val registry = MobFrameRegistry()
        val start = CyclicBarrier(2)
        val finished = CyclicBarrier(2)
        val executor = Executors.newSingleThreadExecutor()
        try {
            val writer = executor.submit {
                repeat(2_000) {
                    val generation = registry.currentGeneration()
                    start.await(5, TimeUnit.SECONDS)
                    repeat(200) { registry.record("outgoing", generation, 1f, 2f, 3f, 4f) }
                    finished.await(5, TimeUnit.SECONDS)
                }
            }
            repeat(2_000) {
                start.await(5, TimeUnit.SECONDS)
                registry.advanceNavigation()
                finished.await(5, TimeUnit.SECONDS)
                assertTrue("An old tracker survived navigation", registry.frames.isEmpty())
            }
            writer.get(5, TimeUnit.SECONDS)
        } finally {
            executor.shutdownNow()
        }
    }

    @Test
    fun outgoingLayoutCannotRepopulateRegistryAfterNavigation() {
        val registry = MobFrameRegistry()
        val outgoing = registry.currentGeneration()
        val navigationDone = CountDownLatch(1)
        val executor = Executors.newSingleThreadExecutor()
        try {
            val writer = executor.submit {
                check(navigationDone.await(5, TimeUnit.SECONDS))
                registry.record("outgoing", outgoing, 1f, 2f, 3f, 4f)
            }
            registry.advanceNavigation()
            navigationDone.countDown()
            writer.get(5, TimeUnit.SECONDS)
            assertTrue(registry.frames.isEmpty())
        } finally {
            executor.shutdownNow()
        }
    }
}
