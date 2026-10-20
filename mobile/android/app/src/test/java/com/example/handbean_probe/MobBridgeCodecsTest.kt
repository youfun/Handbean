package com.example.handbean_probe

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MobBridgeCodecsTest {
    @Test
    fun renderWindowKeepsCountsOrderAndEscapesArbitraryTransitions() {
        val transition = "推送😀\"\\\n\t\u0000"
        val json = MobRenderStatsCodec.encode(false, 242, 240, listOf(
            MobRenderStatsCodec.FrameSample(125.25, 241, transition),
            MobRenderStatsCodec.FrameSample(42.0, 240, "none"),
        ))
        val payload = JSONObject(json)
        assertFalse(payload.getBoolean("enabled"))
        assertEquals(242L, payload.getLong("recorded"))
        assertEquals(2L, payload.getLong("dropped"))
        val samples = payload.getJSONArray("samples")
        assertEquals(2, samples.length())
        assertEquals(transition, samples.getJSONObject(0).getString("transition"))
        assertEquals(125.25, samples.getJSONObject(0).getDouble("apply_us"), 0.0)
        assertEquals(241L, samples.getJSONObject(0).getLong("seq"))
        assertEquals(240L, samples.getJSONObject(1).getLong("seq"))
    }

    @Test
    fun emptyRenderWindowReportsNoDrops() {
        val payload = JSONObject(MobRenderStatsCodec.encode(true, 0, 240, emptyList()))
        assertTrue(payload.getBoolean("enabled"))
        assertEquals(0, payload.getInt("recorded"))
        assertEquals(0, payload.getInt("dropped"))
        assertEquals(0, payload.getJSONArray("samples").length())
    }

    @Test
    fun alertButtonsRetainOrderActionsAndEmptyDefaults() {
        val buttons = MobAlertCodec.parseButtons("""[
            {"label":"确定😀","style":"destructive","action":"confirm","ignored":true},
            {"label":"取消","style":"cancel","action":"dismiss"},
            {}
        ]""")
        assertEquals(listOf(
            mapOf("label" to "确定😀", "style" to "destructive", "action" to "confirm"),
            mapOf("label" to "取消", "style" to "cancel", "action" to "dismiss"),
            mapOf("label" to "", "style" to "", "action" to ""),
        ), buttons)
    }

    @Test
    fun malformedAlertPayloadRejectsTheEntireButtonList() {
        for (json in listOf("broken", "{}", "[null]", """[{"label":"first"}, 1]""")) {
            assertTrue(json, MobAlertCodec.parseButtons(json).isEmpty())
        }
    }
}
