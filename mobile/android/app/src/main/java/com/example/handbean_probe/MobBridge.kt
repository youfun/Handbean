package com.example.handbean_probe

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.net.Uri
import android.os.Build
import android.util.Log
import android.view.HapticFeedbackConstants
import android.view.WindowManager
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import com.example.handbean_probe.MobRenderStatsCodec.FrameSample
import java.lang.ref.WeakReference
import java.util.concurrent.ConcurrentHashMap
import org.json.JSONObject

/**
 * Bridge between the BEAM and Jetpack Compose.
 *
 * The BEAM calls setRootJson(json) (via mob_nif's set_root/1) whenever the
 * screen re-renders. MutableState triggers recomposition automatically —
 * no main-thread dispatch needed for state writes.
 *
 * Tap events: Compose onClick calls nativeSendTap(handle), which routes
 * to mob_send_tap() in mob_nif.zig and sends {:tap, tag} to the registered PID.
 *
 * Sheet dismissal takes a parallel but distinct route: nativeSendDismiss ->
 * mob_send_dismiss() -> {:dismiss, tag}. That is the shape Mob.UI.sheet/2
 * documents for :on_dismiss and the one iOS sends, so it deliberately does
 * NOT reuse the tap sender (MOB-104).
 *
 * Holds the rendered tree and the nav transition to animate.
 *
 * navKey only increments on actual navigation transitions (push/pop/reset).
 * MainActivity keys the slide animation on it, and provides it as the frame
 * tracker epoch, so a same-screen BEAM re-render (transition == "none")
 * neither restarts an animation nor re-keys the trackers.
 */
data class RootState(val navKey: Int, val transition: String, val node: MobNode?)


// JNI resolves this class by its original package and name. Platform methods
// remain forwarding entry points with their original descriptors/static form;
// native declarations, root/navigation state and sampling lifecycle stay here.
// Each extracted helper has one instance/owner; this remains the only JNI facade.
object MobBridge {

    private val _rootState = mutableStateOf(RootState(0, "none", null))
    val rootState: State<RootState> get() = _rootState

    // Compose-observable theme palette pushed from `Mob.Theme.set/1` via
    // `:mob_nif.set_theme/1`. Null until the BEAM side calls Mob.Theme.set
    // for the first time; the MaterialTheme wrapper in MainActivity reads
    // this and falls back to a sensible default while it's still null.
    // Keys are the semantic token strings (`"primary"`, `"on_surface"`,
    // `"surface_raised"`, `"muted"`, …) — the same names mob's renderer
    // uses on the Elixir side. Values are ARGB longs already resolved
    // through theme.color_map / Mob.Renderer.colors so MaterialTheme can
    // call `Color(it)` directly.
    private val _themeColors = mutableStateOf<Map<String, Long>?>(null)
    val themeColors: State<Map<String, Long>?> get() = _themeColors

    // Ordered fallback font names from the last Mob.Theme.set/1 (already
    // resolved to this platform's names — see Mob.Theme.notify_native/1 in
    // mob core). Read by the top-level fontFamilyProp() when a node's own
    // font can't be loaded — not private, since that function lives outside
    // this object. Plain var, not Compose state: fonts don't need to trigger
    // recomposition the way theme colors do — they're consulted the next
    // time a font actually resolves, not reactively.
    @Volatile
    var fontFallback: List<String> = emptyList()
        private set

    /** Called from mob_nif.zig (nif_set_theme) whenever `Mob.Theme.set/1`
     *  runs on the BEAM side. The JSON is the resolved-token map: atom
     *  names → ARGB ints (e.g. `{"primary":4286331629,"surface":...}`),
     *  plus `_font_fallback` (an ordered array of font names — see
     *  MOB_FONTS.md). The Compose-state write hops to the main thread so
     *  recomposition fires safely. */
    @JvmStatic
    fun setTheme(json: String) {
        try {
            val obj = JSONObject(json)
            val map = mutableMapOf<String, Long>()
            val keys = obj.keys()
            while (keys.hasNext()) {
                val key = keys.next()
                val value = obj.opt(key)
                if (value is Number) map[key] = value.toLong()
            }

            obj.optJSONArray("_font_fallback")?.let { arr ->
                fontFallback = (0 until arr.length()).mapNotNull { arr.opt(it) as? String }
            }

            android.os.Handler(android.os.Looper.getMainLooper()).post {
                _themeColors.value = map
            }
        } catch (e: Exception) {
            android.util.Log.w("MobBridge", "setTheme failed: ${e.message}")
        }
    }

    // Event handles include a changing render generation. Stable node identity
    // wins when present; otherwise MobLazyListStateIdentity retains only the
    // stable low-byte event slot. Navigation still clears all retained state.
    private val lazyListStates = mutableMapOf<Any, LazyListState>()

    fun getOrCreateLazyListState(identity: Any): LazyListState =
        lazyListStates.getOrPut(identity) { LazyListState() }

