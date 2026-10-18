package com.example.handbean_probe

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class HandbeanBridgeTest {
    private fun node(type: String, props: Map<String, Any?> = emptyMap(), vararg children: MobNode) =
        MobNode(type, props, children.toList())

    @Test
    fun tapHandleForFindsNestedIdAndCoercesHandle() {
        val root = node(
            "box", mapOf("approval_dialog" to true),
            node("column", emptyMap(),
                node("text", mapOf("id" to "title")),
                node("button", mapOf("id" to BridgeIds.Elements.DISMISS_APPROVAL, "on_tap" to 42L)),
            ),
        )
        assertEquals(42, HandbeanBridge.tapHandleFor(root, BridgeIds.Elements.DISMISS_APPROVAL))
        assertEquals("button", HandbeanBridge.findById(root, "dismiss_approval")?.type)
    }

    @Test
    fun tapHandleForIsNullWhenMissing() {
        val root = node("box", emptyMap(), node("text", mapOf("id" to "x")))
        assertNull(HandbeanBridge.tapHandleFor(root, "missing"))
        assertNull(HandbeanBridge.tapHandleFor(root, null))
        assertNull(HandbeanBridge.tapHandleFor(null, "x"))
        // id matches but no on_tap
        assertNull(HandbeanBridge.tapHandleFor(root, "x"))
    }

    @Test
    fun twoNotificationStopCyclesReachTheCancelBridgeOnceEach() {
        val cancels = CopyOnWriteArrayList<String>()

        HandbeanBridge.observeActiveRuns(setOf("notification-run-a"))
        HandbeanBridge.recordClose { cancels.add("run-a") }
        HandbeanBridge.recordClose { cancels.add("duplicate-a") }

        HandbeanBridge.observeActiveRuns(setOf("notification-run-b"))
        HandbeanBridge.recordClose { cancels.add("run-b") }
        HandbeanBridge.recordClose { cancels.add("duplicate-b") }

        assertEquals(listOf("run-a", "run-b"), cancels.toList())
    }

    @Test
    fun serialDispatcherRunsInOrderOnOneThreadAndSurvivesFailures() {
        val seen = CopyOnWriteArrayList<Int>()
        val threads = CopyOnWriteArrayList<Thread>()
        val errors = CopyOnWriteArrayList<Throwable>()
        val done = CountDownLatch(5)
        val executor = Executors.newSingleThreadExecutor { r ->
            Thread(r, "test-serial").apply {
                // Mirror production: the throw still reaches the thread handler;
                // keep the JVM test quiet.
                setUncaughtExceptionHandler { _, _ -> }
            }
        }
        val dispatcher = SerialCommandDispatcher(executor, onError = { errors.add(it) })
        try {
            for (i in 1..5) {
                dispatcher.dispatch {
                    try {
                        threads.add(Thread.currentThread())
                        seen.add(i)
                        if (i == 3) throw IllegalStateException("boom $i")
                    } finally {
                        done.countDown()
                    }
                }
            }
            assertTrue(done.await(5, TimeUnit.SECONDS))
            assertEquals(listOf(1, 2, 3, 4, 5), seen.toList())
            assertEquals(1, errors.size)
            assertEquals("boom 3", errors.single().message)
            // Single worker: at most one distinct thread before the failure,
            // and no two tasks ever ran concurrently (order was preserved).
            assertEquals(1, threads.take(3).map { it.name }.toSet().size)
            assertTrue(threads.all { it.name == "test-serial" })
        } finally {
            executor.shutdownNow()
        }
    }
}
