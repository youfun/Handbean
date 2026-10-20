package com.example.handbean_probe

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.filled.List
import androidx.compose.material3.Button
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.role
import androidx.compose.ui.unit.dp
import kotlin.math.abs
import org.json.JSONArray
import org.json.JSONObject

internal data class MobNodeIdentityKey(val canonical: String)

internal object MobNodeIdentity {
    fun keyFor(node: MobNode): MobNodeIdentityKey? {
        if (!node.props.containsKey("id")) return null
        return MobNodeIdentityKey(canonicalJsonValue(node.props["id"]))
    }

    private fun canonicalJsonValue(value: Any?): String = when (value) {
        null, JSONObject.NULL -> "z"
        is String -> framed("s", listOf(value))
        is Boolean -> if (value) "b1" else "b0"
        is Number -> framed("n", listOf(value.toString()))
        is JSONArray -> framed(
            "a",
            (0 until value.length()).map { index -> canonicalJsonValue(value.get(index)) }
        )
        is JSONObject -> {
            val keys = value.keys().asSequence().toList().sorted()
            framed(
                "o",
                keys.map { key ->
                    framed(
                        "e",
                        listOf(canonicalJsonValue(key), canonicalJsonValue(value.get(key)))
                    )
                }
            )
        }
        is Map<*, *> -> {
            val entries = value.entries
                .map { entry ->
                    framed(
                        "e",
                        listOf(canonicalJsonValue(entry.key), canonicalJsonValue(entry.value))
                    )
                }
                .sorted()
            framed("o", entries)
        }
        is Iterable<*> -> framed("a", value.map(::canonicalJsonValue))
        is Array<*> -> framed("a", value.map(::canonicalJsonValue))
        else -> error("Unsupported node id value: ${value::class.java.name}")
    }

    private fun framed(type: String, values: List<String>): String = buildString {
        append(type)
        values.forEach { value ->
            append(value.length)
            append(':')
            append(value)
        }
    }
}

internal data class MobEventSlotIdentityKey(val slot: Int)

internal object MobLazyListStateIdentity {
    fun keyFor(node: MobNode, handle: Int?): Any? =
        MobNodeIdentity.keyFor(node) ?:
            if (handle != null && handle >= 0) MobEventSlotIdentityKey(handle and 0xff) else null
}

// ── Composables ───────────────────────────────────────────────────────────────

// ── Native view component registry ───────────────────────────────────────────
// Register platform-native Composables by name at app startup. The name is the
// Elixir module with "Elixir." stripped and "." replaced with "_":
//   MyApp.ChartComponent → "MyApp_ChartComponent"
//
//   MobNativeViewRegistry.register("MyApp_ChartComponent") { props, send ->
//       ChartView(data = props["data"]) { index ->
//           send("tapped", mapOf("index" to index))
//       }
//   }

typealias MobNativeSend = (event: String, payload: Map<String, Any>) -> Unit
typealias MobNativeViewFactory = @Composable (props: Map<String, Any?>, send: MobNativeSend) -> Unit

object MobNativeViewRegistry {
    private val factories = mutableMapOf<String, MobNativeViewFactory>()

    fun register(name: String, factory: MobNativeViewFactory) {
        factories[name] = factory
    }

    @Composable
    fun render(node: MobNode) {
        val name = node.props["module"] as? String ?: return
        val factory = factories[name] ?: return
        val handle = (node.props["component_handle"] as? Number)?.toInt() ?: return
        // -1 means the BEAM couldn't get a native component slot (pool
        // exhausted — MOB-100). Render nothing rather than a view whose
        // events would go nowhere; matches iOS's MobNativeViewRegistry
        // early-return for the same case.
        if (handle < 0) return
        val send: MobNativeSend = { event, payload ->
            try {
                val json = org.json.JSONObject(payload).toString()
                MobBridge.nativeDeliverComponentEvent(handle, event, json)
            } catch (_: Exception) {}
        }
        factory(node.props, send)
    }
}

/** Renders a MobNode tree produced by Mob.Renderer. */
@Composable
internal fun MobRenderNode(node: MobNode, modifier: Modifier = Modifier) {
    val ox = floatProp(node.props, "offset_x") ?: 0f
    val oy = floatProp(node.props, "offset_y") ?: 0f
    if (ox != 0f || oy != 0f) {
        Box(modifier = Modifier.offset(x = ox.dp, y = oy.dp)) {
            RenderNodeInner(node, modifier)
        }
    } else {
        RenderNodeInner(node, modifier)
    }
}

