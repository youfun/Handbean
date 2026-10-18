package com.example.handbean_probe

import android.content.ClipboardManager
import android.content.Context
import android.text.Spanned
import android.widget.TextView
import android.util.Log
import android.view.Choreographer
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.assertContentDescriptionEquals
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.test.core.app.ApplicationProvider
import androidx.test.espresso.Espresso.onView
import androidx.test.espresso.ViewAssertion
import androidx.test.espresso.action.GeneralClickAction
import androidx.test.espresso.action.Press
import androidx.test.espresso.action.Tap
import androidx.test.espresso.action.ViewActions.click
import androidx.test.espresso.matcher.RootMatchers.isPlatformPopup
import androidx.test.espresso.matcher.ViewMatchers.isRoot
import androidx.test.espresso.matcher.ViewMatchers.withText
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertTrue
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NativeMarkdownTest {
    @get:Rule val ui = createComposeRule()

    private val clipboard: ClipboardManager
        get() = ApplicationProvider.getApplicationContext<Context>()
            .getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager

    @Test fun keepsCodeCopyButtonWithoutWholeReplyToolbar() {
        val source = "# Title\n\n```kotlin\nval x = 1\n```\n"
        ui.setContent { NativeMarkdown(source) }

        ui.onNodeWithTag("markdown-copy-all").assertDoesNotExist()
        ui.onNodeWithTag(markdownCodeCopyTag(1))
            .assertContentDescriptionEquals("复制代码")
            .performClick().assertContentDescriptionEquals("已复制")
        awaitClipboard("val x = 1\n")
    }

    @Test fun updatesAnUnterminatedFenceWhileStreaming() {
        val source = mutableStateOf("```txt\none\n")
        ui.setContent { NativeMarkdown(source.value) }
        ui.onNodeWithTag(markdownCodeCopyTag(0)).performClick()
        awaitClipboard("one\n")
        ui.runOnIdle { source.value += "two\n" }
        ui.onNodeWithTag(markdownCodeCopyTag(0)).performClick()
        awaitClipboard("one\ntwo\n")
    }

    @Test fun batchesBurstUpdatesAndFlushesImmediatelyOnCompletion() {
        val source = mutableStateOf("")
        val streaming = mutableStateOf(true)
        MarkdownRenderMetrics.reset()
        ui.setContent {
            NativeMarkdown(source.value, messageId = "stream", streaming = streaming.value)
        }
        ui.waitForIdle()
        val initial = MarkdownRenderMetrics.snapshot().parseCount

        ui.runOnIdle {
            repeat(100) { source.value += "x" }
        }
        ui.waitForIdle()
        val beforePacing = MarkdownRenderMetrics.snapshot().parseCount
        assertEquals(initial, beforePacing)

        val deadline = android.os.SystemClock.uptimeMillis() + 220
        ui.waitUntil(1_000) { android.os.SystemClock.uptimeMillis() >= deadline }
        ui.waitForIdle()
        val paced = MarkdownRenderMetrics.snapshot().parseCount
        assertTrue("parse delta=${paced - initial}", paced - initial in 1..7)

        ui.runOnIdle { streaming.value = false }
        ui.waitForIdle()
        onView(withText("x".repeat(100))).check(ViewAssertion { _, error ->
            if (error != null) throw error
        })
    }

    @Test fun androidRegexKeepsUnicodeGraphemesWhole() {
        val stream = MarkdownStreamController(
            MarkdownStreamConfig(
                startDelayMs = 0,
                minGraphemesPerSecond = 1_000.0,
                maxGraphemesPerSecond = 1_000.0,
                maxGraphemesPerCommit = 1,
            ),
        )
        val clusters = listOf("中", "🙂", "e\u0301", "👩‍💻", "👨‍👩‍👧‍👦")
        stream.update(clusters.joinToString(""), true, 0)
        var expected = ""
        clusters.forEachIndexed { index, cluster ->
            expected += cluster
            assertEquals(expected, stream.tick(34L * (index + 1)))
        }
    }

    @Test fun measuresControlledShortAndLongStreamingFixtures() {
        val source = mutableStateOf("")
        val streaming = mutableStateOf(false)
        val messageId = mutableStateOf("fixture-0")
        ui.setContent {
            NativeMarkdown(source.value, messageId = messageId.value, streaming = streaming.value)
        }
        val short = "# 流式标题\n\n**粗体**、[安全链接](https://example.com) 与 👩‍💻。"
        val long = buildString {
            append("# 长回复\n\n> 引用\n\n")
            repeat(30) { append("- 第 $it 项：组合字 e\u0301 与 emoji 👨‍👩‍👧‍👦\n") }
            append("\n| 名称 | 数值 |\n|---|---:|\n")
            repeat(20) { append("| row-$it | ${it * 17} |\n") }
            append("\n```kotlin\n")
            repeat(80) { append("val item$it = ${it * it}\n") }
            append("```\n")
        }

        logFixtureMeasurement("short", short, 30, 12, source, streaming, messageId)
        logFixtureMeasurement("long", long, 120, 5, source, streaming, messageId)
    }

    @Test fun rendersHeadingAndTableSpansInSelectableNativeViews() {
        ui.setContent { NativeMarkdown("# Heading\n\n| A | B |\n|---|---|\n| 1 | 2 |\n") }
        ui.waitForIdle()
        onView(isRoot()).check(ViewAssertion { view, _ ->
            val textViews = descendants(view)
                .filterIsInstance<TextView>()
                .filter { it.text is Spanned }
                .toList()
            assertTrue(textViews.isNotEmpty())
            assertTrue(textViews.all { it.isTextSelectable })
            val spanNames = textViews.flatMap {
                val text = it.text as Spanned
                text.getSpans(0, text.length, Any::class.java).map { span -> span.javaClass.name }
            }
            assertTrue(spanNames.any { it.contains("Heading", true) || it.contains("RelativeSize") })
            assertTrue(spanNames.any { it.contains("Table", true) })
        })
    }

    @Test fun markwonKeepsIncompleteInlineListTableAndReferenceContentReadable() {
        val source = "**unfinished bold\n\n- list item\n\n| A | B\n\n[linked][later]\n\n[later]: https://example.com"
        ui.setContent { NativeMarkdown(source) }
        ui.waitForIdle()
        onView(isRoot()).check(ViewAssertion { view, _ ->
            val rendered = descendants(view)
                .filterIsInstance<TextView>()
                .joinToString("\n") { it.text.toString() }
            assertTrue(rendered.contains("unfinished bold"))
            assertTrue(rendered.contains("list item"))
            assertTrue(rendered.contains("linked"))
        })
    }

    @Test fun longPressCopiesFullRawMarkdownAcrossParagraphs() {
        val source = "**First** paragraph\n\nSecond [link](https://example.com) paragraph."
        ui.setContent { NativeMarkdown(source) }

        onView(withText("First paragraph")).perform(longPressText())
        onView(withText("复制全文")).inRoot(isPlatformPopup()).perform(click())
        awaitClipboard(source)
    }

    @Test fun longPressActuallySelectsRenderedText() {
        ui.setContent { NativeMarkdown("Select these words") }
        onView(withText("Select these words")).check(ViewAssertion { view, _ ->
            val text = view as TextView
            assertTrue(text.isLongClickable)
            assertTrue(text.movementMethod?.canSelectArbitrarily() == true)
        }).perform(longPressText()).check(ViewAssertion { view, _ ->
            val text = view as TextView
            assertTrue(text.selectionStart >= 0)
            assertTrue(text.selectionEnd > text.selectionStart)
        })
    }

    // TextViews fill the row; their center can be blank space after the text.
    private fun longPressText() = GeneralClickAction(Tap.LONG, { view ->
        val text = view as TextView
        val location = IntArray(2)
        text.getLocationOnScreen(location)
        floatArrayOf(
            location[0] + text.totalPaddingLeft + text.layout.getPrimaryHorizontal(2),
            location[1] + text.totalPaddingTop + text.layout.getLineBottom(0) / 2f,
        )
    }, Press.FINGER)

    private fun descendants(view: android.view.View): Sequence<android.view.View> = sequence {
        yield(view)
        if (view is android.view.ViewGroup) {
            for (index in 0 until view.childCount) yieldAll(descendants(view.getChildAt(index)))
        }
    }

    private fun logFixtureMeasurement(
        name: String,
        content: String,
        chunks: Int,
        intervalMs: Long,
        source: androidx.compose.runtime.MutableState<String>,
        streaming: androidx.compose.runtime.MutableState<Boolean>,
        messageId: androidx.compose.runtime.MutableState<String>,
    ) {
        val baseline = measureFixture(content, chunks, intervalMs, false, source, streaming, messageId)
        val optimized = measureFixture(content, chunks, intervalMs, true, source, streaming, messageId)
        Log.i(
            "NativeMarkdownBench",
            "$name baseline=$baseline optimized=$optimized sourceChars=${content.length} chunks=$chunks intervalMs=$intervalMs",
        )
        assertTrue("$name optimized parses=${optimized.parseCount}", optimized.parseCount < baseline.parseCount)
        assertTrue("$name completion=${optimized.completionMs}", optimized.completionMs < 250)
    }

    private fun measureFixture(
        content: String,
        chunks: Int,
        intervalMs: Long,
        paced: Boolean,
        source: androidx.compose.runtime.MutableState<String>,
        streaming: androidx.compose.runtime.MutableState<Boolean>,
        messageId: androidx.compose.runtime.MutableState<String>,
    ): FixtureMeasurement {
        ui.runOnIdle {
            source.value = ""
            streaming.value = paced
            messageId.value = "${if (paced) "paced" else "baseline"}-${android.os.SystemClock.uptimeMillis()}"
        }
        ui.waitForIdle()
        MarkdownRenderMetrics.reset()
        val frames = FrameRecorder()
        ui.runOnIdle { frames.start() }
        val started = android.os.SystemClock.uptimeMillis()
        var firstVisibleMs = -1L

        for (index in 1..chunks) {
            val target = started + index * intervalMs
            ui.waitUntil(2_000) { android.os.SystemClock.uptimeMillis() >= target }
            val end = (content.length * index / chunks).coerceAtLeast(1)
            ui.runOnIdle { source.value = content.substring(0, end) }
            ui.waitForIdle()
            if (firstVisibleMs < 0 && MarkdownRenderMetrics.snapshot().parseCount > 0) {
                firstVisibleMs = android.os.SystemClock.uptimeMillis() - started
            }
        }

        val completionStarted = android.os.SystemClock.uptimeMillis()
        val beforeCompletion = MarkdownRenderMetrics.snapshot().parseCount
        ui.runOnIdle { streaming.value = false }
        ui.waitForIdle()
        ui.runOnIdle { frames.stop() }
        val completionMs = android.os.SystemClock.uptimeMillis() - completionStarted
        val metrics = MarkdownRenderMetrics.snapshot()
        if (paced) assertTrue("final source was not parsed", metrics.parseCount > beforeCompletion)
        return FixtureMeasurement(
            firstVisibleMs = firstVisibleMs,
            completionMs = completionMs,
            parseCount = metrics.parseCount,
            renderCount = metrics.renderCount,
            parseMs = metrics.parseNanos / 1_000_000.0,
            renderMs = metrics.renderNanos / 1_000_000.0,
            frameCount = frames.intervalsMs.size,
            frameP95Ms = frames.percentile95Ms,
            framesOver24Ms = frames.intervalsMs.count { it > 24.0 },
        )
    }

    private data class FixtureMeasurement(
        val firstVisibleMs: Long,
        val completionMs: Long,
        val parseCount: Long,
        val renderCount: Long,
        val parseMs: Double,
        val renderMs: Double,
        val frameCount: Int,
        val frameP95Ms: Double,
        val framesOver24Ms: Int,
    )

    private class FrameRecorder : Choreographer.FrameCallback {
        private val times = mutableListOf<Long>()
        private var active = false

        val intervalsMs: List<Double>
            get() = times.zipWithNext { left, right -> (right - left) / 1_000_000.0 }

        val percentile95Ms: Double
            get() {
                val sorted = intervalsMs.sorted()
                if (sorted.isEmpty()) return 0.0
                return sorted[((sorted.size - 1) * 0.95).toInt()]
            }

        fun start() {
            active = true
            Choreographer.getInstance().postFrameCallback(this)
        }

        fun stop() {
            active = false
            Choreographer.getInstance().removeFrameCallback(this)
        }

        override fun doFrame(frameTimeNanos: Long) {
            if (!active) return
            times += frameTimeNanos
            Choreographer.getInstance().postFrameCallback(this)
        }
    }

    private fun awaitClipboard(expected: String) {
        ui.waitUntil(2_000) {
            clipboard.primaryClip?.getItemAt(0)?.text?.toString() == expected
        }
    }
}
