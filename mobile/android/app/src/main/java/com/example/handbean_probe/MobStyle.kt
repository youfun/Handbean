package com.example.handbean_probe

import android.content.Context
import android.graphics.Typeface
import android.util.Log
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.key
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

// ── Modifier helpers ──────────────────────────────────────────────────────────

internal fun nodeModifier(props: Map<String, Any?>): Modifier {
    var m: Modifier = Modifier
    floatProp(props, "max_height")?.let { m = m.heightIn(max = it.dp) }
    val cornerRadius = floatProp(props, "corner_radius") ?: 0f
    val shape = if (cornerRadius > 0f) RoundedCornerShape(cornerRadius.dp) else null

    // Background must come before padding so it fills the full area (including
    // padding space). If background were applied after padding, it would only
    // draw behind the inner content area — making empty boxes invisible.
    // When a corner radius is present, clip the background to that shape so
    // rectangular bleed doesn't show through the rounded corners.
    longColorProp(props, "background")?.let { bg ->
        m = if (shape != null) m.background(bg, shape) else m.background(bg)
    }

    // Border (opt-in: requires both border_color and border_width). Drawn on
    // the same shape as the background so rounded boxes get a proper outline.
    val borderColor = longColorProp(props, "border_color")
    val borderWidth = floatProp(props, "border_width") ?: 0f
    if (borderColor != null && borderWidth > 0f) {
        m = if (shape != null) m.border(borderWidth.dp, borderColor, shape)
            else m.border(borderWidth.dp, borderColor)
    }

    // Clip the padded bounds, not the inner content: clipping after padding
    // cuts glyphs at the first and last lines of rounded message bubbles.
    if (shape != null) m = m.clip(shape)

    val uniform = intProp(props, "padding")
    val top     = intProp(props, "padding_top")
    val right   = intProp(props, "padding_right")
    val bottom  = intProp(props, "padding_bottom")
    val left    = intProp(props, "padding_left")
    val hasEdge = top != null || right != null || bottom != null || left != null
    m = when {
        hasEdge  -> m.padding(
            top    = (top    ?: uniform ?: 0).dp,
            end    = (right  ?: uniform ?: 0).dp,
            bottom = (bottom ?: uniform ?: 0).dp,
            start  = (left   ?: uniform ?: 0).dp,
        )
        uniform != null -> m.padding(uniform.dp)
        else            -> m
    }

    if (boolProp(props, "fill_width") == true) m = m.fillMaxWidth()
    // fill_height: true stretches the node to the parent's vertical bounds.
    // Used by full-screen overlay boxes whose center alignment needs the
    // viewport as its reference frame, not the contained children's height.
    if (boolProp(props, "fill_height") == true) m = m.fillMaxHeight()

    // Explicit width / height — when set, the node uses that exact size
    // instead of stretching to fill its parent. Used by SquareTriangle's
    // ring cells (110x110 boxes acting as rings via corner_radius +
    // border).
    floatProp(props, "width")?.let  { w -> m = m.width(w.dp) }
    floatProp(props, "height")?.let { h -> m = m.height(h.dp) }

    // aspect_ratio: lock a node to width:height = ratio. Common use is
    // <Box fill_width={true} aspect_ratio={1.0}> to make a square area
    // (e.g. camera preview + overlay canvas that need to match the
    // model's center-cropped square frame so coords align).
    floatProp(props, "aspect_ratio")?.let { r -> if (r > 0f) m = m.aspectRatio(r) }

    // Per-node offset is NOT applied here. Compose's Modifier.offset on the
    // node's own modifier chain didn't displace siblings reliably when stacking
    // multiple offset boxes inside a parent Box. RenderNode wraps the whole
    // node in an outer Box(Modifier.offset(...)) instead — see RenderNode.
    return m
}

// ── Typography helpers ────────────────────────────────────────────────────────

internal fun fontWeightProp(props: Map<String, Any?>): FontWeight? =
    when (props["font_weight"] as? String) {
        "bold"     -> FontWeight.Bold
        "semibold" -> FontWeight.SemiBold
        "medium"   -> FontWeight.Medium
        "light"    -> FontWeight.Light
        "thin"     -> FontWeight.Thin
        else       -> null
    }

internal fun textAlignProp(props: Map<String, Any?>): TextAlign? =
    when (props["text_align"] as? String) {
        "center" -> TextAlign.Center
        "right"  -> TextAlign.End
        else     -> null
    }

