package com.example.handbean_probe

import android.graphics.Paint
import android.graphics.Typeface
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.filled.List
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size as ComposeSize
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.unit.dp
import org.json.JSONArray
import org.json.JSONObject

// ── Canvas (Mob.Canvas declarative draw spec) ───────────────────────────────
// Renders the node.props["draw"] list via Compose Canvas. Each op is a
// Map<String, Any?> with an "op" key plus op-specific fields, pre-resolved
// by the Elixir renderer (color tokens already converted to ARGB integers).
@Composable
internal fun MobCanvas(node: MobNode, modifier: Modifier) {
    val width = floatProp(node.props, "width") ?: 0f
    val height = floatProp(node.props, "height") ?: 0f
    @Suppress("UNCHECKED_CAST")
    val ops: List<Map<String, Any?>> = when (val raw = node.props["draw"]) {
        is JSONArray -> (0 until raw.length()).map { i -> jsonObjectToMap(raw.getJSONObject(i)) }
        is List<*>   -> raw as List<Map<String, Any?>>
        else         -> emptyList()
    }

    val sized = if (width > 0f && height > 0f) {
        modifier.size(width.dp, height.dp)
    } else {
        modifier
    }

    // on_drag is canvas-only, matching iOS, where the DragGesture lives on the
    // canvas view and nowhere else.
    //
    // One sanctioned divergence: iOS uses DragGesture(minimumDistance: 0) so a
    // stationary tap registers as a zero-length began/ended pair (a dot on a
    // drawing canvas). detectDragGestures only starts after touch slop, so a
    // bare tap emits nothing here. The iOS source already documents this as the
    // expected Android behaviour rather than a defect.
    val dragHandle = intProp(node.props, "on_drag")
    ApplyThrottleConfig(node.props, dragHandle, "drag_config")
    // Deliberately NOT keyed on the handle. on_drag emits continuously, each
    // message re-renders the screen, and every render re-registers the tap
    // table with fresh handle ints. Keying on the handle therefore cancels the
    // gesture coroutine one sample into the drag: `began` and a single
    // `dragging` arrive, then onDragEnd never runs and the drag never closes.
    // Key on nothing and read the current handle through a snapshot instead.
    val liveDragHandle by rememberUpdatedState(dragHandle)
    val dragged = if (dragHandle == null) sized else {
        sized.pointerInput(Unit) {
            var startX = 0f
            var startY = 0f
            // Last reported position, so the closing event carries where the
            // finger actually ended and the total translation — iOS's onEnded
            // reads value.location/value.translation, not the drag origin.
            var curX = 0f
            var curY = 0f
            // Compose reports pixels; the canvas draws in dp and iOS reports
            // points. Emitting raw pixels would scale every coordinate by the
            // device's density and put the drag in a different space than the
            // drawing it is meant to steer.
            fun emit(px: Float, py: Float, phase: String) {
                val h = liveDragHandle ?: return
                MobBridge.nativeSendDrag(
                    h,
                    px.toDp().value.toDouble(), py.toDp().value.toDouble(),
                    (px - startX).toDp().value.toDouble(),
                    (py - startY).toDp().value.toDouble(),
                    phase
                )
            }
            detectDragGestures(
                onDragStart = { off ->
                    startX = off.x
                    startY = off.y
                    curX = off.x
                    curY = off.y
                    emit(off.x, off.y, "began")
                },
                onDragEnd = { emit(curX, curY, "ended") },
                // A cancelled drag still has to close, or a listener that opened
                // state on "began" never gets told to release it.
                onDragCancel = { emit(curX, curY, "ended") }
            ) { change, _ ->
                curX = change.position.x
                curY = change.position.y
                emit(curX, curY, "dragging")
                change.consume()
            }
        }
    }

    Canvas(modifier = dragged) {
        ops.forEach { op -> drawCanvasOp(op) }
    }
}

