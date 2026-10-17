package com.example.handbean_probe

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performScrollTo
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Rule
import org.junit.Test

/**
 * Settings delete/confirm sheets must not use the default medium+large detents
 * with a weight:1 body. That combination sizes a flex column to the half-height
 * sheet and parks Cancel/Confirm below the fold
 * (`artifacts/settings-final-delete-dialog.png`).
 *
 * Production trees use a content detent and an unweighted body so the first
 * visible frame includes the actions; MobSheet scrolls when the body is long.
 */
class SettingsConfirmSheetTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    @Test
    fun shortConfirmSheetShowsCancelOnFirstFrame() {
        composeTestRule.setContent {
            RenderNode(confirmSheet(bodyLines = shortBody()))
        }

        composeTestRule.waitForText("Delete provider stepfun and its 1 models?")
        composeTestRule.onNodeWithText("Cancel").assertIsDisplayed()
        composeTestRule.onNodeWithText("Confirm delete is unavailable").assertIsDisplayed()
    }

    @Test
    fun longConfirmBodyKeepsCancelReachable() {
        composeTestRule.setContent {
            RenderNode(confirmSheet(bodyLines = longBody()))
        }

        composeTestRule.waitForText("Delete provider stepfun and its 1 models?")
        composeTestRule
            .onNodeWithText("Cancel")
            .performScrollTo()
            .assertIsDisplayed()
    }

    private fun confirmSheet(bodyLines: List<String>): MobNode {
        val body = JSONObject()
            .put("type", "column")
            .put("props", JSONObject().put("id", "settings-confirm-body").put("fill_width", true))
            .put("children", JSONArray().apply {
                bodyLines.forEach { line -> put(textNode(line)) }
            })

        val column = JSONObject()
            .put("type", "column")
            .put("props", JSONObject().put("fill_width", true).put("padding", 16))
            .put(
                "children",
                JSONArray()
                    .put(textNode("Delete provider stepfun and its 1 models?", 17))
                    .put(body)
                    .put(textNode("Confirm delete is unavailable"))
                    .put(textNode("Cancel")),
            )

        val json = JSONObject()
            .put("type", "sheet")
            .put(
                "props",
                JSONObject()
                    .put("id", "settings-confirm")
                    .put("background", 4294967295L)
                    .put("detents", JSONArray().put(JSONObject().put("type", "content"))),
            )
            .put("children", JSONArray().put(column))

        return json.toMobNode()
    }

    private fun shortBody(): List<String> =
        listOf(
            "This is the only provider. The catalog must keep at least one.",
            "No settings reference this entry.",
        )

    private fun longBody(): List<String> =
        shortBody() + (1..40).map { index -> "Still referenced. Replacement option $index." }

    private fun textNode(text: String, size: Int? = null): JSONObject {
        val props = JSONObject().put("text", text)
        if (size != null) props.put("text_size", size)
        return JSONObject()
            .put("type", "text")
            .put("props", props)
            .put("children", JSONArray())
    }

    private fun androidx.compose.ui.test.junit4.ComposeContentTestRule.waitForText(text: String) {
        waitUntil(timeoutMillis = 5_000) {
            onAllNodesWithText(text).fetchSemanticsNodes().isNotEmpty()
        }
        onNodeWithText(text).assertIsDisplayed()
    }
}
