package com.example.handbean_probe

import android.util.Log
import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AcUnit
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.List
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.QrCode
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.BottomSheetDefaults
import androidx.compose.material3.Button
import androidx.compose.material3.DividerDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SheetValue
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.example.handbean_probe.HandbeanRender.rowChildModifier
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

/**
 * The scroll handlers for one node, re-read on every composition.
 *
 * Exists so MobScrollEvents can hold the *latest* handles without keying its
 * LaunchedEffect on them: handles are re-registered every render and would
 * otherwise restart the effect and wipe its accumulated scroll state.
 */
private data class MobScrollHandlers(
    val scroll: Int?,
    val began: Int?,
    val ended: Int?,
    val settled: Int?,
    val top: Int?,
    val past: Int?,
    val threshold: Float,
)

/**
 * Emits the scroll event family for a `:scroll` node (MOB-138).
 *
 * Mirrors iOS's MobScrollObserver: first sample opens the scroll with
 * `began`, subsequent samples report deltas and velocity, and a debounced
 * "no motion for 150ms" timer closes it with ended + settled. Throttling and
 * delta-thresholding are applied native-side in mob_send_scroll, so every
 * observed sample is forwarded and the zig layer decides what crosses to the
 * BEAM.
 *
 * Returns immediately when the node declares no scroll handler, so the common
 * scroll node pays nothing beyond six null prop reads.
 */
@Composable
private fun MobScrollEvents(node: MobNode, scrollState: ScrollState, horizontal: Boolean) {
    val scrollH   = intProp(node.props, "on_scroll")
    val beganH    = intProp(node.props, "on_scroll_began")
    val endedH    = intProp(node.props, "on_scroll_ended")
    val settledH  = intProp(node.props, "on_scroll_settled")
    val topH      = intProp(node.props, "on_top_reached")
    val pastH     = intProp(node.props, "on_scrolled_past")
    val threshold = floatProp(node.props, "scrolled_past_threshold") ?: 0f

    if (scrollH == null && beganH == null && endedH == null &&
        settledH == null && topH == null && pastH == null) {
        return
    }

    // scroll_config rides alongside on_scroll; only the throttled sender reads it.
    ApplyThrottleConfig(node.props, scrollH, "scroll_config")

    // The handles must NOT key the effect. Every render clears and re-registers
    // the tap table, so each of these ints is different on every frame — and a
    // scroll handler re-renders the screen, which re-registers, which changes
    // the keys. Keying on them restarts the effect mid-scroll and resets
    // `hasBegun`/`last`/`wasPast`, so began fires on every sample, scrolled_past
    // stops latching, and every delta is computed against a just-reset baseline
    // and comes out 0. Key on the ScrollState, which is remembered and stable,
    // and read the handles through a snapshot that updates without restarting.
    val h by rememberUpdatedState(
        MobScrollHandlers(scrollH, beganH, endedH, settledH, topH, pastH, threshold)
    )

    // ScrollState.value is physical pixels; iOS reports contentOffset in points
    // and every threshold an app writes (scrolled_past_threshold, delta) is
    // authored against that. Forwarding pixels would make the same number mean
    // a third of the distance on a 3x device.
    val density = LocalDensity.current

    LaunchedEffect(scrollState, horizontal, density) {
        var last = with(density) { scrollState.value.toDp().value }
        var lastTs = 0L
        var hasBegun = false
        var wasPast = false
        var endJob: Job? = null

        // drop(1): snapshotFlow emits its CURRENT value the moment it is
        // collected, before anything has moved. Without this, mounting any
        // screen with a scroll handler fires began + a 150ms-later ended and
        // settled for a scroll the user never made — chrome that hides itself
        // on arrival, analytics for phantom scrolls. iOS's
        // onScrollGeometryChange has no such initial callback.
        snapshotFlow { scrollState.value }.drop(1).collect { raw ->
            val pos = with(density) { raw.toDp().value }
            val now = System.nanoTime()
            val dt = if (lastTs > 0L) (now - lastTs) / 1_000_000_000.0 else 0.0
            val delta = pos - last
            val velocity = if (dt > 0.0) delta / dt else 0.0

            // A ScrollState is one-dimensional; which axis it means depends on
            // whether the node rendered a horizontalScroll or a verticalScroll.
            // Reporting into the wrong axis would leave the other permanently 0.
            val x  = if (horizontal) pos.toDouble() else 0.0
            val y  = if (horizontal) 0.0 else pos.toDouble()
            val dx = if (horizontal) delta.toDouble() else 0.0
            val dy = if (horizontal) 0.0 else delta.toDouble()
            val vx = if (horizontal) velocity else 0.0
            val vy = if (horizontal) 0.0 else velocity

            if (!hasBegun) {
                hasBegun = true
                h.began?.let { MobBridge.nativeSendScrollBegan(it) }
                h.scroll?.let { MobBridge.nativeSendScroll(it, x, y, 0.0, 0.0, 0.0, 0.0, "began") }
            } else {
                h.scroll?.let { MobBridge.nativeSendScroll(it, x, y, dx, dy, vx, vy, "dragging") }
            }

            // Fires on ENTERING the top, not while sitting there — otherwise a
            // screen already at 0 would emit on every unrelated recomposition.
            if (pos <= 0.001f && last > 0.001f) {
                h.top?.let { MobBridge.nativeSendTopReached(it) }
            }

            // Latched: only the crossing fires, so dithering around the
            // boundary does not spam the BEAM.
            if (h.threshold > 0f) {
                val nowPast = pos > h.threshold
                if (nowPast && !wasPast) h.past?.let { MobBridge.nativeSendScrolledPast(it) }
                wasPast = nowPast
            }

            last = pos
            lastTs = now

            // Debounced close. Each sample cancels the pending timer, so ended
            // fires once, 150ms after motion actually stops.
            endJob?.cancel()
            endJob = launch {
                delay(150)
                if (hasBegun) {
                    hasBegun = false
                    h.ended?.let { MobBridge.nativeSendScrollEnded(it) }
                    h.settled?.let { MobBridge.nativeSendScrollSettled(it) }
                    h.scroll?.let {
                        MobBridge.nativeSendScroll(it, x, y, 0.0, 0.0, 0.0, 0.0, "ended")
                    }
                }
            }
        }
    }
}

