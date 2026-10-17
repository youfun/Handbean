package com.example.handbean_probe

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class SettingsButtonTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    @Test
    fun secondaryActionKeepsAccessibleTouchTargetAndDispatchesTap() {
        val taps = mutableListOf<Int>()
        composeTestRule.setContent {
            SettingsButton(buttonNode("Edit provider", "edit_provider"), onTap = { taps.add(it) })
        }

        composeTestRule.onNodeWithText("Edit provider").assertIsDisplayed()
        composeTestRule.onNodeWithTag("edit_provider").performClick()
        composeTestRule.runOnIdle { assertEquals(listOf(31), taps) }

        val hit = composeTestRule.onNodeWithTag("edit_provider").getUnclippedBoundsInRoot()
        val hitHeight = hit.bottom - hit.top
        val hitWidth = hit.right - hit.left

        assertTrue(hitHeight >= 48.dp)
        assertTrue(hitWidth >= 48.dp)
    }

    @Test
    fun longChineseAndFontScaleDoNotClipLabel() {
        val label = "确认删除这个提供商以及其下的全部模型配置项"
        composeTestRule.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density, fontScale = 1.3f)) {
                Box(Modifier.fillMaxSize()) {
                    Box(Modifier.width(220.dp)) {
                        RenderNode(buttonNode(label, "confirm_delete", fillWidth = false, handle = 44))
                    }
                }
            }
        }

        composeTestRule.onNodeWithText(label).assertIsDisplayed()
        val hit = composeTestRule.onNodeWithTag("confirm_delete").getUnclippedBoundsInRoot()
        assertTrue((hit.bottom - hit.top) >= 48.dp)
    }

    private fun buttonNode(
        text: String,
        id: String,
        fillWidth: Boolean = false,
        handle: Int = 31,
    ): MobNode {
        val json = JSONObject()
            .put("type", "settings_button")
            .put(
                "props",
                JSONObject()
                    .put("text", text)
                    .put("id", id)
                    .put("on_tap", handle)
                    .put("text_size", 13)
                    .put("fill_width", fillWidth)
                    .put("background", 4294112240L)
                    .put("text_color", 4279830549L)
                    .put("corner_radius", 8)
                    .put("accessibility_role", "button"),
            )
            .put("children", JSONArray())
            .toString()
        return MobJson.parseNode(json)
    }
}
