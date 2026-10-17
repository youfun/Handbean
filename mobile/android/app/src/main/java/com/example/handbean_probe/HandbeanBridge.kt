package com.example.handbean_probe

import android.app.Activity
import android.net.Uri
import android.util.Log
import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.documentfile.provider.DocumentFile
import com.example.handbean_probe.attachments.LocalImagePreview
import com.example.handbean_probe.attachments.PlatformHost
import com.example.handbean_probe.attachments.StagingRoots
import com.example.handbean_probe.workspace.NativeFileViewer
import java.util.concurrent.Executor
import java.util.concurrent.Executors

/**
 * Handbean Probe product hooks that used to live inside the `mob_new` scaffold
 * [MobBridge]. `MobBridge` stays as close to the generated template as
 * possible and delegates here, so a Mob upgrade is a template diff rather
 * than a merge of product code.
 *
 * JNI boundary: every symbol the C side resolves by name
 * (`Java_com_example_handbean_1probe_MobBridge_*`, and `platformCommand` via
 * `GetStaticMethodID` on the `MobBridge` class in `c_src/handbean_browser.c`)
 * must remain declared on [MobBridge]. Those declarations are one-line
 * delegations into this object.
 */
object HandbeanBridge {
    private const val TAG = "HandbeanBridge"

    // ── Lifecycle ─────────────────────────────────────────────────────────

    /** Runs at the end of `MobBridge.init`, before `MainActivity.nativeStartBeam`. */
    @JvmStatic
    fun onInit(activity: Activity) {
        exposeRuntimeEnv(activity)
        PlatformHost.attach(activity)
    }

    @JvmStatic
    fun detachPlatform(activity: Activity) {
        PlatformHost.detach(activity)
    }

    @JvmStatic
    fun startMonitor(activity: Activity) {
        AgentKeepAliveService.start(activity)
    }

    private val closeBridge =
        CloseCycleRunStopBridge(cancelRuns = { MobBridge.nativeCancelRuns() })

    /** Keep close idempotent for the runs visible when the close was claimed. */
    @JvmStatic
    fun observeActiveRuns(runIds: Collection<String>) {
        closeBridge.observeActiveRuns(runIds)
    }

    /** Record close before the process goes away. Elixir may not run. */
    @JvmStatic
    fun recordClose() {
        closeBridge.recordClose()
    }

    internal fun recordClose(cancelRuns: () -> Unit) {
        closeBridge.recordClose(cancelRuns)
    }

    // ── Runtime env ───────────────────────────────────────────────────────

    /**
     * Publish the platform cache directory through the same process env the
     * BEAM launcher already uses for MOB_DATA_DIR. Set before nativeStartBeam.
     * Elixir reads MOB_CACHE_DIR; do not guess /data/data/... paths.
     */
    @JvmStatic
    fun runtimeCacheDir(activity: Activity): String = activity.cacheDir.absolutePath

    @JvmStatic
    fun controlledImportRoot(cacheDir: String): String = StagingRoots.controlledImport(cacheDir)

    private fun exposeRuntimeEnv(activity: Activity) {
        val cacheDir = runtimeCacheDir(activity)
        android.system.Os.setenv("MOB_CACHE_DIR", cacheDir, true)
        Log.i(TAG, "init: MOB_CACHE_DIR=$cacheDir")
    }

    // ── Platform commands (Elixir → Android) ──────────────────────────────

    /**
     * Commands arrive on a BEAM scheduler thread via JNI and must return at
     * once. `PlatformHost.command` only parses and dispatches (long work is
     * already async inside it), so a single worker gives FIFO dispatch —
     * a `platform_cancel` can no longer overtake the command it targets.
     */
    private val platformDispatcher = SerialCommandDispatcher()

    @JvmStatic
    fun platformCommand(requestId: String, payloadJson: String, generation: Int) {
        platformDispatcher.dispatch { PlatformHost.command(requestId, payloadJson, generation) }
    }

    // ── SAF directory import (`files_pick` with kind: "directory") ────────

    @Volatile
    var pendingWorkspaceRequestId: String? = null

    /**
     * Product branch of `MobBridge.files_pick`. Returns true when the request
     * was consumed here (cancellation or directory pick); false hands the
     * stock file-picker path back to the scaffold.
     */
    @JvmStatic
    fun filesPick(pid: Long, typesJson: String): Boolean {
        if (WorkspaceImport.isCancellation(typesJson)) {
            WorkspaceImport.requestIdFromTypes(typesJson)?.let { WorkspaceImport.cancel(it) }
            return true
        }
        if (!WorkspaceImport.isDirectoryPick(typesJson)) {
            pendingWorkspaceRequestId = null
            return false
        }
        MobBridge.pendingFilesPid = pid
        val requestId = WorkspaceImport.requestIdFromTypes(typesJson)
        pendingWorkspaceRequestId = requestId
        requestId?.let { WorkspaceImport.activeRequestId = it }
        val activity = MobBridge.activity() as? MainActivity
        if (activity != null) activity.launchDirectoryPicker()
        else MobBridge.nativeDeliverAtom2(pid, "files", "cancelled")
        return true
    }

