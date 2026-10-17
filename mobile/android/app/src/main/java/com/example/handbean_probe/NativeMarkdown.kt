package com.example.handbean_probe

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.SystemClock
import android.text.SpannedString
import android.text.method.ArrowKeyMovementMethod
import android.view.ActionMode
import android.view.Menu
import android.view.MenuItem
import android.view.ViewGroup
import android.widget.TextView
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import io.noties.markwon.AbstractMarkwonPlugin
import io.noties.markwon.LinkResolver
import io.noties.markwon.Markwon
import io.noties.markwon.MarkwonConfiguration
import io.noties.markwon.ext.strikethrough.StrikethroughPlugin
import io.noties.markwon.ext.tables.TablePlugin
import io.noties.markwon.ext.tables.TableAwareMovementMethod
import io.noties.markwon.movement.MovementMethodPlugin
import kotlinx.coroutines.delay
import org.commonmark.node.FencedCodeBlock
import org.commonmark.node.IndentedCodeBlock
import org.commonmark.node.Node
import java.util.concurrent.atomic.AtomicLong

private val Ink = Color(0xFF1A1815)
private val Paper = Color(0xFFFAF9F7)
private val Muted = Color(0xFF6F6963)

internal fun markdownCodeCopyTag(index: Int) = "markdown-code-copy-$index"

private const val COPY_WHOLE_REPLY_ID = 0x53494749

private data class MarkdownPart(val key: String, val node: Node)

internal data class MarkdownRenderMetricsSnapshot(
    val parseCount: Long,
    val renderCount: Long,
    val parseNanos: Long,
    val renderNanos: Long,
)

internal object MarkdownRenderMetrics {
    private val parseCount = AtomicLong()
    private val renderCount = AtomicLong()
    private val parseNanos = AtomicLong()
    private val renderNanos = AtomicLong()

    fun recordParse(nanos: Long) {
        parseCount.incrementAndGet()
        parseNanos.addAndGet(nanos)
    }

    fun recordRender(nanos: Long) {
        renderCount.incrementAndGet()
        renderNanos.addAndGet(nanos)
    }

    fun snapshot() = MarkdownRenderMetricsSnapshot(
        parseCount.get(), renderCount.get(), parseNanos.get(), renderNanos.get(),
    )

    fun reset() {
        parseCount.set(0)
        renderCount.set(0)
        parseNanos.set(0)
        renderNanos.set(0)
    }
}

/** Native, selectable markdown. Images are deliberately not configured or fetched. */
@Composable
fun NativeMarkdown(
    source: String,
    modifier: Modifier = Modifier,
    messageId: String = "markdown",
    streaming: Boolean = false,
) {
    val context = LocalContext.current
    val markwon = remember(context) {
        Markwon.builder(context)
            .usePlugin(TablePlugin.create(context))
            .usePlugin(StrikethroughPlugin.create())
            .usePlugin(MovementMethodPlugin.create(
                TableAwareMovementMethod.wrap(ArrowKeyMovementMethod.getInstance())
            ))
            .usePlugin(object : AbstractMarkwonPlugin() {
                override fun configureConfiguration(builder: MarkwonConfiguration.Builder) {
                    builder.linkResolver(LinkResolver { view, link ->
                        val uri = Uri.parse(link)
                        if (uri.scheme.equals("http", true) || uri.scheme.equals("https", true)) {
                            try {
                                view.context.startActivity(Intent(Intent.ACTION_VIEW, uri))
                            } catch (_: ActivityNotFoundException) {
                                // A link remains readable when no browser is installed.
                            }
                        }
                    })
                }
            })
            .build()
    }
    val controller = remember(messageId) { MarkdownStreamController() }
    var visibleSource by remember(controller) { mutableStateOf(if (streaming) "" else source) }

    SideEffect {
        val next = controller.update(source, streaming, SystemClock.uptimeMillis())
        if (visibleSource != next) visibleSource = next
    }
    LaunchedEffect(controller) {
        while (true) {
            // This loop is intentionally independent of source updates. A
            // debounce restarted by every delta can starve forever.
            delay(34)
            val next = controller.tick(SystemClock.uptimeMillis())
            if (visibleSource != next) visibleSource = next
        }
    }

    val renderedSource = if (streaming) visibleSource else source
    val parts = remember(renderedSource, markwon) {
        val started = System.nanoTime()
        val document = markwon.parse(renderedSource)
        MarkdownRenderMetrics.recordParse(System.nanoTime() - started)
        generateSequence(document.firstChild) { it.next }
            .mapIndexed { index, node -> MarkdownPart("$index:${node.javaClass.name}", node) }
            .toList()
    }

    Column(
        modifier = modifier.fillMaxWidth().background(Paper),
        verticalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        parts.forEachIndexed { index, part ->
            androidx.compose.runtime.key(part.key) {
                when (val node = part.node) {
                    is FencedCodeBlock -> CodeCard(node.literal, node.info, index)
                    is IndentedCodeBlock -> CodeCard(node.literal, null, index)
                    else -> MarkdownText(markwon, node, source)
                }
            }
        }
    }
}

