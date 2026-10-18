package com.example.handbean_probe

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.dp
import androidx.test.espresso.Espresso.pressBack
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class SettingsSelectTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    @Test
    fun opensMenuSelectsOptionAndDismissesOnBack() {
        val taps = mutableListOf<Int>()
        val node = selectNode()

        composeTestRule.setContent {
            Box(Modifier.fillMaxSize()) {
                Text(
                    "Outside",
                    modifier = Modifier
                        .align(Alignment.TopStart)
                        .testTag("select-outside"),
                )
                SettingsSelect(node, onOptionTap = { taps.add(it) })
            }
        }

        composeTestRule.onNodeWithText("Off").assertIsDisplayed()
        composeTestRule.onNodeWithContentDescription("Open menu").assertIsDisplayed()
        composeTestRule.onNodeWithTag("select-reasoning").performClick()
        composeTestRule.onNodeWithText("Medium").assertIsDisplayed()
        composeTestRule.onNodeWithTag("{:reasoning, \"medium\"}").performClick()
        composeTestRule.runOnIdle { assertEquals(listOf(22), taps) }
        composeTestRule.onNodeWithText("High").assertDoesNotExist()

        composeTestRule.onNodeWithTag("select-reasoning").performClick()
        composeTestRule.onNodeWithText("High").assertIsDisplayed()
        composeTestRule.onNodeWithTag("select-outside").performClick()
        composeTestRule.waitForIdle()
        composeTestRule.onNodeWithText("High").assertDoesNotExist()
        composeTestRule.runOnIdle { assertEquals(listOf(22), taps) }

        composeTestRule.onNodeWithTag("select-reasoning").performClick()
        composeTestRule.onNodeWithText("High").assertIsDisplayed()
        pressBack()
        composeTestRule.waitForIdle()
        composeTestRule.onNodeWithText("High").assertDoesNotExist()
        composeTestRule.onNodeWithTag("select-reasoning").assertIsDisplayed()
        composeTestRule.runOnIdle { assertEquals(listOf(22), taps) }
    }

    @Test
    fun compactComposerSelectKeepsNativeMenuAndTouchTarget() {
        val taps = mutableListOf<Int>()
        val base = selectNode(includeCompactChrome = true)
        val node = base.copy(props = base.props + mapOf("compact" to true, "fill_width" to false))
        composeTestRule.setContent {
            SettingsSelect(node, onOptionTap = { taps.add(it) })
        }
        val bounds = composeTestRule.onNodeWithTag("select-reasoning").getUnclippedBoundsInRoot()
        assertTrue(bounds.bottom - bounds.top >= 48.dp)
        composeTestRule.onNodeWithTag("select-reasoning").performClick()
        composeTestRule.onNodeWithText("High").assertIsDisplayed()
        composeTestRule.onNodeWithTag("{:reasoning, \"high\"}").performClick()
        composeTestRule.runOnIdle { assertEquals(listOf(23), taps) }
        composeTestRule.onNodeWithText("High").assertDoesNotExist()
    }

    @Test
    fun rendererJsonOptionsStayVisibleInsideClippedScroll() {
        val node = MobJson.parseNode(RENDERER_JSON)

        composeTestRule.setContent {
            Column(
                Modifier
                    .height(400.dp)
                    .verticalScroll(rememberScrollState()),
            ) {
                RenderNode(node)
            }
        }

        composeTestRule.onNodeWithTag("select-default").performClick()
        composeTestRule.onNodeWithText("Step Router v1").assertIsDisplayed()
        composeTestRule.onNodeWithTag("{:default_model, \"\"}").assertIsDisplayed()
    }

    companion object {
        // Captured from Mob.Renderer + :json.encode (children key first).
        private const val RENDERER_JSON =
            """{"children":[{"children":[],"props":{"accessibility_role":"menuitem","id":"{:default_model, \"\"}","on_tap":1,"selected":true,"text":"None (use provider default)"},"type":"text"},{"children":[],"props":{"accessibility_role":"menuitem","id":"{:default_model, \"stepfun/step-router-v1\"}","on_tap":2,"selected":false,"text":"Step Router v1"},"type":"text"}],"props":{"accessibility_role":"dropdown","background":4294243312,"border_color":4293189850,"border_width":1,"corner_radius":8,"fill_width":true,"id":"select-default","icon_content_description":"Open menu","padding_left":12,"padding_right":12,"text":"None (use provider default)","text_size":14},"type":"settings_select"}"""
    }

    private fun selectNode(includeCompactChrome: Boolean = false): MobNode {
        val props = JSONObject()
            .put("text", "Off")
            .put("id", "select-reasoning")
            .put("icon_content_description", "Open menu")
        if (includeCompactChrome) {
            props
                .put("text_size", 14)
                .put("fill_width", true)
                .put("padding_left", 12)
                .put("padding_right", 12)
                .put("background", 4294112240L)
                .put("border_color", 4293198042L)
                .put("border_width", 1)
                .put("corner_radius", 8)
        }
        val json = JSONObject()
            .put("type", "settings_select")
            .put("props", props)
            .put(
                "children",
                JSONArray()
                    .put(option("Off", "{:reasoning, \"off\"}", 21, true))
                    .put(option("Medium", "{:reasoning, \"medium\"}", 22, false))
                    .put(option("High", "{:reasoning, \"high\"}", 23, false)),
            )
            .toString()
        return MobJson.parseNode(json)
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
                    .put("selected", selected),
            )
            .put("children", JSONArray())
}
