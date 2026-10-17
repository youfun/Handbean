package com.example.handbean_probe.workspace

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.handbean_probe.MobNode
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

private val Ink = Color(0xFF1A1815)
private val Paper = Color(0xFFFAF9F7)
private val Muted = Color(0xFF6F6963)

const val FILE_VIEWER_TAG = "native-file-viewer"
const val FILE_VIEWER_TEXT_TAG = "native-file-viewer-text"
const val FILE_VIEWER_IMAGE_TAG = "native-file-viewer-image"
const val FILE_VIEWER_WRAP_TAG = "native-file-viewer-wrap"
const val FILE_VIEWER_FIT_TAG = "native-file-viewer-fit"
const val FILE_VIEWER_STATUS_TAG = "native-file-viewer-status"

fun identityOf(node: MobNode): FileIdentity? {
    if (node.type != "file_viewer") return null
    val workspaceId = node.props["workspace_id"]?.toString()?.ifBlank { null } ?: return null
    val workspaceRoot = node.props["workspace_root"]?.toString()?.ifBlank { null } ?: return null
    val relativePath = node.props["relative_path"]?.toString()?.ifBlank { null } ?: return null
    val requestId = node.props["request_id"]?.toString()?.ifBlank { null } ?: return null
    val generation = when (val value = node.props["generation"]) {
        is Number -> value.toLong()
        is String -> value.toLongOrNull()
        else -> null
    } ?: return null
    val displayName = node.props["display_name"]?.toString()
        ?: relativePath.substringAfterLast('/')
    val kind = node.props["kind"]?.toString()?.ifBlank { null } ?: return null
    val mime = node.props["mime"]?.toString() ?: ""
    return FileIdentity(
        workspaceId = workspaceId,
        workspaceRoot = workspaceRoot,
        relativePath = relativePath,
        requestId = requestId,
        generation = generation,
        displayName = displayName,
        kind = kind,
        mime = mime,
    )
}

