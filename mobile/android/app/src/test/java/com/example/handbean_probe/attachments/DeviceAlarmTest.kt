package com.example.handbean_probe.attachments

import android.provider.AlarmClock
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

class DeviceAlarmTest {
    @Test
    fun prefillsSetAlarmWithoutSkippingTheClockUi() {
        val intent = DeviceAlarm.intent(
            JSONObject()
                .put("hour", 7)
                .put("minute", 30)
                .put("message", "起床")
                .put("skip_ui", false)
                .put("vibrate", true)
                .put("days", JSONArray().put(2).put(3).put(4).put(5).put(6)),
        )

        assertEquals(AlarmClock.ACTION_SET_ALARM, intent.action)
        assertEquals(7, intent.getIntExtra(AlarmClock.EXTRA_HOUR, -1))
        assertEquals(30, intent.getIntExtra(AlarmClock.EXTRA_MINUTES, -1))
        assertEquals("起床", intent.getStringExtra(AlarmClock.EXTRA_MESSAGE))
        assertFalse(intent.getBooleanExtra(AlarmClock.EXTRA_SKIP_UI, true))
        assertEquals(true, intent.getBooleanExtra(AlarmClock.EXTRA_VIBRATE, false))
        assertEquals(arrayListOf(2, 3, 4, 5, 6), intent.getIntegerArrayListExtra(AlarmClock.EXTRA_DAYS))
        assertFalse(intent.flags and android.content.Intent.FLAG_ACTIVITY_NEW_TASK != 0)
    }

    @Test
    fun omitsOptionalExtrasAndRejectsABadClock() {
        val intent = DeviceAlarm.intent(JSONObject().put("hour", 0).put("minute", 0))
        assertNull(intent.getStringExtra(AlarmClock.EXTRA_MESSAGE))
        assertFalse(intent.hasExtra(AlarmClock.EXTRA_VIBRATE))
        assertNull(intent.getIntegerArrayListExtra(AlarmClock.EXTRA_DAYS))

        try {
            DeviceAlarm.intent(JSONObject().put("hour", 24).put("minute", 0))
            throw AssertionError("expected invalid_time")
        } catch (e: IllegalArgumentException) {
            assertEquals("invalid_time", e.message)
        }
    }
}