@Composable
internal fun MobColumn(node: MobNode, m: Modifier) {
    Column(modifier = m) {
        val keys = mobChildKeys(node.children)
        node.children.forEachIndexed { i, child ->
            // Modifier.weight is resolved out here, in ColumnScope — forEachIndexed
            // is inline so the scope survives, but key()'s block is a plain
            // composable lambda and has no scope of its own.
            val w = floatProp(child.props, "weight")
            val childModifier = if (w != null) Modifier.weight(w) else Modifier
            key(keys[i]) { RenderNode(child, childModifier) }
        }
    }
}

@Composable
internal fun MobRow(node: MobNode, m: Modifier) {
    Row(modifier = m, verticalAlignment = rowAlignProp(node.props)) {
        val keys = mobChildKeys(node.children)
        node.children.forEachIndexed { i, child ->
            val w = floatProp(child.props, "weight")
            val childModifier = rowChildModifier(node, child, if (w != null) Modifier.weight(w) else Modifier)
            key(keys[i]) { RenderNode(child, childModifier) }
        }
    }
}

// Box defaults to fillMaxWidth when no explicit width is set.
// Content alignment follows the same props as the iOS renderer.
@Composable
internal fun MobBox(node: MobNode, m: Modifier) {
    val isButton = node.props["accessibility_role"] == "button"
    val isDisabled = boolProp(node.props, "disabled") ?: false
    val hasWidth = floatProp(node.props, "width") != null
    val accessibilityLabel = node.props["accessibility_label"] as? String
    // Merge for a label OR an explicit button role. Setting
    // role/disabled without merging leaves them on the container while
    // each child stays its own node, so TalkBack walks into a
    // "button" and reads its children as separate elements. Matches
    // the iOS side, which collapses on the same condition.
    val accessibilityModifier = Modifier.semantics(
        mergeDescendants = accessibilityLabel != null || isButton,
    ) {
        if (accessibilityLabel != null) contentDescription = accessibilityLabel
        if (isButton) role = Role.Button
        if (isDisabled) disabled()
    }
    val boxModifier = (if (hasWidth) m else m.fillMaxWidth())
        .then(accessibilityModifier)
    Box(modifier = boxModifier, contentAlignment = boxAlignProp(node.props)) {
        mobChildKeys(node.children).let { keys ->
            node.children.forEachIndexed { i, child -> key(keys[i]) { RenderNode(child) } }
        }
    }
}