@Composable
fun NativeFileViewer(
    identity: FileIdentity,
    modifier: Modifier = Modifier,
    textReader: (FileIdentity) -> WorkspaceOpen.TextResult = { WorkspaceOpen.readText(it) },
    imageDecoder: (FileIdentity) -> Bitmap? = { WorkspaceOpen.decodeImage(it) },
) {
    var status by remember(identity.token()) { mutableStateOf("loading") }
    var text by remember(identity.token()) { mutableStateOf("") }
    var truncated by remember(identity.token()) { mutableStateOf(false) }
    var wrap by remember(identity.token()) { mutableStateOf(true) }
    var bitmap by remember { mutableStateOf<Bitmap?>(null) }
    val session = remember {
        ImageLoadSession<Bitmap>(recycle = { if (!it.isRecycled) it.recycle() })
    }

    DisposableEffect(Unit) {
        onDispose {
            session.invalidate()
            // RenderThread may still reference a displayed bitmap. Drop our
            // reference and let the runtime reclaim it instead of recycling it
            // while a previously recorded frame can still draw it.
            bitmap = null
        }
    }

    LaunchedEffect(identity.token()) {
        status = "loading"
        bitmap = null
        try {
            when (identity.kind) {
                "text" -> {
                    val result = withContext(Dispatchers.IO) { textReader(identity) }
                    ensureActive()
                    when {
                        result.error != null -> status = "error"
                        result.binary -> status = "binary"
                        result.invalidUtf8 -> status = "invalid_utf8"
                        else -> {
                            text = result.text
                            truncated = result.truncated
                            status = "text"
                        }
                    }
                }
                "image" -> {
                    val token = session.nextToken()
                    var decoded: Bitmap? = null
                    var transferred = false
                    try {
                        // Keep ownership outside withContext: cancellation at
                        // its return boundary otherwise discards an allocated
                        // bitmap before the caller can release it.
                        withContext(Dispatchers.IO) { decoded = imageDecoder(identity) }
                        ensureActive()
                        val accepted = session.accept(token, decoded)
                        transferred = true
                        bitmap = accepted
                        status = if (accepted == null) "error" else "image"
                    } finally {
                        if (!transferred) decoded?.takeIf { !it.isRecycled }?.recycle()
                    }
                }
                else -> status = "external"
            }
        } catch (cancel: CancellationException) {
            throw cancel
        } catch (_: Exception) {
            status = "error"
        }
    }

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(Paper)
            .testTag(FILE_VIEWER_TAG),
    ) {
        Text(
            text = identity.displayName,
            color = Ink,
            fontSize = 16.sp,
            modifier = Modifier.padding(12.dp),
        )
        Text(
            text = status,
            color = Muted,
            modifier = Modifier.testTag(FILE_VIEWER_STATUS_TAG),
        )
        when (status) {
            "loading" -> Text("正在打开…", color = Muted, modifier = Modifier.padding(12.dp))
            "binary" -> Text("这是二进制文件，无法作为文本显示。", color = Muted, modifier = Modifier.padding(12.dp))
            "invalid_utf8" -> Text("不是有效的 UTF-8 文本。", color = Muted, modifier = Modifier.padding(12.dp))
            "external" -> Text("此格式在系统应用中打开。", color = Muted, modifier = Modifier.padding(12.dp))
            "error" -> Text("无法显示这个文件。", color = Muted, modifier = Modifier.padding(12.dp))
            "text" -> {
                Row(Modifier.padding(horizontal = 12.dp)) {
                    Text(
                        text = if (wrap) "换行" else "不换行",
                        color = Ink,
                        modifier = Modifier
                            .testTag(FILE_VIEWER_WRAP_TAG)
                            .clickable { wrap = !wrap }
                            .padding(8.dp),
                    )
                }
                if (truncated) {
                    Text("已截断到 1 MiB。", color = Muted, modifier = Modifier.padding(horizontal = 12.dp))
                }
                val textModifier = Modifier
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .then(if (wrap) Modifier else Modifier.horizontalScroll(rememberScrollState()))
                    .padding(12.dp)
                    .testTag(FILE_VIEWER_TEXT_TAG)
                SelectionContainer {
                    Text(
                        text = text,
                        color = Ink,
                        fontSize = 14.sp,
                        fontFamily = FontFamily.Monospace,
                        softWrap = wrap,
                        modifier = textModifier,
                    )
                }
            }
            "image" -> {
                val shown = bitmap
                if (shown != null) {
                    ZoomableImage(shown)
                }
            }
        }
    }
}

@Composable
fun NativeFileViewer(node: MobNode, modifier: Modifier = Modifier) {
    val identity = identityOf(node) ?: return
    NativeFileViewer(identity, modifier)
}

@Composable
private fun ZoomableImage(bitmap: Bitmap) {
    var scale by remember(bitmap) { mutableFloatStateOf(1f) }
    var offset by remember(bitmap) { mutableStateOf(Offset.Zero) }
    Column(Modifier.fillMaxSize()) {
        Text(
            text = "适屏",
            color = Ink,
            modifier = Modifier
                .testTag(FILE_VIEWER_FIT_TAG)
                .clickable {
                    scale = 1f
                    offset = Offset.Zero
                }
                .padding(12.dp),
        )
        Box(
            modifier = Modifier
                .fillMaxSize()
                .testTag(FILE_VIEWER_IMAGE_TAG)
                .pointerInput(bitmap) {
                    detectTransformGestures { _, pan, zoom, _ ->
                        scale = (scale * zoom).coerceIn(1f, 8f)
                        offset = if (scale == 1f) Offset.Zero else offset + pan
                    }
                },
            contentAlignment = Alignment.Center,
        ) {
            Image(
                bitmap = bitmap.asImageBitmap(),
                contentDescription = null,
                contentScale = ContentScale.Fit,
                modifier = Modifier
                    .fillMaxSize()
                    .graphicsLayer {
                        scaleX = scale
                        scaleY = scale
                        translationX = offset.x
                        translationY = offset.y
                    },
            )
        }
    }
}