/**
 * Forwards a sibling `*_config` prop to the native per-handle throttle (MOB-134).
 *
 * `Mob.Renderer` emits `scroll_config` / `drag_config` next to the handler it
 * configures, built by `Mob.Event.Throttle`. Nothing on Android read them, so
 * an app asking for `throttle: 100, delta: 8` silently ran at the compiled-in
 * default — the same "declared and silently ignored" shape as MOB-138.
 *
 * Applied from a SideEffect, i.e. after every successful composition, which is
 * the cadence this needs: `clear_taps` zeroes the per-handle throttle state on
 * every render, and each render re-registers the handler under a new handle, so
 * the config has to be re-sent for the new handle each frame.
 *
 * Resolving against the ACTIVE table is correct here, unlike iOS. Android's
 * table swap happens inside `nif_set_root` before this composition runs, so by
 * the time Kotlin calls, the handles in this tree are already the active ones.
 * iOS applies config from inside the deserialiser, before its own swap, which
 * is why it needs a build-table lookup instead.
 */
@Composable
internal fun ApplyThrottleConfig(props: Map<String, Any?>, handle: Int?, configKey: String) {
    if (handle == null) return
    // Nested props stay org.json objects — see MobJson's compatibility contract.
    val cfg = props[configKey] as? JSONObject ?: return

    SideEffect {
        // Read straight off the JSONObject. jsonObjectToMap would allocate a
        // LinkedHashMap plus five boxed values on the UI thread on every
        // composition — i.e. every frame of an active scroll — and routing
        // delta_threshold through Float on the way would turn 0.1 into
        // 0.10000000149011612 for no reason.
        MobBridge.nativeSetThrottleConfig(
            handle,
            cfg.optInt("throttle_ms", 0),
            cfg.optInt("debounce_ms", 0),
            cfg.optDouble("delta_threshold", 0.0),
            // Absent means enabled: Mob.Event.Throttle defaults both to true.
            // Neither field has a native reader yet — mob_set_throttle_config
            // stores them and nothing consults them — so this mapping is for
            // whoever implements leading/trailing, not something in force today.
            if (cfg.optBoolean("leading", true)) 1 else 0,
            if (cfg.optBoolean("trailing", true)) 1 else 0,
        )
    }
}

/** Long-press / double-tap handles for one node, re-read each composition. */
private data class MobPressHandles(val long: Int?, val double: Int?)

/** Swipe handles for one node, re-read each composition. See MobScrollHandlers. */
private data class MobSwipeHandlers(
    val any: Int?,
    val left: Int?,
    val right: Int?,
    val up: Int?,
    val down: Int?,
)

/**
 * Stable identities for a child list (MOB-127).
 *
 * Positional identity — a bare `forEach`, or `items()` without a `key` — means
 * an insert or delete makes every later child a different node as far as
 * Compose is concerned, so it is recomposed and its `remember`ed state
 * discarded rather than moved. On a LazyColumn it also loses scroll position
 * anchoring across an insert.
 *
 * Author `:id` when the node has one, position otherwise. The two are prefixed
 * differently so an author id of "3" cannot collide with position 3, and a
 * repeated id gets its position folded in — Compose requires keys to be unique
 * within a list and throws on a duplicate, which would be a worse bug than the
 * one being fixed.
 *
 * Returns plain Strings because LazyColumn keys must survive saved-instance
 * state; MobNodeIdentityKey is a data class and is not Saveable.
 */