private fun DrawScope.drawCanvasOp(op: Map<String, Any?>) {
    val opName = op["op"] as? String ?: return
    val color = canvasColor(op["color"])
    val opacity = (op["opacity"] as? Double)?.toFloat() ?: 1f
    val isFill = (op["fill"] as? Boolean) ?: false
    val stroke = canvasStroke(op)

    when (opName) {
        "line" -> drawLine(
            color = color,
            start = Offset(canvasFloat(op["x1"]), canvasFloat(op["y1"])),
            end = Offset(canvasFloat(op["x2"]), canvasFloat(op["y2"])),
            strokeWidth = stroke.width,
            cap = stroke.cap,
            pathEffect = stroke.pathEffect,
            alpha = opacity
        )

        "circle" -> {
            val center = Offset(canvasFloat(op["x"]), canvasFloat(op["y"]))
            val radius = canvasFloat(op["r"])
            if (isFill) {
                drawCircle(color = color, radius = radius, center = center, alpha = opacity)
            } else {
                drawCircle(color = color, radius = radius, center = center, alpha = opacity, style = stroke)
            }
        }

        "ellipse" -> {
            val cx = canvasFloat(op["x"])
            val cy = canvasFloat(op["y"])
            val rx = canvasFloat(op["rx"])
            val ry = canvasFloat(op["ry"])
            val topLeft = Offset(cx - rx, cy - ry)
            val size = ComposeSize(rx * 2, ry * 2)
            if (isFill) {
                drawOval(color = color, topLeft = topLeft, size = size, alpha = opacity)
            } else {
                drawOval(color = color, topLeft = topLeft, size = size, alpha = opacity, style = stroke)
            }
        }

        "arc" -> {
            // Mob.Canvas arc: degrees, 0° to the right, sweeping clockwise.
            // Compose drawArc takes startAngle + sweepAngle in degrees, same convention.
            val cx = canvasFloat(op["x"])
            val cy = canvasFloat(op["y"])
            val r = canvasFloat(op["r"])
            val startDeg = canvasFloat(op["start_deg"])
            val endDeg = canvasFloat(op["end_deg"])
            val sweep = endDeg - startDeg
            drawArc(
                color = color,
                startAngle = startDeg,
                sweepAngle = sweep,
                useCenter = false,
                topLeft = Offset(cx - r, cy - r),
                size = ComposeSize(r * 2, r * 2),
                alpha = opacity,
                style = stroke
            )
        }

        "rect" -> {
            val topLeft = Offset(canvasFloat(op["x"]), canvasFloat(op["y"]))
            val size = ComposeSize(canvasFloat(op["w"]), canvasFloat(op["h"]))
            val radius = canvasFloat(op["radius"])
            if (radius > 0f) {
                val cornerRadius = androidx.compose.ui.geometry.CornerRadius(radius, radius)
                if (isFill) {
                    drawRoundRect(color = color, topLeft = topLeft, size = size,
                        cornerRadius = cornerRadius, alpha = opacity)
                } else {
                    drawRoundRect(color = color, topLeft = topLeft, size = size,
                        cornerRadius = cornerRadius, alpha = opacity, style = stroke)
                }
            } else {
                if (isFill) {
                    drawRect(color = color, topLeft = topLeft, size = size, alpha = opacity)
                } else {
                    drawRect(color = color, topLeft = topLeft, size = size, alpha = opacity, style = stroke)
                }
            }
        }

        "path" -> {
            @Suppress("UNCHECKED_CAST")
            val pts = op["points"] as? List<List<Any?>> ?: return
            if (pts.isEmpty()) return
            val closed = (op["closed"] as? Boolean) ?: false
            val path = Path().apply {
                moveTo(canvasFloat(pts[0].getOrNull(0)), canvasFloat(pts[0].getOrNull(1)))
                for (i in 1 until pts.size) {
                    lineTo(canvasFloat(pts[i].getOrNull(0)), canvasFloat(pts[i].getOrNull(1)))
                }
                if (closed || isFill) close()
            }
            if (isFill) {
                drawPath(path = path, color = color, alpha = opacity)
            } else {
                drawPath(path = path, color = color, alpha = opacity, style = stroke)
            }
        }

        "text" -> {
            val str = op["text"] as? String ?: return
            val size = canvasFloat(op["size"])
            val anchor = op["anchor"] as? String ?: "start"
            val weight = op["weight"] as? String
            // Compose has no DrawScope text primitive prior to TextMeasurer; the
            // simplest cross-version path is the platform Canvas via drawIntoCanvas.
            // Anchor is handled by measuring with Paint and offsetting x.
            drawIntoCanvas { canvas ->
                val paint = Paint().apply {
                    isAntiAlias = true
                    textSize = size
                    this.color = color.toArgb()
                    alpha = (opacity * 255).toInt().coerceIn(0, 255)
                    typeface = canvasTypeface(weight)
                }
                val measured = paint.measureText(str)
                val x = canvasFloat(op["x"])
                val y = canvasFloat(op["y"])
                val drawX = when (anchor) {
                    "center" -> x - measured / 2f
                    "end"    -> x - measured
                    else     -> x
                }
                // Compose Canvas positions text by baseline; offset by font ascent
                // so y is the top edge (matches SwiftUI Canvas convention).
                val baseline = y - paint.fontMetrics.ascent
                canvas.nativeCanvas.drawText(str, drawX, baseline, paint)
            }
        }

        "image" -> {
            // Image asset rendering deferred — needs context-aware loading from the
            // app's drawable resources or asset catalog. Tracked separately.
        }
    }
}

