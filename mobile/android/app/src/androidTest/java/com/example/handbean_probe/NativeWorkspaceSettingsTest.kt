package com.example.handbean_probe

import android.view.inputmethod.EditorInfo
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Opt-in real UI test: only creates a named test workspace, never sends a model request. */
@RunWith(AndroidJUnit4::class)
class NativeWorkspaceSettingsTest {
    @get:Rule val ui = createAndroidComposeRule<MainActivity>()

    private fun node(id: String): MobNode? {
        fun find(n: MobNode?): MobNode? = when {
            n == null -> null
            n.props["id"] == id -> n
            else -> n.children.firstNotNullOfOrNull { find(it) }
        }
        return find(MobBridge.rootState.value.node)
    }

    private fun tap(id: String, scroll: Boolean = false) {
        ui.waitUntil(15_000) { node(id) != null }
        if (scroll) ui.onNodeWithTag(id).performScrollTo()
        ui.onNodeWithTag(id).performClick()
    }

    private fun input(id: String, value: String) {
        tap(id)
        ui.runOnIdle {
            val connection = requireNotNull(ui.activity.currentFocus?.onCreateInputConnection(EditorInfo()))
            val old = node(id)?.props?.get("value") as? String ?: ""
            assertTrue(connection.setSelection(0, old.length))
            assertTrue(connection.commitText(value, 1))
        }
        ui.waitUntil(5_000) { node(id)?.props?.get("value") == value }
    }

    @Test
    fun unicodeCreateSettingsAndWorkspaceDraftRoundTrip() {
        val previous = InstrumentationRegistry.getArguments().getString("workspaceReviewPrevious")
        assumeTrue("requires an isolated prior workspace", !previous.isNullOrBlank())
        val name = "验收工作区🙂 ${System.currentTimeMillis()}"
        tap("{:page, :workspace}")
        tap("open_create", true)
        input("workspace_name", name)
        tap("create_workspace", true)
        ui.waitUntil(5_000) { node("draft") != null }
        assertEquals(name, node("{:page, :workspace}")?.props?.get("text"))
        input("draft", "当前项目草稿🙂")
        tap("{:page, :settings}")
        tap("select-reasoning", true)
        tap("{:reasoning, \"medium\"}", true)
        ui.waitUntil(5_000) {
            val label = node("select-reasoning")?.props?.get("text") as? String
            label == "中" || label == "Medium" || label == "medium"
        }
        // Settings changes persist; returning to chat must retain its draft.
        androidx.test.espresso.Espresso.pressBack()
        ui.waitUntil(5_000) { node("draft")?.props?.get("value") == "当前项目草稿🙂" }
        tap("{:page, :workspace}")
        val oldTag = "{:workspace, \"$previous\"}"
        tap(oldTag, true)
        ui.waitUntil(5_000) { node("draft") != null }
        assertEquals("", node("draft")?.props?.get("value"))
        input("draft", "另一个项目独立草稿")
        tap("{:page, :workspace}")
        fun findSwitch(n: MobNode?): String? {
            if (n == null) return null
            if (n.children.any { child ->
                child.children.any { it.props["text"] == name }
            }) {
                return n.children.mapNotNull { it.props["id"] as? String }
                    .firstOrNull { it.startsWith("{:workspace,") }
            }
            return n.children.firstNotNullOfOrNull { findSwitch(it) }
        }
        ui.waitUntil(5_000) { findSwitch(MobBridge.rootState.value.node) != null }
        val createdTag = requireNotNull(findSwitch(MobBridge.rootState.value.node))
        tap(createdTag, true)
        ui.waitUntil(5_000) { node("draft")?.props?.get("value") == "当前项目草稿🙂" }
        input("draft", "")
        tap("{:page, :settings}")
        ui.waitUntil(5_000) {
            val label = node("select-reasoning")?.props?.get("text") as? String
            label == "中" || label == "Medium" || label == "medium"
        }
    }
}