@Composable
internal fun MobScroll(node: MobNode, m: Modifier) {
    // Re-created per navigation, for the same reason MobLazyList's state
    // is: `rememberScrollState()` is keyless, so with the composition
    // preserved across navigation (MOB-146) a scroll view landing in the
    // same slot would open the new screen at the old screen's offset.
    val scrollState = HandbeanRender.retainedScrollState(node)
        ?: key(MobBridge.LocalSlotEpoch.current) { rememberScrollState() }
    val horizontal = node.props["axis"] == "horizontal"
    HandbeanRender.stickToBottom(node, scrollState, horizontal)

    // Decided up front because it determines whether this node scrolls a
    // pixel ScrollState at all, and therefore whether the scroll event
    // family can be emitted. Installing the observer on the lazy path
    // would attach it to a ScrollState nothing ever moves.
    val soleChild = node.children.singleOrNull()
    val isLazyPath = !horizontal &&
        boolProp(node.props, "lazy") == true &&
        soleChild != null &&
        soleChild.type == "column" &&
        soleChild.props.keys.all { it == "fill_width" || it == "fill_height" } &&
        soleChild.children.none { it.props.containsKey("weight") }

    if (!isLazyPath) MobScrollEvents(node, scrollState, horizontal)
    // Register by :id so Mob.Test.scroll_info/scroll_to can address it,
    // and record the measured viewport (ScrollState doesn't expose it).
    val id = node.props["id"] as? String
    val regMod: Modifier =
        if (id != null) {
            val handle = MobBridge.scrollHandle(id)
            handle.scrollState = scrollState
            handle.horizontal = horizontal
            Modifier.onGloballyPositioned {
                handle.viewportPx = if (horizontal) it.size.width else it.size.height
            }
        } else {
            Modifier
        }
    if (horizontal) {
        Row(modifier = m.then(regMod).horizontalScroll(scrollState)) {
            mobChildKeys(node.children).let { keys ->
                node.children.forEachIndexed { i, child -> key(keys[i]) { RenderNode(child) } }
            }
        }
    } else {
        // Compose only the rows that are on screen.
        //
        // Mob screens are written scroll > column > rows, so a scroll
        // node usually has exactly ONE child; lazifying its direct
        // children would buy nothing because the column underneath still
        // composes every row. Flatten one level when that column can be
        // removed without changing what the user sees, and use its
        // children as the items.
        //
        // The guard is deliberately narrow. Only fill_width/fill_height
        // are droppable: a LazyColumn already spans its container's
        // width, and fill_height is a no-op under the unbounded main
        // axis a scroll gives its content. ANY other prop — padding,
        // background, align, an id the harness addresses, a tap handler
        // — is something the column contributes visually or behaviourally
        // and would be silently lost, so those keep the eager path.
        //
        // A child carrying `weight` also forces the eager path: weight
        // comes from ColumnScope, and LazyColumn items have no such
        // scope, so it would be dropped without a trace.
        // OPT-IN. `lazy: true` on the scroll node, nothing else.
        //
        // Laziness is not free of observable consequences: rows below
        // the fold are never composed, so they never register a frame
        // and Mob.Test.element_frames / tap_id cannot address them, and
        // scroll position becomes index-based rather than pixel-based.
        // `lazy_list` already makes that trade explicitly. Making it the
        // silent default for every `:scroll` would change harness
        // behaviour under apps that never asked for it, so the author
        // asks for it.
        val sole = soleChild
        val flattenable = isLazyPath

        if (flattenable) {
            // MobLazyList registers `lazyState` under this node's id.
            // The pixel ScrollState above must NOT stay registered: it is
            // never attached to a verticalScroll on this path, so its
            // maxValue keeps its Int.MAX_VALUE default and scrollInfo —
            // which checks scrollState FIRST — would report kind "pixel"
            // with max_y ~2.1e9. scroll_to would then return :ok without
            // moving, and screenshot_tour would page a million times.
            if (id != null) {
                val handle = MobBridge.scrollHandle(id)
                handle.scrollState = null
                handle.horizontal = false
            }
            // The scroll event family is driven by the pixel ScrollState,
            // which this path deliberately detaches — a LazyColumn scrolls
            // a LazyListState instead, in item index + offset rather than
            // pixels. Rather than let the handlers go quiet the way
            // MOB-138 describes, say so once, loudly.
            val declaresScrollHandlers =
                intProp(node.props, "on_scroll") != null ||
                    intProp(node.props, "on_scroll_began") != null ||
                    intProp(node.props, "on_scroll_ended") != null ||
                    intProp(node.props, "on_scroll_settled") != null ||
                    intProp(node.props, "on_top_reached") != null ||
                    intProp(node.props, "on_scrolled_past") != null

            // In a LaunchedEffect, not the composable body: a bare Log.w
            // here would re-fire on every recomposition, which for a
            // scrolling list is every frame.
            if (declaresScrollHandlers) {
                LaunchedEffect(id) {
                    Log.w("MobBridge",
                        "scroll node id=" + (id ?: "?") + " declares scroll handlers " +
                        "with lazy: true; the scroll event family is pixel-based and " +
                        "is not emitted on the lazy path. iOS does emit it here, so " +
                        "this is a platform divergence. Drop lazy or drop the handlers.")
                }
            }
            MobLazyList(node.copy(children = sole!!.children), m)
        } else {
            Column(modifier = m.then(regMod).verticalScroll(scrollState).imePadding()) {
                mobChildKeys(node.children).let { keys ->
                    node.children.forEachIndexed { i, child -> key(keys[i]) { RenderNode(child) } }
                }
            }
        }
    }
}

