package com.example.handbean_probe

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AgentKeepAliveServiceCommandTest {
    @Test
    fun twoAgentNotifyUpdatesAndNotificationStopsReachBridgeOncePerKnownRun() {
        val cancels = mutableListOf<String>()
        val bridge = CloseCycleRunStopBridge(cancelRuns = { cancels.add("cancel") })
        val controller = AgentServiceCommandController(bridge)

        val runA = AgentNotify.activeRunIds(runningPayload("run-a"))
        assertFalse(controller.handle(null, runA))
        assertTrue(controller.handle(AgentKeepAliveService.ACTION_STOP, null))
        assertTrue(controller.handle(AgentKeepAliveService.ACTION_STOP, null))
        assertEquals(1, cancels.size)

        val runB = AgentNotify.activeRunIds(runningPayload("run-b"))
        assertFalse(controller.handle(null, runB))
        assertTrue(controller.handle(AgentKeepAliveService.ACTION_STOP, null))
        assertTrue(controller.handle(AgentKeepAliveService.ACTION_STOP, null))
        assertEquals(2, cancels.size)
    }

    @Test
    fun emptyAgentNotifyUpdateDoesNotCreateAPermanentStopLatch() {
        var cancels = 0
        val bridge = CloseCycleRunStopBridge(cancelRuns = { cancels += 1 })
        val controller = AgentServiceCommandController(bridge)

        assertFalse(controller.handle(null, AgentNotify.activeRunIds(runningPayload(null))))
        assertTrue(controller.handle(AgentKeepAliveService.ACTION_STOP, null))
        assertTrue(controller.handle(AgentKeepAliveService.ACTION_STOP, null))
        assertEquals(2, cancels)
    }

    private fun runningPayload(runId: String?): ByteArray {
        val tasks = if (runId == null) "[]" else "[{\"run_id\":\"$runId\"}]"
        return "{\"running_count\":${if (runId == null) 0 else 1},\"tasks\":$tasks}"
            .toByteArray(Charsets.UTF_8)
    }
}
