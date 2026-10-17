package com.example.handbean_probe

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SettingsSelectOptionsTest {
    @Test
    fun readsChildOnTapHandlesAndSelectedFlags() {
        val json = JSONObject()
            .put("type", "settings_select")
            .put(
                "props",
                JSONObject()
                    .put("text", "None (use provider default)")
                    .put("id", "select-default")
                    .put("accessibility_role", "dropdown"),
            )
            .put(
                "children",
                JSONArray()
                    .put(option("None (use provider default)", "{:default_model, \"\"}", 11, true))
                    .put(option("Alpha", "{:default_model, \"alpha/one\"}", 12, false)),
            )
            .toString()

        val node = MobJson.parseNode(json)
        val options = settingsSelectOptions(node)
        assertEquals(2, options.size)
        assertEquals("None (use provider default)", options[0].text)
        assertEquals(11, options[0].tapHandle)
        assertTrue(options[0].selected)
        assertEquals("{:default_model, \"alpha/one\"}", options[1].id)
        assertEquals(12, options[1].tapHandle)
        assertFalse(options[1].selected)
    }

    @Test
    fun readsChildrenFromOtpJsonEncodeKeyOrder() {
        // Mob.Renderer uses :json.encode, which emits children before type/props.
        val json =
            """{"children":[{"children":[],"props":{"accessibility_role":"menuitem","id":"{:default_model, \"\"}","on_tap":1,"selected":true,"text":"None (use provider default)"},"type":"text"},{"children":[],"props":{"accessibility_role":"menuitem","id":"{:default_model, \"stepfun/step-router-v1\"}","on_tap":2,"selected":false,"text":"Step Router v1"},"type":"text"}],"props":{"accessibility_role":"dropdown","id":"select-default","text":"None (use provider default)"},"type":"settings_select"}"""

        val options = settingsSelectOptions(MobJson.parseNode(json))
        assertEquals(2, options.size)
        assertEquals("None (use provider default)", options[0].text)
        assertEquals(1, options[0].tapHandle)
        assertTrue(options[0].selected)
        assertEquals("Step Router v1", options[1].text)
        assertEquals(2, options[1].tapHandle)
    }

    private fun option(text: String, id: String, handle: Int, selected: Boolean): JSONObject =
        JSONObject()
            .put("type", "text")
            .put(
                "props",
                JSONObject()
                    .put("text", text)
                    .put("id", id)
                    .put("on_tap", handle)
                    .put("selected", selected)
                    .put("accessibility_role", "menuitem"),
            )
            .put("children", JSONArray())
}
