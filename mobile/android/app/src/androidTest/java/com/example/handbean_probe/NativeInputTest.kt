package com.example.handbean_probe

import android.os.Process
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.espresso.Espresso.pressBack
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Exercises the real Compose InputConnection and BEAM echo, not ASCII key injection.
 * ARC owns the keyboard candidate window outside Android; this verifies the IME
 * protocol, not that external candidate window's visual behavior.
 */
@RunWith(AndroidJUnit4::class)
class NativeInputTest {
    @get:Rule val ui = createAndroidComposeRule<MainActivity>()

    private fun node(id: String): MobNode? {
        fun find(n: MobNode?): MobNode? = when {
            n == null -> null
            n.props["id"] == id -> n
            else -> n.children.firstNotNullOfOrNull { find(it) }
        }
        return find(MobBridge.rootState.value.node)
    }

    private fun tap(id: String) {
        ui.waitUntil(15_000) { node(id) != null }
        ui.onNodeWithTag(id).performClick()
    }

    private fun echo(text: String) {
        // value on the rendered Mob node comes BACK from HomeScreen assigns.
        ui.waitUntil(5_000) { node("draft")?.props?.get("value") == text }
        assertEquals(text, node("draft")?.props?.get("value"))
    }

    @Test
    fun composingUnicodeSelectionMultilineAndActivityRecreation() {
        tap("{:page, :history}")
        tap("new_chat")
        tap("draft")
        lateinit var connection: InputConnection
        ui.runOnIdle {
            connection = requireNotNull(ui.activity.currentFocus?.onCreateInputConnection(EditorInfo()))
            assertTrue(connection.setComposingText("ni", 1))
        }
        echo("ni")
        ui.runOnIdle { assertTrue(connection.setComposingText("你好", 1)) }
        echo("你好")
        ui.runOnIdle {
            assertTrue(connection.finishComposingText())
            assertTrue(connection.commitText("🙂", 1))
        }
        echo("你好🙂")
        ui.runOnIdle {
            assertTrue(connection.setSelection(1, 1))
            assertTrue(connection.commitText("A", 1))
        }
        echo("你A好🙂")
        ui.runOnIdle { assertTrue(connection.deleteSurroundingText(1, 0)) }
        echo("你好🙂")
        ui.runOnIdle {
            assertTrue(connection.setSelection(0, 4))
            assertTrue(connection.commitText("第一行\n第二行🙂\n第三行", 1))
        }
        echo("第一行\n第二行🙂\n第三行")
        val pid = Process.myPid()
        ui.activityRule.scenario.recreate()
        echo("第一行\n第二行🙂\n第三行")
        assertEquals(pid, Process.myPid())

        tap("draft")
        ui.runOnIdle {
            connection = requireNotNull(ui.activity.currentFocus?.onCreateInputConnection(EditorInfo()))
            assertTrue(connection.setSelection(0, "第一行\n第二行🙂\n第三行".length))
            assertTrue(connection.commitText("", 1))
        }
        echo("")
        ui.runOnIdle { assertTrue(connection.performEditorAction(EditorInfo.IME_ACTION_SEND)) }
        ui.waitUntil(5_000) {
            fun hasError(n: MobNode): Boolean = n.props["text"] == "请输入消息" || n.children.any { hasError(it) }
            MobBridge.rootState.value.node?.let { hasError(it) } == true
        }
        // No model request was sent; finish with a clean new chat.
        tap("{:page, :history}")
        tap("new_chat")
        tap("{:page, :settings}")
        ui.waitUntil(5_000) { node("add_model") != null }
        pressBack()
        ui.waitUntil(5_000) { node("draft") != null }
        assertFalse(ui.activity.isFinishing)
        tap("{:page, :history}")
        ui.waitUntil(5_000) { node("new_chat") != null }
        pressBack()
        ui.waitUntil(5_000) { node("draft") != null }
        assertFalse(ui.activity.isFinishing)
    }
}
