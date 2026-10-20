package com.example.handbean_probe

import org.junit.Assert.assertEquals
import org.junit.Test

class MobPermissionsTest {
    @Test
    fun missingActivityDeniesTheRequestWithItsOriginalPidAndCapability() {
        val delivered = mutableListOf<List<Any>>()
        val owner = MobPermissions({ null }) { pid, event, cap, status ->
            delivered.add(listOf(pid, event, cap, status))
        }
        owner.request(42L, "camera")
        assertEquals(listOf(listOf(42L, "permission", "camera", "denied")), delivered)
        assertEquals(42L, owner.pendingPid)
        assertEquals("camera", owner.pendingCap)
    }

    @Test
    fun activityResultsUseTheSinglePendingCallbackSlot() {
        val delivered = mutableListOf<List<Any>>()
        val owner = MobPermissions({ null }) { pid, event, cap, status ->
            delivered.add(listOf(pid, event, cap, status))
        }
        owner.pendingPid = 7L
        owner.pendingCap = "microphone"
        owner.onResult(true)
        owner.pendingPid = 8L
        owner.pendingCap = "calendar"
        owner.onResult(false)
        assertEquals(listOf(
            listOf(7L, "permission", "microphone", "granted"),
            listOf(8L, "permission", "calendar", "denied"),
        ), delivered)
    }
}