    @JvmStatic
    fun cancelWorkspaceImport(requestId: String) {
        WorkspaceImport.cancel(requestId)
    }

    @JvmStatic
    fun handleDirectoryResult(uri: Uri?) {
        val pid = MobBridge.pendingFilesPid
        val requestId = pendingWorkspaceRequestId ?: return
        fun deliverError(reason: String) {
            MobBridge.nativeDeliverFileResult(pid, "files", "picked", WorkspaceImport.errorJson(requestId, reason))
        }
        if (uri == null) {
            deliverError("cancelled")
            WorkspaceImport.finish(requestId)
            return
        }
        val activity = MobBridge.activity() ?: run {
            deliverError("copy_failed")
            return
        }
        // A tree copy can run for minutes; it must not share the platform
        // command worker.
        Thread({
            try {
                val result = WorkspaceImport.copyTree(activity, uri, requestId)
                val dest = result.getOrElse { error ->
                    Log.e(TAG, "workspace import failed", error)
                    deliverError(when (error) {
                        is WorkspaceImport.Cancelled -> "cancelled"
                        is WorkspaceImport.TooLarge -> "too_large"
                        is WorkspaceImport.UnsafeName -> "unsafe_name"
                        else -> "copy_failed"
                    })
                    return@Thread
                }
                if (requestId != WorkspaceImport.activeRequestId || WorkspaceImport.cancelled(requestId)) {
                    dest.deleteRecursively()
                    deliverError("cancelled")
                    return@Thread
                }
                val tree = DocumentFile.fromTreeUri(activity, uri)
                val displayName = WorkspaceImport.safeName(tree?.name).getOrElse { dest.name }
                MobBridge.nativeDeliverFileResult(pid, "files", "picked", WorkspaceImport.resultJson(dest, requestId, displayName))
            } catch (e: Exception) {
                Log.e(TAG, "workspace import failed", e)
                deliverError("copy_failed")
            } finally {
                WorkspaceImport.finish(requestId)
            }
        }, "handbean-workspace-import").start()
    }

    // ── Node-tree helpers (pure; unit-tested) ─────────────────────────────

    /** Depth-first search for the node whose `id` prop equals [id]. */
    @JvmStatic
    fun findById(root: MobNode?, id: String?): MobNode? {
        if (root == null || id == null) return null
        if (root.props[BridgeIds.Props.ID] == id) return root
        return root.children.firstNotNullOfOrNull { findById(it, id) }
    }

    /**
     * `on_tap` handle of the node with [id], or null. Used to route system
     * Back / dialog dismiss through an existing Elixir tap handler instead of
     * inventing a second event.
     */
    @JvmStatic
    fun tapHandleFor(root: MobNode?, id: String?): Int? =
        (findById(root, id)?.props?.get(BridgeIds.Props.ON_TAP) as? Number)?.toInt()

    /** Fire the `on_tap` of node [id] under [root]; returns whether a handler existed. */
    @JvmStatic
    fun sendTapTo(root: MobNode?, id: String?): Boolean {
        val handle = tapHandleFor(root, id) ?: return false
        MobBridge.nativeSendTap(handle)
        return true
    }
}

internal interface AgentRunStopBridge {
    fun observeActiveRuns(runIds: Collection<String>)
    fun recordClose()
}

internal class CloseCycleRunStopBridge(
    private val cancelRuns: () -> Unit,
    private val closeGate: CloseCycleGate = CloseCycleGate(),
) : AgentRunStopBridge {
    override fun observeActiveRuns(runIds: Collection<String>) {
        closeGate.observeActiveRuns(runIds)
    }

    override fun recordClose() {
        recordClose(cancelRuns)
    }

    fun recordClose(action: () -> Unit) {
        try {
            closeGate.runOnce(action)
        } catch (_: Throwable) {
        }
    }
}

/**
 * Deduplicates close signals for one observed set of active runs. A new run id
 * opens a new close cycle; an empty update has no stable identity and therefore
 * cannot hold a permanent claim. The native action runs outside the monitor.
 */
internal class CloseCycleGate {
    private data class Claim(val runIds: Set<String>)

    private val lock = Any()
    private var activeRunIds: Set<String> = emptySet()
    private var claim: Claim? = null

