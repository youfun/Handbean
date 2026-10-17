package com.example.handbean_probe

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class WorkspaceScrollTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun returningFromViewerRetainsScrollButNewWorkspaceDoesNot() {
        val viewer = mutableStateOf(false)
        val id = mutableStateOf("workspace-scroll-test-${System.nanoTime()}")
        compose.setContent {
            Box(Modifier.size(300.dp, 200.dp)) {
                if (viewer.value) {
                    Text("File viewer")
                } else {
                    RenderNode(
                        MobNode(
                            "scroll",
                            mapOf("id" to id.value, "retain_scroll" to true),
                            List(50) { index ->
                                MobNode("text", mapOf("text" to "File $index", "padding" to 12), emptyList())
                            },
                        ),
                    )
                }
            }
        }
        val original = compose.runOnIdle { requireNotNull(MobBridge.scrollHandle(id.value).scrollState) }
        compose.runOnIdle {
            assertTrue(original.maxValue > 400)
            original.dispatchRawDelta(400f)
        }
        compose.runOnIdle { viewer.value = true }
        compose.runOnIdle { viewer.value = false }
        compose.runOnIdle {
            assertSame(original, MobBridge.scrollHandle(id.value).scrollState)
            assertEquals(400, original.value)
            id.value += "-new-workspace"
        }
        compose.runOnIdle {
            val changed = requireNotNull(MobBridge.scrollHandle(id.value).scrollState)
            assertNotSame(original, changed)
            assertEquals(0, changed.value)
        }
    }
}