    // ── Test harness: id-addressable scroll registry + in-process capture ──────
    //
    // Gives a remotely-connected agent (Mob.Test.screenshot/scroll_info/scroll_to)
    // pixels and deterministic scroll over Erlang dist, with no adb/xcrun. A
    // ScrollHandle carries whichever Compose scroll state backs the node plus its
    // measured viewport; the :scroll / lazy-list composables register themselves
    // here by their :id prop.
    class ScrollHandle {
        var scrollState: ScrollState? = null // pixel-precise vertical/horizontal scroll
        var lazyState: LazyListState? = null // item-indexed list
        var viewportPx: Int = 0 // measured viewport extent (for ScrollState kind)
        var horizontal: Boolean = false
    }

    // Concurrent: written from the Compose main thread (registration), read from
    // the NIF/binder thread (scrollInfo/scrollTo). computeIfAbsent keeps creation
    // atomic so a registration race can't drop a handle.
    private val scrollHandlesById = ConcurrentHashMap<String, ScrollHandle>()

    internal fun findScrollHandle(id: String): ScrollHandle? = scrollHandlesById[id]

    fun scrollHandle(id: String): ScrollHandle =
        scrollHandlesById.computeIfAbsent(id) { ScrollHandle() }

    // ── Element frame registry (positions without a screenshot) ────────────────
    private val frameRegistry = MobFrameRegistry()

    // MainActivity supplies navKey as the epoch of the composed tree. A dynamic
    // local invalidates only trackers that read it; reading rootState here would
    // subscribe every tagged node to every same-screen render. Reused slots must
    // re-capture their generation on navigation, even when their id is unchanged.
    val LocalSlotEpoch = androidx.compose.runtime.compositionLocalOf { 0 }

    fun currentFrameGeneration(): Long = frameRegistry.currentGeneration()

    fun recordElementFrame(id: String, generation: Long, x: Float, y: Float, w: Float, h: Float) =
        frameRegistry.record(id, generation, x, y, w, h)

    @Composable
    fun frameTrackingModifier(id: String): Modifier =
        MobAutomation.frameTrackingModifier(id)

    @JvmStatic
    fun elementFrames(): String =
        MobAutomation.elementFrames(frameRegistry.frames)

    @JvmStatic
    fun screenshot(format: String, quality: Int, scale: Double): ByteArray? =
        MobAutomation.screenshot(format, quality, scale)

    @JvmStatic
    fun scrollInfo(id: String): String? =
        MobAutomation.scrollInfo(id)

    @JvmStatic
    fun scrollTo(id: String, x: Double, y: Double): Boolean =
        MobAutomation.scrollTo(id, x, y)

    @JvmStatic
    fun tapXy(x: Float, y: Float): Boolean =
        MobAutomation.tapXy(x, y)

    @JvmStatic
    fun longPressXy(x: Float, y: Float, durationMs: Long): Boolean =
        MobAutomation.longPressXy(x, y, durationMs)

    @JvmStatic
    fun swipeXy(x1: Float, y1: Float, x2: Float, y2: Float): Boolean =
        MobAutomation.swipeXy(x1, y1, x2, y2)

    @JvmStatic
    fun typeText(text: String): Boolean =
        MobAutomation.typeText(text)

    @JvmStatic
    fun deleteBackward(): Boolean =
        MobAutomation.deleteBackward()

    private var activityRef: WeakReference<Activity>? = null

    @JvmStatic
    fun activity(): Activity? = activityRef?.get()

    /** Called from mob_nif.c via JNI — initialise anything activity-scoped. */
    @JvmStatic
    fun init(activity: Activity) {
        nativeInitPlatformClass()
        activityRef = WeakReference(activity)
        // Thread-local and throws off a Looper thread, so it has to be taken
        // here rather than lazily from whichever thread samples first.
        mainHandler.post { mainChoreographer = android.view.Choreographer.getInstance() }
        MobRuntimeAssets.extractOtpIfNeeded(activity)
        MobRuntimeAssets.copyMobLogos(activity)
        MobUsb.ensureUsbReceiver(activity.applicationContext)
        HandbeanBridge.onInit(activity)
    }

    // ── Handbean Probe JNI glue (resolved by name from C; keep on MobBridge) ──
    // c_src/handbean_browser.c caches `platformCommand` via GetStaticMethodID on
    // this class; beam_jni.c exports nativeCancelRuns. Bodies live in HandbeanBridge.
    @JvmStatic
    private external fun nativeInitPlatformClass()

    @JvmStatic
    fun platformCommand(requestId: String, payloadJson: String, generation: Int) =
        HandbeanBridge.platformCommand(requestId, payloadJson, generation)

    external fun nativeCancelRuns()