@Composable
private fun MarkdownText(markwon: Markwon, node: Node, rawSource: String) {
    val rendered = remember(markwon, node) {
        val started = System.nanoTime()
        val block = markwon.render(node)
        // Each block has its own view and Compose spacing. Keep inline spans
        // and internal newlines, but not the document's block separators.
        val end = block.indexOfLast { it != '\n' } + 1
        val value = SpannedString(block.subSequence(0, end))
        MarkdownRenderMetrics.recordRender(System.nanoTime() - started)
        value
    }
    AndroidView(
        modifier = Modifier.fillMaxWidth(),
        factory = { context ->
            TextView(context).apply {
                setTextColor(android.graphics.Color.rgb(26, 24, 21))
                textSize = 14f
                setTextIsSelectable(true)
                layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
                customSelectionActionModeCallback = WholeReplyActionModeCallback(context, rawSource)
                markwon.setParsedMarkdown(this, rendered)
                tag = rendered
            }
        },
        update = { view ->
            view.customSelectionActionModeCallback = WholeReplyActionModeCallback(view.context, rawSource)
            if (view.tag !== rendered) {
                markwon.setParsedMarkdown(view, rendered)
                view.tag = rendered
            }
        }
    )
}

private class WholeReplyActionModeCallback(
    context: Context,
    private val rawSource: String,
) : ActionMode.Callback {
    private val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager

    override fun onCreateActionMode(mode: ActionMode, menu: Menu): Boolean {
        menu.add(Menu.NONE, COPY_WHOLE_REPLY_ID, Menu.NONE, "复制全文")
            .setShowAsAction(MenuItem.SHOW_AS_ACTION_IF_ROOM)
        return true
    }

    override fun onPrepareActionMode(mode: ActionMode, menu: Menu) = false

    override fun onActionItemClicked(mode: ActionMode, item: MenuItem): Boolean {
        if (item.itemId != COPY_WHOLE_REPLY_ID) return false
        clipboard.setPrimaryClip(ClipData.newPlainText("Markdown reply", rawSource))
        mode.finish()
        return true
    }

    override fun onDestroyActionMode(mode: ActionMode) = Unit
}

@Composable
private fun CodeCard(literal: String, info: String?, index: Int) {
    // Fence literals keep a trailing newline; that would paint a blank line
    // under one-liners. Copy still uses the raw literal.
    val display = literal.trimEnd('\n')
    val shape = RoundedCornerShape(8.dp)
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(Color(0xFFF0EEEA), shape)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(start = 10.dp, top = 8.dp, bottom = 8.dp, end = 36.dp)
        ) {
            if (!info.isNullOrBlank()) {
                Text(
                    info,
                    color = Muted,
                    fontSize = 11.sp,
                    lineHeight = 14.sp,
                    modifier = Modifier.padding(bottom = 4.dp),
                )
            }
            SelectionContainer {
                Text(
                    text = display,
                    modifier = Modifier.horizontalScroll(rememberScrollState()),
                    color = Ink,
                    fontSize = 14.sp,
                    lineHeight = 20.sp,
                    fontFamily = FontFamily.Monospace,
                )
            }
        }
        CopyButton(
            literal,
            "复制代码",
            markdownCodeCopyTag(index),
            modifier = Modifier.align(Alignment.TopEnd),
        )
    }
}

@Composable
private fun CopyButton(text: String, label: String, tag: String, modifier: Modifier = Modifier) {
    val clipboard = LocalClipboardManager.current
    var copied by remember(text) { mutableStateOf(false) }
    val description = if (copied) "已复制" else label
    LaunchedEffect(copied) {
        if (copied) { delay(2000); copied = false }
    }
    // IconButton's 48dp min height was stretching one-line fences. Keep a
    // compact chrome; the tag/description stay on this node for tests.
    Box(
        modifier = modifier
            .testTag(tag)
            .size(32.dp)
            .semantics { contentDescription = description }
            .clickable {
                clipboard.setText(AnnotatedString(text))
                copied = true
            },
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            imageVector = if (copied) Icons.Default.Check else Icons.Default.ContentCopy,
            contentDescription = null,
            modifier = Modifier.size(16.dp),
            tint = Muted,
        )
    }
}