    fun observeActiveRuns(runIds: Collection<String>) {
        val observed = runIds.filterTo(mutableSetOf()) { it.isNotBlank() }
        synchronized(lock) {
            val currentClaim = claim
            claim =
                when {
                    observed.isEmpty() -> null
                    currentClaim != null && observed.any { it !in currentClaim.runIds } -> null
                    else -> currentClaim
                }
            activeRunIds = observed
        }
    }

    fun runOnce(action: () -> Unit): Boolean {
        val acquired = synchronized(lock) {
            if (activeRunIds.isEmpty()) {
                null
            } else {
                if (claim != null) return false
                Claim(activeRunIds).also { claim = it }
            }
        }

        try {
            action()
            return true
        } catch (error: Throwable) {
            if (acquired != null) {
                synchronized(lock) {
                    if (claim === acquired) claim = null
                }
            }
            throw error
        }
    }
}

/**
 * Bounded, ordered replacement for `Thread { ... }.start()` per command.
 * Exceptions are logged with context and then rethrown on the worker so the
 * process-level uncaught handler still sees them (same outcome as the raw
 * thread it replaces — nothing is swallowed).
 */
internal class SerialCommandDispatcher(
    private val executor: Executor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "handbean-platform-command")
    },
    private val onError: (Throwable) -> Unit = { Log.e("HandbeanBridge", "platformCommand failed", it) },
) {
    fun dispatch(block: () -> Unit) {
        executor.execute {
            try {
                block()
            } catch (t: Throwable) {
                onError(t)
                throw t
            }
        }
    }
}

/**
 * Render-time hooks called from the scaffold composables in `MobBridge.kt`.
 * Each entry point is a single line on the scaffold side.
 */
internal object HandbeanRender {
    /** Mirrors `NativeUi.color(:surface)`; used only when Elixir sends no `background`. */
    private val surfaceFallback = Color(0xFFFAF9F7)

    /** Node types whose composable installs its own tap handling. */
    private val selfTapping = setOf(
        BridgeIds.Types.SETTINGS_SELECT,
        BridgeIds.Types.SETTINGS_BUTTON,
        BridgeIds.Types.FILE_VIEWER,
    )

    fun handlesOwnTap(type: String): Boolean = type in selfTapping

    /**
     * HomeScreen shells: approval dialog, history drawer, chat timeline.
     * Returns true when the node was fully rendered here.
     */
    @Composable
    fun renderShell(node: MobNode, m: Modifier): Boolean {
        if (boolProp(node.props, BridgeIds.Props.APPROVAL_DIALOG) == true) {
            Dialog(onDismissRequest = {
                HandbeanBridge.sendTapTo(node, BridgeIds.Elements.DISMISS_APPROVAL)
            }) {
                val configuration = LocalConfiguration.current
                val height = minOf(configuration.screenHeightDp.dp * 0.85f, 620.dp)
                Surface(
                    modifier = Modifier.width(minOf(configuration.screenWidthDp.dp * 0.9f, 480.dp)).height(height),
                    shape = RoundedCornerShape(16.dp),
                    color = colorProp(node.props, BridgeIds.Props.BACKGROUND) ?: surfaceFallback,
                ) { node.children.forEach { RenderNode(it) } }
            }
            return true
        }
        if (boolProp(node.props, BridgeIds.Props.HISTORY_SHELL) == true) {
            NativeHistoryDrawer(
                open = boolProp(node.props, BridgeIds.Props.DRAWER_OPEN) == true,
                onDismiss = {
                    HandbeanBridge.sendTapTo(node, node.props[BridgeIds.Props.BACK_TARGET] as? String)
                },
                modifier = m,
                content = { node.children.firstOrNull()?.let { RenderNode(it) } },
                drawer = { node.children.getOrNull(1)?.let { RenderNode(it) } },
            )
            return true
        }
        if (node.type == BridgeIds.Types.SCROLL && boolProp(node.props, BridgeIds.Props.CHAT_NAVIGATION) == true) {
            NativeChatScroll(node, m) { RenderNode(it) }
            return true
        }
        return false
    }

    /**
     * Text actions include their own padding. Align the actual text
     * baselines, not the padded boxes, for mixed-size label/action rows.
     */
    fun RowScope.rowChildModifier(row: MobNode, child: MobNode, base: Modifier): Modifier =
        if (row.props[BridgeIds.Props.ALIGN] == BridgeIds.Props.ALIGN_BASELINE && child.type == BridgeIds.Types.TEXT) {
            base.alignByBaseline()
        } else {
            base
        }

    /**
     * A workspace tree opts into retaining its registered scroll state while
     * a file viewer temporarily replaces it within the same screen. Real Mob
     * navigation still clears the registry in `setRootJson`. Null means "use
     * the stock per-navigation state".
     */
    @Composable
    fun retainedScrollState(node: MobNode): ScrollState? {
        val retainedId = (node.props[BridgeIds.Props.ID] as? String)
            ?.takeIf { boolProp(node.props, BridgeIds.Props.RETAIN_SCROLL) == true }
            ?: return null
        return remember(MobBridge.LocalSlotEpoch.current, retainedId) {
            MobBridge.scrollHandle(retainedId).scrollState ?: ScrollState(0)
        }
    }

