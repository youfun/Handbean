package com.example.handbean_probe

import android.net.Uri
import android.util.Log
import androidx.camera.core.CameraSelector
import androidx.camera.core.Preview as CameraPreview
import androidx.camera.core.UseCase
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.ArrowForward
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.QuestionMark
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.StarBorder
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.LifecycleOwner
import coil.compose.AsyncImage
import java.io.File
import kotlinx.coroutines.launch

@Composable
internal fun MobText(node: MobNode, modifier: Modifier) {
    val text          = node.props["text"] as? String ?: ""
    if (HandbeanRender.renderMarkdown(node, modifier)) return
    val color         = colorProp(node.props, "text_color")
    val fontSize      = sizeProp(node.props, "text_size")
    val fontWeight    = fontWeightProp(node.props)
    val fontStyle     = if (boolProp(node.props, "italic") == true) FontStyle.Italic else FontStyle.Normal
    val textAlign     = textAlignProp(node.props)
    val letterSpacing = floatProp(node.props, "letter_spacing")
    val lineHeightMul = floatProp(node.props, "line_height")
    val fontFamily    = fontFamilyProp(node.props, LocalContext.current)
    val resolvedLineHeight = if (lineHeightMul != null && fontSize != TextUnit.Unspecified)
        (lineHeightMul * fontSize.value).sp else TextUnit.Unspecified

    // No clickable here. RenderNodeInner already installed one for on_tap (the
    // `tapHandle != null && node.type != "button"` arm), and `modifier` carries
    // it in. A second clickable appended here would be INNERMOST, so it won the
    // Main pass, consumed the down, and shadowed the outer one entirely — which
    // silently cost text nodes two things the outer arm provides:
    //
    //   * `enabled = !isDisabled`, so `<Text on_tap disabled: true>` still
    //     dispatched taps while the semantics block announced it disabled
    //   * the padded hit area and ripple, since nodeModifier's padding is
    //     applied AFTER the gesture modifier in `base` — iOS pads before
    //     .contentShape(Rectangle()).onTapGesture, so the inner clickable was
    //     also the thing making Android disagree with it
    //
    // It additionally swallowed the down before the outer combinedClickable's
    // long-press detector could see it, so on_long_press never fired on a text
    // node. That was the symptom; this redundancy was the cause.
    val tappableModifier = modifier

    // text_align is a no-op when the Text wraps to its content width — the
    // alignment only matters if the Text is wider than its content. Apply
    // fillMaxWidth in that case so center/right alignment behaves like iOS.
    val textModifier = if (textAlign != null && boolProp(node.props, "fill_width") != false &&
        floatProp(node.props, "width") == null) {
        tappableModifier.fillMaxWidth()
    } else tappableModifier

    val content: @Composable () -> Unit = { Text(
        text          = text,
        modifier      = textModifier,
        color         = color,
        fontSize      = fontSize,
        fontWeight    = fontWeight,
        fontStyle     = fontStyle,
        textAlign     = textAlign,
        lineHeight    = resolvedLineHeight,
        letterSpacing = letterSpacing?.sp ?: TextUnit.Unspecified,
        fontFamily    = fontFamily,
        maxLines      = intProp(node.props, "max_lines") ?: Int.MAX_VALUE,
        overflow      = if (node.props["ellipsize"] == "end") TextOverflow.Ellipsis else TextOverflow.Clip,
    ) }
    HandbeanRender.selectable(node, content)
}