internal fun mobRendererChildKeys(children: List<MobNode>): List<String> {
    val seen = HashSet<String>(children.size * 2)

    return children.mapIndexed { index, child ->
        // A non-empty String, matching iOS exactly. Mob.Renderer coerces atom
        // and number ids to strings before they leave Elixir, so the platforms
        // agree by construction; keying on anything else here would resurrect
        // the divergence — MobNodeIdentity.keyFor canonicalises any JSON value,
        // while iOS reads :id as an NSString and ignores the rest.
        //
        // Deliberately not MobNodeIdentity.keyFor: that is the sheet-slot
        // identity and has different (broader) semantics. It also raises on an
        // unknown value type, which is fine for the one sheet per screen it was
        // written for and not fine on a path that now runs for every child of
        // every column, row and lazy list.
        val authored = (child.props["id"] as? String)?.takeIf { it.isNotEmpty() }
        var k = if (authored != null) "i\u0001" + authored else "p\u0001" + index
        if (!seen.add(k)) k = "d\u0001" + index + "\u0001" + k
        k
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun RenderNodeInner(node: MobNode, modifier: Modifier) {
    // Apply on_tap as a clickable modifier for any node type except button —
    // button installs its own onClick via the Button composable. Mirrors iOS,
    // where most node types pick up onTapGesture via .ifLet(node.onTap).
    val tapHandle = intProp(node.props, "on_tap")
    val longPressHandle = intProp(node.props, "on_long_press")
    val doubleTapHandle = intProp(node.props, "on_double_tap")
    val isDisabled = boolProp(node.props, "disabled") ?: false
    val accessibilityRole = node.props["accessibility_role"] as? String
    val isButton = node.type == "box" && accessibilityRole == "button"
    // The node types iOS actually attaches gestures to. MobRootView applies
    // .mobGestures(node) at exactly five sites — column (:298), row (:335),
    // label (:363), icon (:379) and box (:828) — out of 25 case branches.
    // Everything else, button included, never gets a long press there.
    //
    // Gating on `!= "button"` instead would hand combinedClickable to
    // text_field, toggle, slider, image and the rest, which iOS never does. On
    // a text_field that is actively harmful: long press is the platform's own
    // text-selection gesture, and installing a competing detector over it
    // trades a working selection for a handler iOS would not have fired.
    val gesturableType = node.type in setOf("column", "row", "text", "icon", "box")

    // Read through a snapshot for the same reason the swipe and scroll paths do:
    // handles are re-registered every render, so a detector keyed on one is
    // cancelled by any mid-gesture re-render.
    val pressHandles by rememberUpdatedState(MobPressHandles(longPressHandle, doubleTapHandle))

    val tapModifier = when {
        // Only when a long-press or double-tap is actually declared.
        // combinedClickable installs a detector that delays the click to wait
        // for a possible second tap, so making it the default would add latency
        // to every ordinary tap in the app. Role and `enabled` are carried over
        // from the plain arms below so accessibility behaviour does not change
        // just because a node gained a long-press.
        // With a real on_tap: combinedClickable is right — ripple, focusability
        // and an "activate" action that actually does something.
        tapHandle != null && (longPressHandle != null || doubleTapHandle != null) &&
            gesturableType ->
            modifier.combinedClickable(
                enabled = !isDisabled,
                role = if (isButton) Role.Button else null,
                onLongClick = longPressHandle?.let { h -> { MobBridge.nativeSendLongPress(h) } },
                onDoubleClick = doubleTapHandle?.let { h -> { MobBridge.nativeSendDoubleTap(h) } }
            ) { MobBridge.nativeSendTap(tapHandle) }

        // Long press or double tap with NO on_tap: a raw detector, not
        // combinedClickable. combinedClickable would need an onClick, and
        // passing an empty one publishes a clickable, focusable node with an
        // "activate" accessibility action that does nothing — the same
        // misreporting the plain arms below were written to avoid. iOS's
        // .onLongPressGesture adds no tap affordance either.
        (longPressHandle != null || doubleTapHandle != null) && gesturableType ->
            // Keyed on WHICH handlers are declared, for the same reason as the
            // swipe detector: with a constant key the block never restarts, so a
            // box that starts with on_long_press and later gains on_double_tap
            // would keep a null onDoubleTap forever. The handle values are still
            // read live through pressHandles.
            modifier.pointerInput(longPressHandle != null, doubleTapHandle != null) {
                detectTapGestures(
                    onLongPress =
                        if (longPressHandle == null) null
                        else { _: Offset ->
                            pressHandles.long?.let { MobBridge.nativeSendLongPress(it) }
                        },
                    onDoubleTap =
                        if (doubleTapHandle == null) null
                        else { _: Offset ->
                            pressHandles.double?.let { MobBridge.nativeSendDoubleTap(it) }
                        }
                )
            }

        // Require a handler here. Compose's ClickableSemanticsNode publishes
        // disabled() whenever `enabled` is false, so encoding "no tap handler"
        // as enabled = false made a perfectly live box whose tap is handled by
        // an ancestor announce as "…, button, disabled". With no handler we
        // fall through to the semantics-only path below, which still sets the
        // button role.
        isButton && tapHandle != null ->
            modifier.clickable(enabled = !isDisabled, role = Role.Button) {
                MobBridge.nativeSendTap(tapHandle)
            }

        // `enabled = !isDisabled` here too, not just on the button arm above.
        // Without it a box with `disabled: true` and no explicit
        // accessibility_role still dispatched taps, while the semantics block
        // below simultaneously marked it disabled() — announced as disabled to
        // TalkBack and still firing. iOS applies .disabled() to every box
        // regardless of role, so this also keeps the platforms in step.
        tapHandle != null && node.type != "button" && !HandbeanRender.handlesOwnTap(node.type) ->
            modifier.clickable(enabled = !isDisabled) { MobBridge.nativeSendTap(tapHandle) }

        else -> modifier
    }
    // ── Swipe (MOB-138) ─────────────────────────────────────────────────────
    // Attached only when a swipe handler is actually declared. detectDragGestures
    // consumes the drag, so an unconditional pointerInput here would swallow
    // scrolling for every node in the app. iOS gates its DragGesture on the same
    // condition and for the same reason.
    val swipeAny   = intProp(node.props, "on_swipe")
    val swipeLeft  = intProp(node.props, "on_swipe_left")
    val swipeRight = intProp(node.props, "on_swipe_right")
    val swipeUp    = intProp(node.props, "on_swipe_up")
    val swipeDown  = intProp(node.props, "on_swipe_down")
    // Same five-type restriction as above: iOS's swipe DragGesture lives inside
    // mobGestures, so it reaches exactly the same nodes and no others.
    val hasSwipe = gesturableType &&
        (swipeAny != null || swipeLeft != null || swipeRight != null ||
            swipeUp != null || swipeDown != null)

    // Same reasoning as the canvas drag below: handles change on every render,
    // so keying on them lets any mid-gesture re-render cancel the detector. A
    // swipe only emits at onDragEnd, so it survives today by accident — nothing
    // re-renders during it. That stops being true the moment the screen updates
    // for any other reason mid-swipe.
    val liveSwipe by rememberUpdatedState(
        MobSwipeHandlers(swipeAny, swipeLeft, swipeRight, swipeUp, swipeDown)
    )

    // Which axes the declared handlers actually cover. A swipe detector that
    // consumes both axes wins pointer arbitration against an ancestor
    // verticalScroll/LazyColumn, so a swipe-to-delete row inside a list would
    // freeze that list: any drag starting on a row is swallowed and only drags
    // in the gaps between rows scroll. iOS does not have this problem, because a
    // plain DragGesture loses arbitration to UIScrollView's pan recogniser.
    //
    // When the declared set is axis-pure, use the axis-specific detector. What
    // saves the parent is slop-direction arbitration, not per-axis consumption
    // — change.consume() still consumes the whole change; the difference is that
    // detectHorizontalDragGestures only claims the gesture once the drag crosses
    // slop HORIZONTALLY, so a vertical drag is never claimed and reaches the
    // parent scroll.
    //
    // This therefore fixes the horizontal-swipe-inside-vertical-scroll case, the
    // common one (swipe-to-delete). A vertical swipe inside a vertical scroll is
    // NOT fixed and cannot be by this mechanism: both want the same axis, and
    // the child wins. A generic on_swipe likewise has to take the whole gesture.
    //
    // Note the axis detectors also change classification: horizontal-only never
    // accumulates dy, so an L-shaped drag (40dp right then 200dp down) fires
    // swipe_right, where the both-axis path and iOS would call it "down" and
    // fire nothing.
    val swipeHorizontalOnly =
        swipeAny == null && swipeUp == null && swipeDown == null &&
            (swipeLeft != null || swipeRight != null)
    val swipeVerticalOnly =
        swipeAny == null && swipeLeft == null && swipeRight == null &&
            (swipeUp != null || swipeDown != null)

    val gestureModifier = if (!hasSwipe) tapModifier else {
        // Keyed on which axes are declared, NOT on Unit and NOT on the handles.
        //
        // Not Unit: SuspendPointerInputElement compares keys only, so with a
        // constant key the block never restarts and the detector chosen at first
        // composition runs forever. A row that starts with on_swipe_left and
        // later gains on_swipe_up would keep the horizontal-only detector and
        // never fire the vertical one; a node that narrows from generic
        // on_swipe to on_swipe_left would keep detectDragGestures and keep
        // freezing its parent list — the very thing the split exists to avoid.
        //
        // Not the handles: those change every render, which would cancel the
        // detector mid-gesture. These two booleans only flip when the declared
        // prop set changes, which is exactly when a restart is correct.
        //
        // A restart does drop an in-flight gesture — the coroutine is cancelled
        // and the new block starts at awaitFirstDown(), which will not see a
        // down that is already held, so nothing fires until the finger lifts and
        // presses again. Acceptable: it happens only when the app changes which
        // swipe directions a node declares, mid-drag.
        tapModifier.pointerInput(swipeHorizontalOnly, swipeVerticalOnly) {
            // 30dp mirrors iOS's DragGesture(minimumDistance: 30). There the
            // gesture never starts below the threshold; Compose starts at touch
            // slop, so the distance check moves to the end instead. Note the
            // residual divergence: Compose reports positions from AFTER slop is
            // crossed, so the accumulated distance excludes it and the effective
            // floor here is 30dp + slop. iOS also thresholds on overall drag
            // distance while this is per-dominant-axis, so a 25x25dp diagonal
            // swipes on iOS and does not here.
            val minDistance = 30.dp.toPx()
            var dx = 0f
            var dy = 0f

            fun fire() {
                // Dominant axis wins, ties go vertical — same rule as iOS,
                // where `abs(dx) > abs(dy)` picks horizontal and everything
                // else falls through to vertical.
                val direction = when {
                    abs(dx) > abs(dy) && abs(dx) >= minDistance -> if (dx > 0) "right" else "left"
                    abs(dy) >= abs(dx) && abs(dy) >= minDistance -> if (dy > 0) "down" else "up"
                    else -> null
                } ?: return

                // Generic first, then the direction-specific one. iOS fires them
                // in this order and a node may have both.
                val sw = liveSwipe
                sw.any?.let { MobBridge.nativeSendSwipe(it, direction) }
                when (direction) {
                    "left"  -> sw.left?.let  { MobBridge.nativeSendSwipeLeft(it) }
                    "right" -> sw.right?.let { MobBridge.nativeSendSwipeRight(it) }
                    "up"    -> sw.up?.let    { MobBridge.nativeSendSwipeUp(it) }
                    "down"  -> sw.down?.let  { MobBridge.nativeSendSwipeDown(it) }
                }
            }

            when {
                swipeHorizontalOnly ->
                    detectHorizontalDragGestures(
                        onDragStart = { dx = 0f; dy = 0f },
                        onDragEnd = { fire() }
                    ) { change, amount ->
                        dx += amount
                        change.consume()
                    }

                swipeVerticalOnly ->
                    detectVerticalDragGestures(
                        onDragStart = { dx = 0f; dy = 0f },
                        onDragEnd = { fire() }
                    ) { change, amount ->
                        dy += amount
                        change.consume()
                    }

                else ->
                    detectDragGestures(
                        onDragStart = { dx = 0f; dy = 0f },
                        onDragEnd = { fire() }
                    ) { change, drag ->
                        dx += drag.x
                        dy += drag.y
                        change.consume()
                    }
            }
        }
    }

    val base = gestureModifier.then(nodeModifier(node.props))
    // Track on-screen frame + set a testTag for any node carrying an :id, so the
    // agent can read positions (Mob.Test.element_frames) without a screenshot.
    val trackId = node.props["id"] as? String
    val m = if (trackId != null) base.then(MobBridge.frameTrackingModifier(trackId)) else base
    if (HandbeanRender.renderShell(node, m)) return
    when (node.type) {
        "column" -> MobColumn(node, m)
        "row" -> MobRow(node, m)
        "box" -> MobBox(node, m)
        "scroll" -> MobScroll(node, m)
        "text"       -> MobText(node, m)
        "button"     -> MobButton(node, m)
        "tab_bar"    -> MobTabBar(node, m)
        "text_field" -> MobTextField(node, m)
        "toggle"     -> MobToggle(node, m)
        "slider"     -> MobSlider(node, m)
        "divider"    -> MobDivider(node, m)
        "spacer"     -> MobSpacer(node, m)
        "progress"   -> MobProgress(node, m)
        "image"      -> MobImage(node, m)
        "icon"       -> MobIcon(node, m)
        "lazy_list"  -> MobLazyList(node, m)
        "video"          -> MobVideoPlayer(node, m)
        "camera_preview" -> MobCameraPreview(node, m)
        "web_view"       -> MobWebView(node, m)
        "native_view"    -> MobNativeViewRegistry.render(node)
        "canvas"         -> MobCanvas(node, m)
        "gpu_view"       -> MobGpuView(node, m)
        "sheet"          -> MobSheetSlot(node) { state -> MobSheet(node, state) }
        else             -> HandbeanRender.renderCustomNode(node, modifier, trackId)
    }
}