// Tries `name` as a bundled custom font (res/font/, build-copied from
// priv/fonts/ + plugin assets.fonts) then as a system family name
// (sans-serif, monospace, …). Returns null if neither resolves — the
// caller (fontFamilyProp) walks the fallback chain, this is just the
// single-name resolution step.
internal fun resolveOneFontName(name: String, context: android.content.Context?): FontFamily? {
    if (context != null) {
        var resName = name.lowercase().replace(Regex("[^a-z0-9_]"), "_")
        if (!resName.matches(Regex("^[a-z].*"))) resName = "f_$resName"
        val resId = context.resources.getIdentifier(resName, "font", context.packageName)
        if (resId != 0) {
            try {
                val tf = androidx.core.content.res.ResourcesCompat.getFont(context, resId)
                if (tf != null) return FontFamily(tf)
            } catch (e: Exception) {
                android.util.Log.w("MobBridge", "font resource \"$resName\" failed to load: ${e.message}")
            }
        }
    }
    // Typeface.create(String, Int) never returns null and rarely throws for an
    // unrecognized family name — per its own docs, it silently substitutes
    // Typeface.DEFAULT. Reference-equality against that singleton is the
    // standard (if slightly unfortunate) way to detect "this name didn't
    // resolve to anything real" — without it, every candidate after the
    // first "succeeds" trivially and the fallback chain never gets walked.
    return try {
        val tf = Typeface.create(name, Typeface.NORMAL)
        if (tf == Typeface.DEFAULT) {
            android.util.Log.w("MobBridge", "font \"$name\" not found (Typeface substituted the default)")
            null
        } else {
            FontFamily(tf)
        }
    } catch (e: Exception) {
        android.util.Log.w("MobBridge", "font \"$name\" not found: ${e.message}")
        null
    }
}

// Walks [the node's own font, ...MobBridge.fontFallback] (the ordered list
// from the last Mob.Theme.set/1 — see MOB_FONTS.md), returning the first
// name that actually resolves. Logs when the primary choice misses so a
// missing/misnamed font is diagnosable instead of silently looking like the
// wrong font. Returns null (system default) if nothing in the chain resolves
// — same as today's no-font-set behavior.
internal fun fontFamilyProp(props: Map<String, Any?>, context: android.content.Context?): FontFamily? {
    val primary = props["font"] as? String ?: return null
    val candidates = (listOf(primary) + MobBridge.fontFallback).filter { it.isNotEmpty() }

    candidates.forEachIndexed { index, name ->
        resolveOneFontName(name, context)?.let { family ->
            if (index > 0) {
                android.util.Log.w("MobBridge", "font \"$primary\" not found — fell back to \"$name\"")
            }
            return family
        }
    }

    android.util.Log.w("MobBridge", "none of $candidates resolved — using system font")
    return null
}

// ── Prop extraction ───────────────────────────────────────────────────────────

// Vertical alignment for Row from the `align:` prop — :top / :center / :bottom
// (atom from Elixir arrives as a String). Defaults to CenterVertically because
// that matches the most common visual expectation (e.g. icon next to title);
// opt back into Top with align: :top.
internal fun rowAlignProp(props: Map<String, Any?>): Alignment.Vertical =
    when (props["align"] as? String) {
        "top"    -> Alignment.Top
        "bottom" -> Alignment.Bottom
        else     -> Alignment.CenterVertically
    }

// 2D alignment for Box content — same string keys as iOS so the
// renderer doesn't have to discriminate per platform.
internal fun boxAlignProp(props: Map<String, Any?>): Alignment =
    when (props["align"] as? String) {
        "center"          -> Alignment.Center
        "top"             -> Alignment.TopCenter
        "top_center"      -> Alignment.TopCenter
        "top_trailing"    -> Alignment.TopEnd
        "leading"         -> Alignment.CenterStart
        "trailing"        -> Alignment.CenterEnd
        "bottom"          -> Alignment.BottomCenter
        "bottom_leading"  -> Alignment.BottomStart
        "bottom_center"   -> Alignment.BottomCenter
        "bottom_trailing" -> Alignment.BottomEnd
        else              -> Alignment.TopStart
    }

internal fun colorProp(props: Map<String, Any?>, key: String): Color =
    longColorProp(props, key) ?: Color.Unspecified

internal fun longColorProp(props: Map<String, Any?>, key: String): Color? =
    when (val v = props[key]) {
        is Long   -> Color(v.toInt())
        is Int    -> Color(v)
        is Double -> Color(v.toLong().toInt())
        else      -> null
    }

internal fun sizeProp(props: Map<String, Any?>, key: String): TextUnit =
    when (val v = props[key]) {
        is Double -> v.toFloat().sp
        is Float  -> v.sp
        is Int    -> v.sp
        is Long   -> v.toFloat().sp
        else      -> TextUnit.Unspecified
    }

internal fun intProp(props: Map<String, Any?>, key: String): Int? =
    when (val v = props[key]) {
        is Int    -> v
        is Long   -> v.toInt()
        is Double -> v.toInt()
        else      -> null
    }

internal fun floatProp(props: Map<String, Any?>, key: String): Float? =
    when (val v = props[key]) {
        is Double -> v.toFloat()
        is Float  -> v
        is Int    -> v.toFloat()
        is Long   -> v.toFloat()
        else      -> null
    }

internal fun boolProp(props: Map<String, Any?>, key: String): Boolean? =
    when (val v = props[key]) {
        is Boolean -> v
        is String  -> v == "true"
        else       -> null
    }