@Composable
internal fun MobDivider(node: MobNode, modifier: Modifier) {
    val thickness = floatProp(node.props, "thickness") ?: 1f
    val color     = colorProp(node.props, "color")
    HorizontalDivider(
        modifier  = modifier,
        thickness = thickness.dp,
        color     = if (color != Color.Unspecified) color else DividerDefaults.color,
    )
}

@Composable
internal fun MobSpacer(node: MobNode, modifier: Modifier) {
    val size = floatProp(node.props, "size")
    // size() sets both width and height so Spacer works as a gap in both Column and Row.
    Spacer(modifier = if (size != null) modifier.size(size.dp) else modifier)
}

@Composable
internal fun MobProgress(node: MobNode, modifier: Modifier) {
    val value = floatProp(node.props, "value")
    val color = colorProp(node.props, "color")
    val trackColor = if (color != Color.Unspecified) color else Color.Unspecified

    if (value != null) {
        LinearProgressIndicator(
            progress    = { value },
            modifier    = modifier.fillMaxWidth(),
            color       = if (trackColor != Color.Unspecified) trackColor else Color.Unspecified,
        )
    } else {
        LinearProgressIndicator(
            modifier = modifier.fillMaxWidth(),
            color    = if (trackColor != Color.Unspecified) trackColor else Color.Unspecified,
        )
    }
}

// MobSheet — native modal bottom sheet backed by Material 3 ModalBottomSheet.
// Presentation is owned by `visible`, a Compose-`remember`ed boolean. The
// dispatch site keys this whole composable by the sheet's stable node id so a
// different sheet rendered into the same tree slot gets fresh presentation
// state. Without that boundary, a late dismiss callback from the old sheet can
// hide its replacement and its `dismissSent` flag can suppress the new
// sheet's callback. Sheets without an id keep the former slot-based behavior
// through the constant Unit fallback.
//
// Deliberately does NOT take the `m` (nodeModifier(node.props)-derived)
// modifier every other composable receives from RenderNodeInner — that
// modifier already has `background`/`corner_radius` baked in as
// `.background()`/`.clip()`, which would double up against
// ModalBottomSheet's own `containerColor`/`shape` params (it owns its
// container paint the same way M3's Button does, and can't take those
// via a modifier chain). Content-area props are read directly off
// `node.props` with those two keys stripped instead.
// Node types that install their own scrollable container. A sheet must not
// wrap these in another vertical scroll: Compose throws on a scrollable
// measured with infinite max height.
private fun isScrollableNode(node: MobNode): Boolean =
    node.type == "scroll" || node.type == "lazy_list" || node.children.any(::isScrollableNode)