// Canvas coordinates from BEAM are in dp (matching the canvas's declared
// width/height). Compose's DrawScope works in pixels, so convert dp→px here.
private fun DrawScope.canvasFloat(v: Any?): Float {
    val dp = when (v) {
        is Float  -> v
        is Double -> v.toFloat()
        is Int    -> v.toFloat()
        is Long   -> v.toFloat()
        else      -> 0f
    }
    return dp.dp.toPx()
}

private fun canvasColor(v: Any?): Color = when (v) {
    is Long   -> Color(v.toInt())
    is Int    -> Color(v)
    is Double -> Color(v.toLong().toInt())
    is String -> {
        // Hex string fallback ("#rrggbb"). Pre-resolved ARGB integers are the
        // hot path; this is for raw color strings that bypass theme resolution.
        if (v.startsWith("#") && v.length == 7) {
            val rgb = v.substring(1).toLong(16)
            val r = ((rgb shr 16) and 0xFF).toInt()
            val g = ((rgb shr 8) and 0xFF).toInt()
            val b = (rgb and 0xFF).toInt()
            Color(red = r, green = g, blue = b)
        } else Color.Black
    }
    else      -> Color.Black
}

private fun DrawScope.canvasStroke(op: Map<String, Any?>): Stroke {
    val width = canvasFloat(op["width"]).let { if (it > 0f) it else 1f }
    val cap = when (op["cap"] as? String) {
        "round"  -> StrokeCap.Round
        "square" -> StrokeCap.Square
        else     -> StrokeCap.Butt
    }
    val join = when (op["join"] as? String) {
        "round" -> StrokeJoin.Round
        "bevel" -> StrokeJoin.Bevel
        else    -> StrokeJoin.Miter
    }
    @Suppress("UNCHECKED_CAST")
    val dashList = (op["dash"] as? List<Any?>)?.map { canvasFloat(it) }?.toFloatArray()
    val pathEffect = if (dashList != null && dashList.isNotEmpty()) {
        PathEffect.dashPathEffect(dashList, 0f)
    } else null
    return Stroke(width = width, cap = cap, join = join, pathEffect = pathEffect)
}

private fun canvasTypeface(weight: String?): Typeface = when (weight) {
    "bold", "semibold", "medium" -> Typeface.DEFAULT_BOLD
    else -> Typeface.DEFAULT
}

// Recursively convert org.json.JSONObject/JSONArray trees to plain Kotlin
// Map<String, Any?> / List<Any?> so they're usable by code that expects
// Kotlin collections (e.g. MobCanvas's "draw" op list).
private fun jsonObjectToMap(obj: JSONObject): Map<String, Any?> {
    val result = mutableMapOf<String, Any?>()
    for (key in obj.keys()) {
        result[key] = jsonValueToKotlin(obj.get(key))
    }
    return result
}

private fun jsonValueToKotlin(v: Any?): Any? = when (v) {
    is JSONObject -> jsonObjectToMap(v)
    is JSONArray  -> (0 until v.length()).map { i -> jsonValueToKotlin(v.get(i)) }
    JSONObject.NULL -> null
    else -> v
}