@Composable
internal fun MobImage(node: MobNode, modifier: Modifier) {
    val src          = node.props["src"] as? String
    val contentScale = when (node.props["content_mode"] as? String) {
        "fill"    -> ContentScale.Crop
        "stretch" -> ContentScale.FillBounds
        else      -> ContentScale.Fit
    }
    val cornerRadius = floatProp(node.props, "corner_radius") ?: 0f
    val fixedWidth   = floatProp(node.props, "width")
    val fixedHeight  = floatProp(node.props, "height")

    // Coil's AsyncImage expects a URL string for remote images or a File object for
    // local paths. Passing a bare path string as a model causes it to treat it as a
    // relative URL and fail silently. Detect local paths and wrap in File.
    val model: Any? = when {
        src == null -> null
        src.startsWith("http://") || src.startsWith("https://") -> src
        else -> java.io.File(src)
    }

    var m = modifier
    if (fixedWidth  != null) m = m.width(fixedWidth.dp)
    if (fixedHeight != null) m = m.height(fixedHeight.dp)
    if (cornerRadius > 0f)   m = m.clip(RoundedCornerShape(cornerRadius.dp))

    if (HandbeanRender.renderLocalImage(node, m, contentScale)) return

    AsyncImage(
        model              = model,
        contentDescription = HandbeanRender.imageDescription(node.props),
        contentScale       = contentScale,
        modifier           = m,
    )
}

@Composable
internal fun MobIcon(node: MobNode, modifier: Modifier) {
    val name        = node.props["name"] as? String ?: "questionmark"
    val tint        = colorProp(node.props, "text_color")
    val fontSizeSp  = sizeProp(node.props, "text_size")
    val sizeDp      = if (fontSizeSp != androidx.compose.ui.unit.TextUnit.Unspecified)
        fontSizeSp.value.dp else 24.dp
    val description = node.props["text"] as? String

    // See MobText: RenderNodeInner already installed the on_tap clickable, and a
    // second one here would be innermost, shadowing it along with its `enabled`
    // handling and padded hit area, and swallowing the down that on_long_press
    // needs.
    val baseMod = modifier

    Icon(
        imageVector       = materialIconFor(name),
        contentDescription = description,
        tint              = if (tint == Color.Unspecified) Color.Unspecified else tint,
        modifier          = baseMod.size(sizeDp),
    )
}

// Logical icon name → Material icon. Names mirror MobRootView.swift's
// sfSymbolName/1 so the same `name:` prop renders an Apple-styled icon on iOS
// and a Material-styled icon on Android. Unknown names fall back to a "?".
private fun materialIconFor(logical: String): androidx.compose.ui.graphics.vector.ImageVector =
    when (logical) {
        "settings"        -> Icons.Filled.Settings
        "back"            -> Icons.Filled.ArrowBack
        "forward"         -> Icons.Filled.ArrowForward
        "close"           -> Icons.Filled.Close
        "add"             -> Icons.Filled.Add
        "remove"          -> Icons.Filled.Remove
        "edit"            -> Icons.Filled.Edit
        "check"           -> Icons.Filled.Check
        "chevron_right"   -> Icons.Filled.ChevronRight
        "chevron_left"    -> Icons.Filled.ChevronLeft
        "chevron_up"      -> Icons.Filled.KeyboardArrowUp
        "chevron_down"    -> Icons.Filled.ExpandMore
        "info"            -> Icons.Filled.Info
        "warning"         -> Icons.Filled.Warning
        "error"           -> Icons.Filled.Error
        "search"          -> Icons.Filled.Search
        "trash"           -> Icons.Filled.Delete
        "share"           -> Icons.Filled.Share
        "more"            -> Icons.Filled.MoreVert
        "menu"            -> Icons.Filled.Menu
        "refresh"         -> Icons.Filled.Refresh
        "favorite"        -> Icons.Filled.FavoriteBorder
        "favorite_filled" -> Icons.Filled.Favorite
        "star"            -> Icons.Filled.StarBorder
        "star_filled"     -> Icons.Filled.Star
        "user"            -> Icons.Filled.Person
        "home"            -> Icons.Filled.Home
        "expand_more"     -> Icons.Filled.ExpandMore
        "expand_less"     -> Icons.Filled.ExpandLess
        else              -> Icons.Filled.QuestionMark
    }