    /** Follow content growth while the user is already near the bottom. */
    @Composable
    fun stickToBottom(node: MobNode, scrollState: ScrollState, horizontal: Boolean) {
        if (horizontal || boolProp(node.props, BridgeIds.Props.STICK_TO_BOTTOM) != true) return
        val id = node.props[BridgeIds.Props.ID]
        var previousMax by remember(id) { mutableStateOf(0) }
        LaunchedEffect(id, scrollState.maxValue) {
            val max = scrollState.maxValue
            if (max != Int.MAX_VALUE) {
                if (scrollState.value >= previousMax - 48) scrollState.scrollTo(max)
                previousMax = max
            }
        }
    }

    /**
     * `else` arm of the scaffold `when (node.type)`. [m] carries the stock
     * node modifier; [bare] is the incoming parent modifier without node
     * padding, for composables that lay out their own chrome.
     */
    @Composable
    fun renderCustomNode(node: MobNode, bare: Modifier, trackId: String?) {
        val tracked = if (trackId != null) bare.then(MobBridge.frameTrackingModifier(trackId)) else bare
        when (node.type) {
            BridgeIds.Types.SETTINGS_SELECT -> SettingsSelect(node, tracked)
            BridgeIds.Types.SETTINGS_BUTTON -> SettingsButton(node, tracked)
            BridgeIds.Types.FILE_VIEWER -> NativeFileViewer(node, tracked)
        }
    }

    /** Assistant Markdown via Markwon. Returns true when rendered here. */
    @Composable
    fun renderMarkdown(node: MobNode, modifier: Modifier): Boolean {
        if (boolProp(node.props, BridgeIds.Props.MARKDOWN) != true) return false
        NativeMarkdown(
            source = node.props["text"] as? String ?: "",
            modifier = modifier,
            messageId = node.props[BridgeIds.Props.ID] as? String ?: "markdown",
            streaming = boolProp(node.props, BridgeIds.Props.MARKDOWN_STREAMING) == true,
        )
        return true
    }

    @Composable
    fun selectable(node: MobNode, content: @Composable () -> Unit) {
        if (boolProp(node.props, BridgeIds.Props.SELECTABLE) == true) SelectionContainer { content() }
        else content()
    }

    /** Compact composer input. Returns true when rendered here. */
    @Composable
    fun renderPlainTextField(node: MobNode, modifier: Modifier): Boolean {
        if (node.props[BridgeIds.Props.PLAIN] != true) return false
        HandbeanTextField(node, modifier)
        return true
    }

    fun imageDescription(props: Map<String, Any?>): String? =
        (props[BridgeIds.Props.CONTENT_DESCRIPTION] as? String) ?: (props["text"] as? String)

    /**
     * Stock Coil Image can fetch http(s). Composer thumbs set local_only and
     * decode a bounded bitmap from an absolute file path only. Returns true
     * when rendered here.
     */
    @Composable
    fun renderLocalImage(node: MobNode, m: Modifier, contentScale: ContentScale): Boolean {
        if (boolProp(node.props, BridgeIds.Props.LOCAL_ONLY) != true) return false
        LocalImagePreview(
            src = node.props["src"] as? String,
            maxEdge = floatProp(node.props, BridgeIds.Props.MAX_DECODE_EDGE)?.toInt()?.coerceAtLeast(1) ?: 240,
            contentDescription = imageDescription(node.props),
            fallback = (node.props[BridgeIds.Props.FALLBACK] as? String) ?: "图片无法显示",
            contentScale = contentScale,
            modifier = m,
            uploadOnly = boolProp(node.props, BridgeIds.Props.UPLOAD_ONLY) == true,
        )
        return true
    }

    // Prop readers mirror the private helpers in MobBridge.kt (same coercions).
    private fun boolProp(props: Map<String, Any?>, key: String): Boolean? =
        when (val v = props[key]) {
            is Boolean -> v
            is String -> v == "true"
            else -> null
        }

    private fun floatProp(props: Map<String, Any?>, key: String): Float? =
        when (val v = props[key]) {
            is Double -> v.toFloat()
            is Float -> v
            is Int -> v.toFloat()
            is Long -> v.toFloat()
            else -> null
        }

    private fun colorProp(props: Map<String, Any?>, key: String): Color? =
        when (val v = props[key]) {
            is Long -> Color(v.toInt())
            is Int -> Color(v)
            is Double -> Color(v.toLong().toInt())
            else -> null
        }
}
