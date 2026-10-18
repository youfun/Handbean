package com.example.handbean_probe.attachments

import android.content.Intent
import android.provider.AlarmClock
import org.json.JSONArray
import org.json.JSONObject

/**
 * Prefill the system clock via [AlarmClock.ACTION_SET_ALARM].
 *
 * This does not insert an alarm by itself. Many devices still require the user
 * to tap save. [AlarmClock.EXTRA_SKIP_UI] is only a hint and is off unless the
 * caller sets `skip_ui`. No accessibility service is involved.
 */
object DeviceAlarm {
    fun intent(payload: JSONObject): Intent {
        val hour = payload.optInt("hour", -1)
        val minute = payload.optInt("minute", -1)
        require(hour in 0..23 && minute in 0..59) { "invalid_time" }

        return Intent(AlarmClock.ACTION_SET_ALARM).apply {
            putExtra(AlarmClock.EXTRA_HOUR, hour)
            putExtra(AlarmClock.EXTRA_MINUTES, minute)
            putExtra(AlarmClock.EXTRA_SKIP_UI, payload.optBoolean("skip_ui", false))
            payload.optString("message").trim().ifBlank { null }?.let {
                putExtra(AlarmClock.EXTRA_MESSAGE, it.take(120))
            }
            if (payload.has("vibrate") && !payload.isNull("vibrate")) {
                putExtra(AlarmClock.EXTRA_VIBRATE, payload.optBoolean("vibrate"))
            }
            days(payload)?.let { putExtra(AlarmClock.EXTRA_DAYS, it) }
        }
    }

    private fun days(payload: JSONObject): ArrayList<Int>? {
        val raw = payload.optJSONArray("days") ?: return null
        val days = ArrayList<Int>()
        for (index in 0 until raw.length()) {
            val day = raw.optInt(index, -1)
            if (day !in 1..7 || day in days) continue
            days += day
        }
        return days.ifEmpty { null }
    }

    /** Exposed for tests that do not want to construct a full payload. */
    fun daysFrom(values: List<Int>): ArrayList<Int>? {
        val array = JSONArray()
        values.forEach { array.put(it) }
        return days(JSONObject().put("days", array))
    }
}
