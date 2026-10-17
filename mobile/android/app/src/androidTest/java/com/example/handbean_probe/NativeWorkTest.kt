package com.example.handbean_probe

import android.view.inputmethod.EditorInfo
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Run with the controlled on-device NativeWorkArcProvider fixture.
 * The host releases the held tool only after checking the actual steer queue.
 */
@RunWith(AndroidJUnit4::class)
class NativeWorkTest {
    @get:Rule val ui = createAndroidComposeRule<MainActivity>()

    private fun nodes(): List<MobNode> {
        fun flatten(node: MobNode): List<MobNode> = listOf(node) + node.children.flatMap(::flatten)
        return MobBridge.rootState.value.node?.let(::flatten) ?: emptyList()
    }

    @Test
    fun unicodeSubmitDuringHeldToolPreservesRunAndFinalAnswer() {
        assumeTrue(InstrumentationRegistry.getArguments().getString("work_fixture") == "true")
        ui.waitUntil(120_000) {
            nodes().any { (it.props["text"] as? String)?.contains("native_work_hold") == true }
        }
        ui.onNodeWithTag("draft").performClick()
        ui.runOnIdle {
            val input = requireNotNull(ui.activity.currentFocus?.onCreateInputConnection(EditorInfo()))
            assertTrue(input.commitText("追加中文🙂 不要取消工具", 1))
        }
        ui.waitUntil(5_000) {
            nodes().any { it.props["id"] == "draft" && it.props["value"] == "追加中文🙂 不要取消工具" }
        }
        ui.onNodeWithTag("send").performClick()
        ui.waitUntil(5_000) {
            nodes().any { it.props["id"] == "draft" && it.props["value"] == "" } &&
                nodes().any { it.props["text"] == "追加中文🙂 不要取消工具" }
        }
        assertTrue(nodes().any { it.props["id"] == "stop" })
        ui.waitUntil(120_000) {
            nodes().any { (it.props["text"] as? String)?.contains("已保留工具结果和中文追加消息") == true }
        }
        ui.waitUntil(5_000) { nodes().none { it.props["id"] == "stop" } }
        assertTrue(nodes().any { (it.props["text"] as? String)?.contains("展开过程") == true })
    }
}