@Composable
internal fun MobCameraPreview(node: MobNode, modifier: Modifier) {
    val facingStr  = (node.props["facing"] as? String) ?: "back"
    val cameraSelector = if (facingStr == "front")
        CameraSelector.DEFAULT_FRONT_CAMERA
    else
        CameraSelector.DEFAULT_BACK_CAMERA
    val context        = LocalContext.current
    val lifecycleOwner = context as LifecycleOwner

    // PreviewView is held in remember so the LaunchedEffect can rebind to
    // the same surface provider across recompositions. COMPATIBLE mode
    // uses TextureView so the preview renders inside the normal Compose
    // Z-order — PERFORMANCE (default) uses SurfaceView which punches
    // through above Compose and hides any overlay drawn on top of the
    // camera (e.g. bounding boxes, status text). FILL_CENTER center-crops
    // the camera image to fill the view.
    val previewView = remember(context) {
        PreviewView(context).apply {
            scaleType = PreviewView.ScaleType.FILL_CENTER
            implementationMode = PreviewView.ImplementationMode.COMPATIBLE
        }
    }

    // Bind in a LaunchedEffect keyed only on cameraSelector — NOT in
    // AndroidView's update block. The update block re-runs on every
    // recomposition, so wiring the bind there caused continual
    // unbindAll/bind cycles whenever any sibling state ticked (e.g. an
    // FPS counter), making the TextureView surface flicker and fight
    // with overlays.
    LaunchedEffect(cameraSelector) {
        val providerFuture = ProcessCameraProvider.getInstance(context)
        providerFuture.addListener({
            val provider = providerFuture.get()
            MobBridge.previewCameraProvider = provider
            val preview = CameraPreview.Builder().build().also {
                it.setSurfaceProvider(previewView.surfaceProvider)
            }
            val useCases = mutableListOf<UseCase>(preview)
            try {
                provider.unbindAll()
                provider.bindToLifecycle(lifecycleOwner, cameraSelector, *useCases.toTypedArray())
            } catch (e: Exception) {
                Log.e("MobCamera", "bindToLifecycle failed: ${e.message}")
            }
        }, context.mainExecutor)
    }

    // clipToBounds keeps the TextureView's surface texture from bleeding
    // past the AndroidView's declared layout bounds; without it, sibling
    // Compose nodes adjacent to the preview can be overdrawn by the
    // camera surface.
    AndroidView(modifier = modifier.clipToBounds(), factory = { previewView })
}

private val MOB_JS_SHIM = """
(function(){
  if(window.mob)return;
  var _h=[];
  window.mob={
    send:function(d){MobNative.postMessage(JSON.stringify(d));},
    onMessage:function(h){_h.push(h);return function(){_h=_h.filter(function(x){return x!==h;});};},
    _dispatch:function(j){try{var d=JSON.parse(j);_h.forEach(function(h){h(d);});}catch(e){}}
  };
})();
""".trimIndent()

