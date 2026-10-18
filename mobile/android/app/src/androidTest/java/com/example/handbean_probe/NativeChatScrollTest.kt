package com.example.handbean_probe

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.dp
import androidx.core.graphics.ColorUtils
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NativeChatScrollTest {
    @get:Rule val ui = createComposeRule()

    private fun row(id: String? = null, summary: String = "", height: Int = 300) = MobNode(
        type = "row",
        props = buildMap {
            put("height", height)
            if (id != null) {
                put("nav_user_id", id)
                put("nav_user_summary", summary)
            }
        },
        children = emptyList(),
    )

    private fun timeline(
        id: String,
        children: List<MobNode>,
        historyBefore: String? = null,
        topHandle: Int? = null,
    ) = MobNode(
        "scroll",
        buildMap {
            put("id", id)
            if (historyBefore != null) put("history_before", historyBefore)
            if (topHandle != null) put("on_top_reached", topHandle)
        },
        children,
    )

    @Composable
    private fun render(node: MobNode) {
        val height = node.props["height"] as Int
        Box(Modifier.fillMaxWidth().height(height.dp).testTag("row-${node.props["nav_user_id"]}")) {
            Text(node.props["nav_user_summary"] as? String ?: "filler")
        }
    }

    private fun state(id: String) = requireNotNull(MobBridge.scrollHandle(id).scrollState)

    @Test fun menuTextHasReadableContrastEvenWithDarkHostTheme() {
        val longSummary = "这是需要保持单行并在末尾省略的很长消息摘要。".repeat(6)
        ui.setContent {
            MaterialTheme(colorScheme = darkColorScheme()) {
                NativeChatScroll(
                    timeline("contrast", listOf(row("first", "First"), row("second", longSummary))),
                    Modifier.height(240.dp),
                    renderChild = { render(it) },
                )
            }
        }
        ui.waitUntil { state("contrast").maxValue > 0 && state("contrast").value == state("contrast").maxValue }
        ui.onNodeWithTag("chat-nav-toggle").performClick()

        listOf("first" to "1. First", "second" to "✓ 2. $longSummary").forEach { (id, label) ->
            val layouts = mutableListOf<TextLayoutResult>()
            ui.onNodeWithText(label).performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
            assertEquals(1, layouts.single().lineCount)
            if (id == "second") assertTrue(layouts.single().isLineEllipsized(0))
            val style = layouts.single().layoutInput.style
            val foreground = style.color.toArgb()
            val background = if (id == "second") Color(0xFFF0EEEA) else Color(0xFFFAF9F7)
            assertTrue("$label must meet WCAG AA", ColorUtils.calculateContrast(foreground, background.toArgb()) >= 4.5)
        }
    }

    @Test fun controlsFollowMessageCountAndBottomDistance() {
        val node = mutableStateOf(timeline("count", emptyList()))
        ui.setContent { NativeChatScroll(node.value, Modifier.height(240.dp)) { render(it) } }
        ui.onNodeWithTag("chat-nav-toggle").assertDoesNotExist()
        ui.onNodeWithTag("chat-nav-bottom").assertDoesNotExist()

        ui.runOnIdle { node.value = timeline("count", listOf(row("one"), row("two"))) }
        ui.waitUntil { state("count").maxValue > 0 && state("count").value == state("count").maxValue }
        ui.onNodeWithTag("chat-nav-toggle").assertExists()
        ui.onNodeWithTag("chat-nav-bottom").assertDoesNotExist()
        ui.runOnIdle { runBlocking { state("count").scrollTo(0) } }
        ui.onNodeWithTag("chat-nav-bottom").assertExists().performClick()
        ui.waitUntil { state("count").value == state("count").maxValue }
    }

    @Test fun menuItemsJumpToMeasuredUserRowsAndClose() {
        ui.setContent {
            NativeChatScroll(
                timeline("jumps", listOf(row("first", "First"), row(null), row("second", "Second"))),
                Modifier.height(240.dp),
                renderChild = { render(it) },
            )
        }
        ui.waitUntil { state("jumps").maxValue > 0 }
        ui.onNodeWithTag("chat-nav-toggle").performClick()
        ui.onNodeWithTag("chat-nav-panel").assertExists()
        ui.onNodeWithTag("chat-nav-item-first").performClick()
        ui.waitUntil { state("jumps").value == 0 }
        ui.onNodeWithTag("chat-nav-panel").assertDoesNotExist()

        ui.onNodeWithTag("chat-nav-toggle").performClick()
        ui.onNodeWithTag("chat-nav-item-second").performClick()
        ui.waitUntil { state("jumps").value > 500 }
        ui.onNodeWithTag("chat-nav-panel").assertDoesNotExist()
    }

    @Test fun growthFollowsOnlyWhenPreviouslyPinned() {
        val rows = mutableStateOf(listOf(row("one"), row("two")))
        ui.setContent { NativeChatScroll(timeline("growth", rows.value), Modifier.height(240.dp)) { render(it) } }
        ui.waitUntil { state("growth").value == state("growth").maxValue && state("growth").maxValue > 0 }
        ui.runOnIdle { runBlocking { state("growth").scrollTo(80) } }
        ui.runOnIdle { rows.value = rows.value + row(null, height = 200) }
        ui.waitUntil { state("growth").maxValue > 700 }
        ui.runOnIdle { assertEquals(80, state("growth").value) }

        ui.runOnIdle { runBlocking { state("growth").scrollTo(state("growth").maxValue) } }
        val oldMax = state("growth").maxValue
        ui.runOnIdle { rows.value = rows.value + row(null, height = 200) }
        ui.waitUntil { state("growth").maxValue > oldMax && state("growth").value == state("growth").maxValue }
    }

    @Test fun reachingTopLoadsOnceAndPrependingKeepsTheVisibleAnchor() {
        val node = mutableStateOf(
            timeline(
                "older",
                listOf(row("one"), row("two"), row("three")),
                historyBefore = "cursor-2",
                topHandle = 77,
            ),
        )
        var topEvents = 0
        ui.setContent {
            NativeChatScroll(
                node.value,
                Modifier.height(240.dp),
                onTopReached = { handle ->
                    assertEquals(77, handle)
                    topEvents += 1
                },
            ) { render(it) }
        }
        ui.waitUntil { state("older").maxValue > 0 && state("older").value == state("older").maxValue }
        val oldMax = state("older").maxValue

        ui.runOnIdle { runBlocking { state("older").scrollTo(0) } }
        ui.waitUntil { topEvents == 1 }

        ui.runOnIdle {
            node.value = timeline(
                "older",
                listOf(row("earlier-one"), row("earlier-two")) + node.value.children,
                historyBefore = "cursor-1",
                topHandle = 77,
            )
        }
        ui.waitUntil {
            state("older").maxValue == oldMax + 600 && state("older").value == 600
        }
        ui.runOnIdle { assertEquals(1, topEvents) }

        ui.runOnIdle { runBlocking { state("older").scrollTo(0) } }
        ui.waitUntil { topEvents == 2 }
    }

    @Test fun switchingTimelineResetsPositionClosesPopupAndRegistersNewId() {
        val node = mutableStateOf(timeline("old", listOf(row("old-a"), row("old-b"))))
        ui.setContent { NativeChatScroll(node.value, Modifier.height(240.dp)) { render(it) } }
        ui.waitUntil { state("old").maxValue > 0 }
        ui.onNodeWithTag("chat-nav-toggle").performClick()
        ui.onNodeWithTag("chat-nav-panel").assertExists()

        ui.runOnIdle { node.value = timeline("new", listOf(row("new-a"), row("new-b"))) }
        ui.waitUntil { MobBridge.scrollHandle("new").scrollState != null && state("new").maxValue > 0 }
        ui.onNodeWithTag("chat-nav-panel").assertDoesNotExist()
        ui.runOnIdle {
            assertTrue(state("new") !== state("old"))
            assertEquals(state("new").maxValue, state("new").value)
        }
        ui.onNodeWithTag("chat-nav-toggle").performClick()
        ui.onNodeWithTag("chat-nav-item-new-a").assertExists()
        ui.onNodeWithTag("chat-nav-item-old-a").assertDoesNotExist()
    }
}