internal class MobSheetPresentationState {
    var visible by mutableStateOf(true)
        private set

    private var active = true
    private var dismissSent = false

    fun deactivate() {
        active = false
    }

    fun dismiss(sendDismiss: () -> Unit) {
        if (!active) return

        visible = false
        if (!dismissSent) {
            dismissSent = true
            sendDismiss()
        }
    }
}

@Composable
internal fun MobLayoutSheetSlot(
    node: MobNode,
    content: @Composable (MobSheetPresentationState) -> Unit
) {
    val identityKey = MobNodeIdentity.keyFor(node)
    // The epoch joins the identity key for the same reason: an id-less sheet
    // dismissed on the outgoing screen would otherwise carry visible=false and
    // dismissSent=true into the incoming screen's sheet, which would then never
    // show and never fire :on_dismiss.
    key(identityKey ?: Unit, MobBridge.LocalSlotEpoch.current) {
        val presentation = remember { MobSheetPresentationState() }
        DisposableEffect(presentation) {
            onDispose { presentation.deactivate() }
        }
        content(presentation)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun MobSheet(node: MobNode, presentation: MobSheetPresentationState) {
    val rawDetents = sheetDetentsProp(node.props)
    val contentDetent = rawDetents.filterIsInstance<JSONObject>()
        .firstOrNull { detent -> detent.optString("type") == "content" }
    val detents = rawDetents.filterIsInstance<String>()
        .filter { detent -> detent == "medium" || detent == "large" }
        .ifEmpty { if (contentDetent == null) listOf("medium", "large") else emptyList() }
    val contentOnly = contentDetent != null
    val allowsMedium = "medium" in detents
    val allowsLarge = "large" in detents || contentOnly
    val mediumOnly = allowsMedium && !allowsLarge

    val dismissHandle = intProp(node.props, "on_dismiss")

    if (!presentation.visible) return

    val sheetState = rememberModalBottomSheetState(
        skipPartiallyExpanded = !allowsMedium,
        confirmValueChange = { value ->
            allowsLarge || value != SheetValue.Expanded
        }
    )

    LaunchedEffect(sheetState) { sheetState.show() }

    val containerColor = colorProp(node.props, "background")
        .takeIf { it != Color.Unspecified } ?: BottomSheetDefaults.ContainerColor
    val cornerRadius = floatProp(node.props, "corner_radius") ?: 0f
    val shape = if (cornerRadius > 0f) {
        RoundedCornerShape(topStart = cornerRadius.dp, topEnd = cornerRadius.dp)
    } else {
        BottomSheetDefaults.ExpandedShape
    }
    val scrimColor = colorProp(node.props, "scrim")
        .takeIf { it != Color.Unspecified } ?: BottomSheetDefaults.ScrimColor

    // Custom drag indicator requires all four geometry props together —
    // Mob.UI.sheet/2 already enforces this; check defensively here too
    // since a hand-built node map (bypassing that validation) is possible.
    val indicatorColor = colorProp(node.props, "drag_indicator_color")
    val indicatorWidth = floatProp(node.props, "drag_indicator_width")
    val indicatorHeight = floatProp(node.props, "drag_indicator_height")
    val indicatorRailHeight = floatProp(node.props, "drag_indicator_rail_height")
    val hasCustomIndicator = indicatorColor != Color.Unspecified &&
        indicatorWidth != null && indicatorHeight != null && indicatorRailHeight != null

    // background/corner_radius belong to ModalBottomSheet's own
    // containerColor/shape above — not the child content's modifier.
    val contentProps = node.props - listOf("background", "corner_radius")
    val contentModifier = nodeModifier(contentProps)

    ModalBottomSheet(
        onDismissRequest = {
            presentation.dismiss {
                // {:dismiss, tag}, not {:tap, tag} — matches what Mob.UI.sheet/2
                // documents and what iOS sends. See MOB-104.
                dismissHandle?.let { MobBridge.nativeSendDismiss(it) }
            }
        },
        sheetState = sheetState,
        containerColor = containerColor,
        scrimColor = scrimColor,
        shape = shape,
        dragHandle = if (hasCustomIndicator) {
            {
                Box(
                    modifier = Modifier.fillMaxWidth().height(indicatorRailHeight!!.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Box(
                        modifier = Modifier
                            .width(indicatorWidth!!.dp)
                            .height(indicatorHeight!!.dp)
                            .background(indicatorColor, RoundedCornerShape(50))
                    )
                }
            }
        } else {
            { BottomSheetDefaults.DragHandle() }
        }
    ) {
        // MOB-follow-up (mob_new-e30-5): Material 3 can omit the
        // PartiallyExpanded anchor when content is shorter than half the
        // viewport. A medium-only sheet rejects Expanded (confirmValueChange
        // above), so a too-short sheet would otherwise never get a valid
        // anchor to land on and stay hidden. Force content to slightly over
        // half the measured viewport height in that case only — full
        // medium+large sheets size to their natural content height as usual.
        BoxWithConstraints(modifier = Modifier.fillMaxWidth()) {
            val configuredMaximumHeight = contentDetent
                ?.takeIf { detent -> detent.has("max_height") }
                ?.optDouble("max_height")
                ?.toFloat()
                ?.dp
            val contentMaximumHeight = configuredMaximumHeight
                ?.let(maxHeight::coerceAtMost)
                ?: maxHeight
            val mediumDetentModifier = if (mediumOnly) {
                Modifier.heightIn(min = maxHeight * 0.5f + 1.dp)
            } else {
                Modifier
            }

            // Only add our own scroll when the content doesn't already
            // contain one. Compose's checkScrollableContainerConstraints
            // THROWS when a scrollable is measured with an infinite max
            // height, which is exactly what wrapping verticalScroll around a
            // `scroll` or `lazy_list` child does — so an intrinsic sheet
            // containing a list (the most natural use of one) crashed at first
            // measure. iOS survives the equivalent nesting because SwiftUI
            // tolerates it; Compose does not. Cap the height either way; let
            // the child own the scrolling when it has its own.
            val hasScrollableChild = node.children.any(::isScrollableNode)
            val contentDetentModifier = when {
                contentOnly && hasScrollableChild ->
                    Modifier.heightIn(max = contentMaximumHeight)

                contentOnly ->
                    Modifier
                        .heightIn(max = contentMaximumHeight)
                        .verticalScroll(rememberScrollState())

                else -> Modifier
            }

            Column(
                // Cap BEFORE the node's own padding, so padding counts against
                // max_height instead of being added outside it — otherwise a
                // sheet with padding overshoots the documented cap, and
                // disagrees with iOS, which caps the already-padded body.
                modifier = mediumDetentModifier
                    .then(contentDetentModifier)
                    .then(contentModifier)
                    .fillMaxWidth()
            ) {
                mobChildKeys(node.children).let { keys ->
                    node.children.forEachIndexed { i, child -> key(keys[i]) { RenderNode(child) } }
                }
            }
        }
    }
}

@Composable
internal fun MobLazyList(node: MobNode, modifier: Modifier) {
    val handle    = intProp(node.props, "on_end_reached")
    val stateIdentity = MobLazyListStateIdentity.keyFor(node, handle)
    // Persist by stable node/slot identity so render-generation changes do not
    // reset scroll position or leak one LazyListState per frame.
    // Keyed on the slot epoch as well as the identity.
    //
    // `setRootJson` clears `lazyListStates` on navigation, and says why: old
    // list state would scroll the wrong list to a stale position. That clear
    // used to stick because the composition was disposed with it. It is not
    // any more (MOB-146), so a list landing in the same composition slot keeps
    // the remembered LazyListState OBJECT and never looks at the map again —
    // the clear becomes a no-op and a push to a structurally similar screen
    // opens it mid-scroll. An id-less list with no `on_end_reached` has a null
    // identity, so without the epoch it would retain across every navigation.
    val listState = remember(stateIdentity, MobBridge.LocalSlotEpoch.current) {
        if (stateIdentity != null) MobBridge.getOrCreateLazyListState(stateIdentity)
        else LazyListState()
    }

    // Register by :id so Mob.Test.scroll_info/scroll_to can address this list.
    (node.props["id"] as? String)?.let { id ->
        MobBridge.scrollHandle(id).lazyState = listState
    }

    val reachedEnd by remember {
        derivedStateOf {
            val lastVisible = listState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: -1
            val total       = listState.layoutInfo.totalItemsCount
            total > 0 && lastVisible >= total - 1
        }
    }

    LaunchedEffect(reachedEnd) {
        if (reachedEnd) handle?.let { MobBridge.nativeSendTap(it) }
    }

    // Hoisted out of the LazyColumn: its trailing lambda is a LazyListScope
    // builder, not a composable, so remember/1 cannot be called inside it.
    val keys = mobChildKeys(node.children)

    LazyColumn(state = listState, modifier = modifier.fillMaxWidth()) {
        itemsIndexed(node.children, key = { index, _ -> keys[index] }) { _, child ->
            RenderNode(child)
        }
    }
}

@Composable
internal fun MobTabBar(node: MobNode, modifier: Modifier) {
    val tabs     = tabDefsProp(node.props)
    val activeId = (node.props["active"] as? String) ?: tabs.firstOrNull()?.get("id") ?: ""
    val handle   = intProp(node.props, "on_tab_select")
    val activeIdx = tabs.indexOfFirst { it["id"] == activeId }.coerceAtLeast(0)

    Scaffold(
        modifier  = modifier,
        bottomBar = {
            NavigationBar {
                tabs.forEachIndexed { index, tab ->
                    NavigationBarItem(
                        selected = index == activeIdx,
                        onClick  = { handle?.let { MobBridge.nativeSendChangeStr(it, tab["id"] ?: "") } },
                        label    = { Text(tab["label"] ?: "") },
                        icon     = { Icon(materialIconForLogical(tab["icon"] ?: ""), contentDescription = tab["label"]) }
                    )
                }
            }
        }
    ) { innerPadding ->
        if (activeIdx < node.children.size) {
            RenderNode(node.children[activeIdx], Modifier.padding(innerPadding))
        }
    }
}

// ── Tab bar helpers ───────────────────────────────────────────────────────────

// Logical icon name → Material Icon. Mirrors the iOS sfSymbolName/2 lookup so
// the same Elixir tab declaration ("history", "qr_code", etc.) renders a
// platform-native icon on each side. Falls back to a visible Star for unknown
// names so missing mappings show up in the UI rather than failing silently.
private fun materialIconForLogical(logical: String): androidx.compose.ui.graphics.vector.ImageVector =
    when (logical) {
        "home"      -> Icons.Filled.Home
        "history"   -> Icons.Filled.History
        "list"      -> Icons.Filled.List
        "qr_code"   -> Icons.Filled.QrCode
        "link"      -> Icons.Filled.Link
        "snowflake" -> Icons.Filled.AcUnit
        "star"      -> Icons.Filled.Star
        "settings"  -> Icons.Filled.Settings
        "search"    -> Icons.Filled.Search
        "user"      -> Icons.Filled.Person
        else        -> Icons.Filled.Star
    }

private fun tabDefsProp(props: Map<String, Any?>): List<Map<String, String>> {
    return when (val raw = props["tabs"]) {
        is JSONArray -> (0 until raw.length()).map { i ->
            val obj = raw.getJSONObject(i)
            mapOf("id" to obj.optString("id"), "label" to obj.optString("label"), "icon" to obj.optString("icon"))
        }
        else -> emptyList()
    }
}

// MobNode's parser hands array-valued props through as org.json.JSONArray,
// not Kotlin List — `as? List<*>` silently fails and falls through to the
// default on every real BEAM-sent tree (see tabDefsProp above for the same
// pattern). The `is List<*>` branch stays as a fallback purely so a
// directly-constructed MobNode (e.g. an instrumentation test building props
// by hand instead of through JSON parsing) still works.
private fun sheetDetentsProp(props: Map<String, Any?>): List<Any?> =
    when (val raw = props["detents"]) {
        is JSONArray -> (0 until raw.length()).map { raw.get(it) }
        is List<*> -> raw
        else -> listOf("medium", "large")
    }