@Composable
internal fun MobWebView(node: MobNode, modifier: Modifier) {
    val url       = node.props["url"] as? String ?: return
    val allowStr  = node.props["allow"] as? String ?: ""
    val allowList = allowStr.split(",").filter { it.isNotEmpty() }
    val title     = node.props["title"] as? String

    // File-chooser plumbing for HTML <input type="file"> inside the WebView
    // (e.g. Livebook's Upload import, attachments). Without a WebChromeClient
    // that handles onShowFileChooser, tapping a file input does nothing.
    val filePathCallback =
        remember { mutableStateOf<android.webkit.ValueCallback<Array<android.net.Uri>>?>(null) }
    val fileChooserLauncher =
        androidx.activity.compose.rememberLauncherForActivityResult(
            androidx.activity.result.contract.ActivityResultContracts.StartActivityForResult()
        ) { result ->
            val uris =
                android.webkit.WebChromeClient.FileChooserParams.parseResult(
                    result.resultCode,
                    result.data,
                )
            filePathCallback.value?.onReceiveValue(uris)
            filePathCallback.value = null
        }

    Column(modifier = modifier) {
        if (title != null) {
            Text(text = title, fontSize = 12.sp,
                 modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp))
        }
        AndroidView(
            modifier = Modifier.weight(1f),
            factory  = { ctx ->
                android.webkit.WebView(ctx).apply {
                    // Fill the AndroidView's allocated bounds. Without explicit
                    // MATCH_PARENT layout params the WebView defaults to
                    // wrap_content, so a full-viewport web app (CSS 100vh/100%,
                    // e.g. an xterm.js terminal) measures its container as 0px
                    // and collapses to nothing. useWideViewPort +
                    // loadWithOverviewMode make the WebView honour the page's
                    // viewport meta so vh units resolve correctly.
                    layoutParams = android.view.ViewGroup.LayoutParams(
                        android.view.ViewGroup.LayoutParams.MATCH_PARENT,
                        android.view.ViewGroup.LayoutParams.MATCH_PARENT,
                    )
                    settings.javaScriptEnabled = true
                    settings.domStorageEnabled = true
                    settings.useWideViewPort = true
                    settings.loadWithOverviewMode = true
                    addJavascriptInterface(object : Any() {
                        @android.webkit.JavascriptInterface
                        fun postMessage(json: String) {
                            MobBridge.nativeDeliverWebViewMessage(0L, json)
                        }
                    }, "MobNative")
                    webViewClient = object : android.webkit.WebViewClient() {
                        override fun onPageFinished(view: android.webkit.WebView, pageUrl: String) {
                            view.evaluateJavascript(MOB_JS_SHIM, null)
                        }
                        override fun shouldOverrideUrlLoading(
                            view: android.webkit.WebView,
                            request: android.webkit.WebResourceRequest
                        ): Boolean {
                            if (allowList.isEmpty()) return false
                            val reqUrl = request.url.toString()
                            if (allowList.any { reqUrl.startsWith(it) }) return false
                            MobBridge.nativeDeliverWebViewBlocked(0L, reqUrl)
                            return true
                        }
                    }
                    webChromeClient = object : android.webkit.WebChromeClient() {
                        override fun onShowFileChooser(
                            webView: android.webkit.WebView?,
                            callback: android.webkit.ValueCallback<Array<android.net.Uri>>?,
                            params: android.webkit.WebChromeClient.FileChooserParams?,
                        ): Boolean {
                            // Cancel any in-flight chooser, then launch the picker the
                            // page asked for (params carries its accept/multiple flags).
                            filePathCallback.value?.onReceiveValue(null)
                            filePathCallback.value = callback
                            val intent = params?.createIntent()
                            return if (intent != null) {
                                try {
                                    fileChooserLauncher.launch(intent)
                                    true
                                } catch (e: Exception) {
                                    filePathCallback.value = null
                                    false
                                }
                            } else {
                                filePathCallback.value = null
                                false
                            }
                        }
                    }
                    MobBridge.webView = this
                    loadUrl(url)
                }
            },
            update = { wv ->
                MobBridge.webView = wv
                if (wv.url != url) wv.loadUrl(url)
            }
        )
    }
}

@Composable
internal fun MobVideoPlayer(node: MobNode, modifier: Modifier) {
    val src = node.props["src"] as? String ?: return
    val autoplay = boolProp(node.props, "autoplay") ?: false
    val context = LocalContext.current
    // ExoPlayer / Media3 video player.
    // Requires: implementation 'androidx.media3:media3-exoplayer:1.3.0'
    //           implementation 'androidx.media3:media3-ui:1.3.0'
    // Stubbed until Media3 dependency is added to build.gradle.
    // Replace this Box with the full player implementation when the dep is present:
    androidx.compose.foundation.layout.Box(
        modifier = modifier
            .background(Color.Black),
        contentAlignment = androidx.compose.ui.Alignment.Center
    ) {
        Text("Video: $src", color = Color.White, fontSize = 12.sp)
    }
}