    /**
     * Lock the activity to an ActivityInfo.SCREEN_ORIENTATION_* constant
     * (SCREEN_ORIENTATION_UNSPECIFIED = -1 to unlock). Called from
     * mob_nif.zig's nif_device_lock_orientation via the cached orientationLock
     * JMethodID. setRequestedOrientation must run on the UI thread.
     */
    @JvmStatic
    fun orientationLock(orientation: Int) {
        val activity = activityRef?.get() ?: return
        activity.runOnUiThread {
            try {
                activity.requestedOrientation = orientation
            } catch (_: Throwable) {
            }
        }
    }

    /**
     * Keep the screen on (FLAG_KEEP_SCREEN_ON) while `on != 0`, clear it
     * otherwise. Called from mob_nif.zig's nif_device_keep_awake via the cached
     * keepAwake JMethodID. Window flags must be set on the UI thread. No
     * permission required.
     */
    @JvmStatic
    fun keepAwake(on: Int) {
        val activity = activityRef?.get() ?: return
        activity.runOnUiThread {
            if (on != 0) {
                activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            } else {
                activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
        }
    }

    /**
     * Called from nif_color_scheme via JNI. Returns "light" or "dark" based on
     * the current night-mode UI configuration. Falls back to "light" if the
     * activity is gone (shouldn't happen in practice).
     */
    @JvmStatic
    fun getColorScheme(): String {
        val activity = activityRef?.get() ?: return "light"
        val nightMode =
            activity.resources.configuration.uiMode and
                android.content.res.Configuration.UI_MODE_NIGHT_MASK
        return if (nightMode == android.content.res.Configuration.UI_MODE_NIGHT_YES) "dark"
        else "light"
    }

    /** Called from nif_exit_app via JNI — backgrounds the app without killing it. */
    @JvmStatic
    fun moveToBack() {
        activityRef?.get()?.let { activity ->
            activity.runOnUiThread { activity.moveTaskToBack(true) }
        }
    }

    /**
     * Called from MainActivity.onConfigurationChanged when uiMode flips.
     * Forwards to the BEAM via JNI so Mob.Device :appearance subscribers
     * see {:mob_device, :color_scheme_changed, :light | :dark}.
     */
    @JvmStatic
    fun notifyColorSchemeChanged(scheme: String) {
        nativeNotifyColorScheme(scheme)
    }

    /** JNI bridge — implemented in beam_jni.c. */
    @JvmStatic external fun nativeNotifyColorScheme(scheme: String)

    // ── Native frame timing (Mob.RenderStats.native_*) ───────────────────────
    //
    // `Mob.RenderStats` can already time the BEAM half of a render. It cannot
    // see the native half: `set_root_us` closes when `setRootJson` returns, and
    // this function returns as soon as it has written `_rootState` — every bit
    // of Compose's work happens after that. On a dense screen that unseen half
    // is most of the cost, which is exactly the half MOB-129 and MOB-146 argue
    // about.
    //
    // Same JSON shape as the iOS implementation, so `Mob.RenderStats` needs no
    // per-platform parsing.

    private const val RENDER_STAT_SAMPLES = 240

    private val renderStatSlots = arrayOfNulls<FrameSample>(RENDER_STAT_SAMPLES)

    // Counts every sample ever recorded, not just the retained ones, so a
    // reader can tell "240 samples, that is all there were" from "240 samples,
    // and 5000 more scrolled past" — the difference decides whether a
    // percentile over this window means anything.
    private var renderStatSeq = 0L

    // Cached rather than fetched per sample. `Choreographer.getInstance()` is
    // thread-local and throws off a Looper thread, so it is captured on the
    // main thread at init; `postFrameCallback` itself is internally locked and
    // safe to call from the NIF thread.
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

    @Volatile private var mainChoreographer: android.view.Choreographer? = null
    private val renderStatLock = Any()

    // Read on every setRootJson, written from a NIF thread. @Volatile rather
    // than lock-guarded so the disabled path — the overwhelmingly common one —
    // costs a field read and nothing else.
    @Volatile private var renderStatsOn = false

    @JvmStatic
    fun renderStatsEnable(on: Boolean): Boolean {
        // Clear when ENABLING only. Clearing on disable as well would destroy
        // the window the caller is about to read: `native_disable/0` documents
        // that recorded samples stay readable, and the natural shape is
        // enable, drive, disable, read.
        if (on) {
            synchronized(renderStatLock) {
                java.util.Arrays.fill(renderStatSlots, null)
                renderStatSeq = 0L
            }
        }
        renderStatsOn = on
        return true
    }

    @JvmStatic
    fun renderStats(): String {
        val (samples, recorded) =
            synchronized(renderStatLock) {
                Pair(renderStatSlots.filterNotNull().sortedByDescending { it.seq }, renderStatSeq)
            }

        return MobRenderStatsCodec.encode(renderStatsOn, recorded, RENDER_STAT_SAMPLES, samples)
    }

    private fun recordFrameSample(applyUs: Double, transition: String) {
        synchronized(renderStatLock) {
            renderStatSlots[(renderStatSeq % RENDER_STAT_SAMPLES).toInt()] =
                FrameSample(applyUs, renderStatSeq, transition)
            renderStatSeq++
        }
    }

    // Brackets from the state write to the end of the frame that renders it.
    //
    // The closing bracket is the hard part, and getting it wrong fails silently
    // with a plausible number. Two rejected options, recorded so nobody
    // re-derives them:
    //
    //   * A `MessageQueue.IdleHandler` is the literal analogue of the
    //     `CFRunLoopObserver(.beforeWaiting)` iOS uses. It is wrong here.
    //     Compose requests its frame through `Choreographer`, and a vsync
    //     callback arrives asynchronously rather than sitting in the queue, so
    //     between the request and the vsync the queue is genuinely empty. The
    //     handler fires there, before any of the work being measured, and
    //     reports the cost of a field write.
    //   * Posting a plain `Runnable` and registering from inside it. Same flaw
    //     for a different reason: `ViewRootImpl.scheduleTraversals` installs a
    //     sync barrier that blocks non-async messages until `doTraversal`
    //     runs. With a traversal already pending — the steady state on a busy
    //     screen, which is exactly when these measurements are taken — that
    //     post is held while Compose recomposes at frame V, so it registers
    //     for V+1 and the sample absorbs a whole extra frame. Choreographer's
    //     own vsync messages are async and sail past the barrier, which is why
    //     registering directly from this thread does not have the problem.
    //
    // So: register the frame callback straight from the calling thread.
    // `postFrameCallback` fires at the START of the next frame, before Compose
    // recomposes and before the traversal that measures, lays out and draws. A
    // message posted from inside that callback cannot run until the traversal
    // has finished, because the traversal is synchronous on that thread. That
    // post is the closing bracket.
    //
    // Biases worth knowing before trusting a tail figure, all upward:
    //
    //   * If Compose lands the recomposition in a later frame than the one we
    //     attach to, this under-reports; an animated navigation spans several
    //     frames while this measures only the first, which is the one carrying
    //     the composition cost.
    //   * A burst of `setRootJson` calls arms several brackets that all close
    //     on the SAME frame, so each attributes the cost of rendering the last
    //     tree to a tree that was superseded and never composed. Over-counting
    //     rather than losing samples, which is the safer direction for a
    //     measurement whose purpose is to justify work. iOS behaves the same.
    private fun measureApply(startNanos: Long, transition: String) {
        val choreographer = mainChoreographer ?: return
        choreographer.postFrameCallback {
            mainHandler.post {
                recordFrameSample((System.nanoTime() - startNanos) / 1000.0, transition)
            }
        }
    }

    /** Called from mob_nif.c's nif_set_root — updates Compose state. */
    @JvmStatic
    fun setRootJson(json: String, transition: String) {
        // Navigation transitions mean a genuinely different screen — old list state
        // is no longer relevant and would scroll the wrong list to a stale position.
        val newKey = if (transition != "none") {
            // Invalidate outgoing trackers before publishing the incoming tree.
            // Generation and navKey advance in this same conditional branch.
            frameRegistry.advanceNavigation()
            lazyListStates.clear()
            scrollHandlesById.clear()
            _rootState.value.navKey + 1
        } else {
            _rootState.value.navKey
        }
        // Taken AFTER the parse, deliberately. `set_root_us` on the BEAM side
        // already spans this call, parse included, because setRootJson runs
        // synchronously from the NIF — so measuring the parse here too would
        // double-count it against anyone adding the two windows together. iOS
        // has the same boundary for a different reason: its node arrives
        // already parsed.
        val measuring = renderStatsOn
        val parsed = MobJson.parseNode(json)

        // System.nanoTime rather than elapsedRealtimeNanos: the latter counts
        // deep sleep, so a run spanning a screen-off yields a sample of
        // minutes. iOS's CACurrentMediaTime does not count sleep either.
        val startNanos = if (measuring) System.nanoTime() else 0L

        _rootState.value = RootState(newKey, transition, parsed)

        if (measuring) measureApply(startNanos, transition)
    }

    /** Called from Compose onClick — routes tap back to BEAM via C. */
    @JvmStatic
    external fun nativeSendTap(handle: Int)

    /**
     * Routes a sheet dismissal back to BEAM as `{:dismiss, tag}`.
     *
     * Deliberately separate from [nativeSendTap]: `Mob.UI.sheet/2` documents
     * `:on_dismiss` as `{:dismiss, tag}` and iOS delivers that, so sending a
     * tap here produced a message no screen written to the contract matches
     * (MOB-104). Must stay declared on MobBridge — the JNI symbol is
     * `Java_<pkg>_MobBridge_nativeSendDismiss` and resolution is by declaring
     * class, not by call site.
     */
    @JvmStatic
    external fun nativeSendDismiss(handle: Int)

    /**
     * `on_long_press` / `on_double_tap`. The native senders existed all along;
     * what was missing was any Kotlin path to them, so these two were
     * registered by the renderer, carried in the JSON, and silently never fired
     * (MOB-138).
     */
    @JvmStatic
    external fun nativeSendLongPress(handle: Int)

    @JvmStatic
    external fun nativeSendDoubleTap(handle: Int)

    /**
     * Swipe. `nativeSendSwipe` carries the direction so a single handler can
     * branch on it; the four fixed-direction senders exist because iOS fires
     * both — a node may declare `on_swipe` and `on_swipe_left` at once and
     * expects each to arrive.
     */
    @JvmStatic
    external fun nativeSendSwipe(handle: Int, direction: String)

    @JvmStatic
    external fun nativeSendSwipeLeft(handle: Int)

    @JvmStatic
    external fun nativeSendSwipeRight(handle: Int)

    @JvmStatic
    external fun nativeSendSwipeUp(handle: Int)

    @JvmStatic
    external fun nativeSendSwipeDown(handle: Int)

    /**
     * Scroll. Throttling and delta-thresholding happen native-side in
     * mob_send_scroll, so Kotlin forwards every sample it observes.
     *
     * Per-handler options are honoured. `Mob.Renderer` serialises them into
     * sibling `scroll_config` / `drag_config` props, the composition reads them
     * and calls `mob_set_throttle_config`, and native applies them to the table
     * being built (MOB-134). An app asking for `throttle: 100, delta: 8` gets
     * exactly that; the built-in defaults (33ms/1.0 scroll, 16ms/1.0 drag)
     * apply only where a handler asked for nothing.
     *
     * `debounce` / `leading` / `trailing` are accepted and stored but not yet
     * acted on by either platform.
     */
    @JvmStatic
    external fun nativeSendScroll(handle: Int, x: Double, y: Double, dx: Double, dy: Double,
                                  vx: Double, vy: Double, phase: String)

    @JvmStatic
    external fun nativeSendScrollBegan(handle: Int)

    @JvmStatic
    external fun nativeSendScrollEnded(handle: Int)

    @JvmStatic
    external fun nativeSendScrollSettled(handle: Int)

    @JvmStatic
    external fun nativeSendTopReached(handle: Int)

    @JvmStatic
    external fun nativeSendScrolledPast(handle: Int)

    /**
     * Per-handle throttle/debounce config for a high-frequency event.
     *
     * Must be re-sent on every render. `clear_taps` runs at the top of each
     * frame and zeroes the per-handle throttle state — throttle_ms,
     * delta_threshold, last_emit_ns, seq — because table slots are reused
     * across renders. A config sent once would survive exactly one frame.
     */
    @JvmStatic
    external fun nativeSetThrottleConfig(handle: Int, throttleMs: Int, debounceMs: Int,
                                         deltaThreshold: Double, leading: Int, trailing: Int)

    /**
     * Drag, for `:canvas`. Coordinates are dp, matching the canvas's own
     * coordinate space (width/height props are dp) and iOS's points — Compose
     * hands the gesture raw pixels, so the caller converts before this point.
     */
    @JvmStatic
    external fun nativeSendDrag(handle: Int, x: Double, y: Double, dx: Double, dy: Double,
                                phase: String)

    /**
     * Called from Compose onChange. Convert the JVM UTF-16 string with Kotlin's
     * standard UTF-8 encoder before JNI; GetStringUTFChars would yield Modified
     * UTF-8 and corrupt non-BMP characters such as emoji.
     */
    @JvmStatic
    fun nativeSendChangeStr(handle: Int, value: String) =
        nativeSendChangeStrBytes(handle, TextChangeEncoding.utf8(value))

    @JvmStatic
    private external fun nativeSendChangeStrBytes(handle: Int, value: ByteArray)
    @JvmStatic
    external fun nativeSendChangeBool(handle: Int, value: Boolean)
    @JvmStatic
    external fun nativeSendChangeFloat(handle: Int, value: Float)

    @JvmStatic external fun nativeSendFocus(handle: Int)
    @JvmStatic external fun nativeSendBlur(handle: Int)
    @JvmStatic external fun nativeSendSubmit(handle: Int)

    /** Called from BackHandler in MainActivity when the system back gesture fires. */
    @JvmStatic external fun nativeHandleBack()

    // ── Native delivery stubs — implemented in beam_jni.c ────────────────────
    @JvmStatic external fun nativeDeliverAtom2(pid: Long, a1: String, a2: String)
    @JvmStatic external fun nativeDeliverAtom3(pid: Long, a1: String, a2: String, a3: String)
    @JvmStatic external fun nativeDeliverMotion(pid: Long, ax: Double, ay: Double, az: Double,
                                                  gx: Double, gy: Double, gz: Double, ts: Long)
    @JvmStatic external fun nativeDeliverMotionMag(pid: Long, ax: Double, ay: Double, az: Double,
                                                  gx: Double, gy: Double, gz: Double,
                                                  mx: Double, my: Double, mz: Double,
                                                  heading: Double, ts: Long)
    @JvmStatic external fun nativeDeliverFileResult(pid: Long, event: String, sub: String, json: String?)
    @JvmStatic external fun nativeDeliverPushToken(pid: Long, token: String)
    @JvmStatic external fun nativeDeliverNotification(pid: Long, json: String)
    @JvmStatic external fun nativeSetLaunchNotification(json: String?)
    @JvmStatic external fun nativeDeliverWebViewMessage(pid: Long, json: String)
    @JvmStatic external fun nativeDeliverWebViewBlocked(pid: Long, url: String)
    @JvmStatic external fun nativeDeliverAlertAction(action: String)

    // ── Pending callback PIDs ──────────────────────────────────────────────
    private val permissions = MobPermissions(::activity, ::nativeDeliverAtom3)

    var pendingPermissionPid: Long
        get() = permissions.pendingPid
        set(value) { permissions.pendingPid = value }
    var pendingPermissionCap: String
        get() = permissions.pendingCap
        set(value) { permissions.pendingCap = value }
    var pendingFilesPid: Long = 0

    // ── Permissions ────────────────────────────────────────────────────────
    @JvmStatic
    fun request_permission(pid: Long, cap: String) = permissions.request(pid, cap)

    @JvmStatic
    fun onPermissionResult(granted: Boolean) = permissions.onResult(granted)

    @JvmStatic
    fun files_pick(pid: Long, typesJson: String) =
        MobFilesMedia.files_pick(pid, typesJson)

    @JvmStatic
    fun handleFilesResult(uris: List<Uri>) =
        MobFilesMedia.handleFilesResult(uris)

    @JvmStatic
    fun audio_start_recording(pid: Long, optsJson: String) =
        MobAudio.audio_start_recording(pid, optsJson)

    @JvmStatic
    fun audio_stop_recording() =
        MobAudio.audio_stop_recording()

    @JvmStatic
    fun audio_start_input_metering() =
        MobAudio.audio_start_input_metering()

    @JvmStatic
    fun audio_input_level(): Int =
        MobAudio.audio_input_level()

    @JvmStatic
    fun audio_stop_input_metering() =
        MobAudio.audio_stop_input_metering()

    @JvmStatic
    fun audio_play(pid: Long, path: String, optsJson: String) =
        MobAudio.audio_play(pid, path, optsJson)

    @JvmStatic
    fun audio_play_at(pid: Long, path: String, optsJson: String, atWallMsStr: String) =
        MobAudio.audio_play_at(pid, path, optsJson, atWallMsStr)

    @JvmStatic
    fun audio_stop_playback() =
        MobAudio.audio_stop_playback()

    @JvmStatic
    fun audio_set_volume(volStr: String) =
        MobAudio.audio_set_volume(volStr)

    @JvmStatic
    fun storage_dir(type: String): String? =
        MobFilesMedia.storage_dir(type)

    @JvmStatic
    fun storage_external_files_dir(type: String): String? =
        MobFilesMedia.storage_external_files_dir(type)

    @JvmStatic
    fun storage_save_to_media_store(pid: Long, path: String, type: String) =
        MobFilesMedia.storage_save_to_media_store(pid, path, type)

    @JvmStatic
    fun camera_start_preview(pid: Long, optsJson: String) =
        MobFilesMedia.camera_start_preview(pid, optsJson)

    @JvmStatic
    fun camera_stop_preview() =
        MobFilesMedia.camera_stop_preview()

    internal var previewCameraProvider: ProcessCameraProvider?
        get() = MobFilesMedia.previewCameraProvider
        set(value) { MobFilesMedia.previewCameraProvider = value }

    val previewFacing: State<String?> get() = MobFilesMedia.previewFacing

    // ── Alerts / action sheets / toasts ───────────────────────────────────

    @JvmStatic
    fun alert_show(title: String, message: String, buttonsJson: String) =
        MobAlerts.show(title, message, buttonsJson)

    @JvmStatic
    fun action_sheet_show(title: String, buttonsJson: String) =
        MobAlerts.showActionSheet(title, buttonsJson)

    @JvmStatic
    fun toast_show(message: String, duration: String) =
        MobAlerts.showToast(message, duration)

    @JvmStatic
    fun webview_eval_js(code: String) =
        MobWebMotion.webview_eval_js(code)

    @JvmStatic
    fun webview_post_message(json: String) =
        MobWebMotion.webview_post_message(json)

    @JvmStatic
    fun webview_can_go_back(): Boolean =
        MobWebMotion.webview_can_go_back()

    @JvmStatic
    fun webview_go_back() =
        MobWebMotion.webview_go_back()

    @JvmStatic
    fun motion_start(pid: Long, spec: String) =
        MobWebMotion.motion_start(pid, spec)

    @JvmStatic
    fun motion_stop() =
        MobWebMotion.motion_stop()

    var webView: android.webkit.WebView?
        get() = MobWebMotion.webView
        set(value) { MobWebMotion.webView = value }

    // scanner_scan / handleScanResult moved to the mob_scanner plugin
    // (io.mob.scanner.MobScannerBridge + MobScannerActivity).


    // notify_schedule / notify_cancel / notify_register_push moved to the
    // mob_notify plugin (io.mob.notify.MobNotifyBridge); shared delivery state
    // lives in the generated io.mob.plugin.MobNotifyHub. The channel id +
    // delivery thunks/receiver stay host-side (delivery is core/host-owned).
    @JvmStatic
    fun setLaunchNotification(json: String?) {
        nativeSetLaunchNotification(json)
    }

    @JvmStatic
    fun getSafeArea(): FloatArray =
        MobAutomation.getSafeArea()

    @JvmStatic
    fun screenInfo(): FloatArray =
        MobAutomation.screenInfo()

    /** Called from nif_haptic via JNI — fires haptic feedback on the UI thread. */
    @JvmStatic
    fun haptic(type: String) {
        activityRef?.get()?.let { activity ->
            activity.runOnUiThread {
                val view     = activity.window.decorView
                val constant = when (type) {
                    "light"   -> HapticFeedbackConstants.VIRTUAL_KEY
                    "medium"  -> HapticFeedbackConstants.CLOCK_TICK
                    "heavy"   -> HapticFeedbackConstants.LONG_PRESS
                    "success" -> if (Build.VERSION.SDK_INT >= 30) HapticFeedbackConstants.CONFIRM
                                 else HapticFeedbackConstants.CLOCK_TICK
                    "error"   -> if (Build.VERSION.SDK_INT >= 30) HapticFeedbackConstants.REJECT
                                 else HapticFeedbackConstants.LONG_PRESS
                    "warning" -> HapticFeedbackConstants.CLOCK_TICK
                    else      -> HapticFeedbackConstants.VIRTUAL_KEY
                }
                @Suppress("DEPRECATION")
                view.performHapticFeedback(constant, HapticFeedbackConstants.FLAG_IGNORE_GLOBAL_SETTING)
            }
        }
    }

    /**
     * Called from nif_torch via JNI — toggles the rear-camera torch on ("on") or
     * off (any other value). Uses CameraManager.setTorchMode, so no capture
     * session and no CAMERA permission are needed. No-op on a device with no
     * flash unit, and swallows the transient failures (torch in use / camera
     * unavailable) rather than crashing the caller.
     */
    @JvmStatic
    fun torch(state: String) {
        val activity = activityRef?.get() ?: return
        val cm = activity.getSystemService(Context.CAMERA_SERVICE) as? CameraManager ?: return
        try {
            val camId = cm.cameraIdList.firstOrNull { id ->
                cm.getCameraCharacteristics(id).get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
            } ?: return
            cm.setTorchMode(camId, state == "on")
        } catch (e: Exception) {
            Log.w("MobBridge", "torch($state) failed: ${e.message}")
        }
    }

    @JvmStatic
    fun ttsSpeak(text: String, optsJson: String) =
        MobAudio.ttsSpeak(text, optsJson)

    @JvmStatic
    fun ttsStop() =
        MobAudio.ttsStop()
    /** Called from nif_clipboard_put via JNI — writes text to the system clipboard. */
    @JvmStatic
    fun clipboardPut(text: String) {
        activityRef?.get()?.let { activity ->
            activity.runOnUiThread {
                val cm = activity.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                cm.setPrimaryClip(ClipData.newPlainText("mob", text))
            }
        }
    }

    /**
     * Called from nif_clipboard_get via JNI — returns clipboard text or null.
     * Blocks the calling thread until the UI thread has read the clipboard.
     */
    @JvmStatic
    fun clipboardGet(): String? {
        val activity = activityRef?.get() ?: return null
        val result   = arrayOfNulls<String>(1)
        val latch    = java.util.concurrent.CountDownLatch(1)
        activity.runOnUiThread {
            try {
                val cm = activity.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                result[0] = cm.primaryClip?.getItemAt(0)?.coerceToText(activity)?.toString()
            } finally {
                latch.countDown()
            }
        }
        try { latch.await() } catch (e: InterruptedException) { Thread.currentThread().interrupt() }
        return result[0]
    }

    /** Called from nif_share_text via JNI — opens the system share sheet. */
    @JvmStatic
    fun shareText(text: String) {
        activityRef?.get()?.let { activity ->
            activity.runOnUiThread {
                val intent = Intent(Intent.ACTION_SEND).apply {
                    type = "text/plain"
                    putExtra(Intent.EXTRA_TEXT, text)
                }
                activity.startActivity(Intent.createChooser(intent, null))
            }
        }
    }

    /** Called from nif_open_url via JNI — hands a URL to the OS to open in the
     *  default browser/handler. Fire-and-forget; failures are silently ignored. */
    @JvmStatic
    fun openUrl(url: String) {
        activityRef?.get()?.let { activity ->
            activity.runOnUiThread {
                try {
                    val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    activity.startActivity(intent)
                } catch (e: Exception) {
                    android.util.Log.w("MobBridge", "openUrl failed for $url: ${e.message}")
                }
            }
        }
    }

    /** Called from nif_open_settings via JNI — opens an OS settings screen.
     *  target is "app" | "notifications" | "exact_alarm". Fire-and-forget;
     *  failures are silently ignored. */
    @JvmStatic
    fun openSettings(target: String) {
        activityRef?.get()?.let { activity ->
            activity.runOnUiThread {
                try {
                    val pkgUri = Uri.parse("package:" + activity.packageName)
                    val intent = when (target) {
                        "notifications" ->
                            Intent(android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                                .putExtra(
                                    android.provider.Settings.EXTRA_APP_PACKAGE,
                                    activity.packageName,
                                )
                        "exact_alarm" ->
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                                Intent(
                                    android.provider.Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM,
                                    pkgUri,
                                )
                            } else {
                                Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS, pkgUri)
                            }
                        else ->
                            Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS, pkgUri)
                    }
                    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    activity.startActivity(intent)
                } catch (e: Exception) {
                    android.util.Log.w("MobBridge", "openSettings failed for $target: ${e.message}")
                }
            }
        }
    }

    @JvmStatic
    fun audioOutputStatus(): FloatArray =
        MobAudio.audioOutputStatus()

    @JvmStatic
    fun audioOutputLevel(source: String): FloatArray =
        MobAudio.audioOutputLevel(source)
    @JvmStatic
    fun vendor_usb_list_devices(pid: Long, filterJson: String) =
        MobUsb.vendor_usb_list_devices(pid, filterJson)

    @JvmStatic
    fun vendor_usb_request_permission(pid: Long, ref: String) =
        MobUsb.vendor_usb_request_permission(pid, ref)

    @JvmStatic
    fun vendor_usb_open(pid: Long, optsJson: String) =
        MobUsb.vendor_usb_open(pid, optsJson)

    @JvmStatic
    fun vendor_usb_bulk_write(pid: Long, sessionId: Int, bytes: ByteArray, timeoutMs: Int) =
        MobUsb.vendor_usb_bulk_write(pid, sessionId, bytes, timeoutMs)

    @JvmStatic
    fun vendor_usb_start_reading(pid: Long, sessionId: Int, chunkBytes: Int) =
        MobUsb.vendor_usb_start_reading(pid, sessionId, chunkBytes)

    @JvmStatic
    fun vendor_usb_stop_reading(sessionId: Int) =
        MobUsb.vendor_usb_stop_reading(sessionId)

    @JvmStatic
    fun vendor_usb_close(sessionId: Int) =
        MobUsb.vendor_usb_close(sessionId)

    // Native callbacks — implemented in beam_jni.c → mob_deliver_vendor_usb_*.
    @JvmStatic external fun nativeDeliverVendorUsbDevices(pid: Long, json: String)
    @JvmStatic external fun nativeDeliverVendorUsbPermission(
        pid: Long, granted: Boolean, deviceJson: String)
    @JvmStatic external fun nativeDeliverVendorUsbOpened(
        pid: Long, sessionId: Int, deviceJson: String)
    @JvmStatic external fun nativeDeliverVendorUsbData(
        pid: Long, sessionId: Int, bytes: ByteArray, len: Int)
    @JvmStatic external fun nativeDeliverVendorUsbWriteComplete(
        pid: Long, sessionId: Int, bytesWritten: Int)
    @JvmStatic external fun nativeDeliverVendorUsbEvent(
        pid: Long, sessionId: Int, tag: String, reason: String)

    // Native callback for MobNativeViewRegistry's tier-2 components — see
    // beam_jni.c's Java_..._MobBridge_nativeDeliverComponentEvent. JNI
    // resolves a native method by its DECLARING class, so this must stay on
    // MobBridge (where every other nativeDeliver* callback lives) even
    // though only MobNativeViewRegistry calls it.
    @JvmStatic external fun nativeDeliverComponentEvent(handle: Int, event: String, payloadJson: String)

}

// Keep the original JVM facade for callers compiled against MobBridgeKt.
@Composable
fun RenderNode(node: MobNode, modifier: Modifier = Modifier) = MobRenderNode(node, modifier)

internal fun mobChildKeys(children: List<MobNode>): List<String> = mobRendererChildKeys(children)

@Composable
internal fun MobSheetSlot(
    node: MobNode,
    content: @Composable (MobSheetPresentationState) -> Unit
) = MobLayoutSheetSlot(node, content)
