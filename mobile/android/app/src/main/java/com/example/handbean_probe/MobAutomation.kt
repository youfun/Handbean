package com.example.handbean_probe

import android.app.Activity
import android.graphics.Bitmap
import android.os.Build
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.InputDevice
import android.view.KeyCharacterMap
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.PixelCopy
import android.view.View
import android.view.WindowInsets
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import java.io.ByteArrayOutputStream
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONArray
import org.json.JSONObject

internal object MobAutomation {
    private val mainScope = CoroutineScope(Dispatchers.Main)

    @Composable
    fun frameTrackingModifier(id: String): Modifier {
        // remember(id), deliberately: neither keyless nor keyed on anything
        // that moves per recomposition.
        //
        // Keying on the live generation, remember(currentFrameGeneration()), or
        // dropping remember and reading the counter inside
        // onGloballyPositioned, would re-read it on every recomposition or
        // every layout pass. A write could then never be stale and the gate
        // would be dead code that still looked like a fix.
        //
        // Keying on id re-runs the capture exactly when this modifier starts
        // tracking a DIFFERENT element, which is the one way a composition that
        // is still alive can end up holding a generation that was never its
        // own. Only column, row and the lazy list key their children on the
        // author's :id via mobChildKeys; everywhere else children sit in
        // positional composition slots, so a slot can be handed a different
        // node, and a different :id, while keeping its remembered state. Under
        // a keyless remember that slot would stamp writes for its new id with
        // the previous occupant's generation.
        //
        // Navigation is covered by the slot epoch, and has to be.
        //
        // This used to rest on an AnimatedContent internal: it wraps each
        // content in key(contentKey), so a changing navKey made the incoming
        // tree a fresh composition that captured the bumped generation for
        // free. MOB-146 removed AnimatedContent — building that fresh
        // composition is what cost 818ms a push — so the free part is gone.
        //
        // Without the epoch the failure is silent and delayed. The first
        // navigation still works, because the incoming slot has never held a
        // tree. The SECOND one puts a tree into a slot that still holds the
        // one from two navigations ago, Compose reuses the nodes whose id
        // matches, their remembered generation is now stale, and every frame
        // write from them is refused for ever. element_frames quietly loses
        // those ids and tap_id stops finding them, with nothing raised.
        val epoch = MobBridge.LocalSlotEpoch.current
        val generation = remember(id, epoch) { MobBridge.currentFrameGeneration() }
        return Modifier
            .testTag(id)
            .onGloballyPositioned { c ->
                val b = c.boundsInWindow()
                MobBridge.recordElementFrame(id, generation, b.left, b.top, b.width, b.height)
            }
    }

    /** JSON {id:[x,y,w,h], ...} in dp (matches screenInfo / tap_xy units). */
    fun elementFrames(frames: Map<String, FloatArray>): String {
        val density = MobBridge.activity()?.resources?.displayMetrics?.density ?: 1f
        val o = JSONObject()
        for ((id, f) in frames) {
            val arr = org.json.JSONArray()
            arr.put((f[0] / density).toDouble())
            arr.put((f[1] / density).toDouble())
            arr.put((f[2] / density).toDouble())
            arr.put((f[3] / density).toDouble())
            o.put(id, arr)
        }
        return o.toString()
    }

    /**
     * Capture the activity window in-process and return PNG/JPEG bytes.
     * Called from nif_screenshot/3 via JNI. `scale` is a multiplier of native
     * resolution (1.0 = full, 0.5 = half). Returns null when there is no live
     * window (e.g. backgrounded) so the NIF can report {:error, :no_window}.
     */
    fun screenshot(format: String, quality: Int, scale: Double): ByteArray? {
        val activity = MobBridge.activity() ?: return null
        val window = activity.window ?: return null
        val decor = window.decorView
        val w = decor.width
        val h = decor.height
        if (w <= 0 || h <= 0) return null

        val src = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val latch = java.util.concurrent.CountDownLatch(1)
        var ok = false
        val handler = android.os.Handler(android.os.Looper.getMainLooper())

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            PixelCopy.request(window, src, { result ->
                ok = result == PixelCopy.SUCCESS
                latch.countDown()
            }, handler)
        } else {
            // Pre-O fallback: draw the decor view (misses SurfaceView/GL layers).
            handler.post {
                ok =
                    try {
                        decor.draw(android.graphics.Canvas(src)); true
                    } catch (e: Throwable) {
                        false
                    }
                latch.countDown()
            }
        }

        if (!latch.await(2, java.util.concurrent.TimeUnit.SECONDS) || !ok) return null

        val bmp =
            if (scale > 0.0 && scale != 1.0) {
                Bitmap.createScaledBitmap(
                    src,
                    (w * scale).toInt().coerceAtLeast(1),
                    (h * scale).toInt().coerceAtLeast(1),
                    true
                )
            } else {
                src
            }

        val out = java.io.ByteArrayOutputStream()
        if (format == "jpeg") {
            bmp.compress(Bitmap.CompressFormat.JPEG, quality.coerceIn(0, 100), out)
        } else {
            bmp.compress(Bitmap.CompressFormat.PNG, 100, out)
        }
        return out.toByteArray()
    }

    /**
     * Read a scroll view's offset/extent as a flat JSON object (the shape
     * Mob.Test.scroll_info/2 decodes). Returns null when no scroll view is
     * registered under `id`. `kind` is "pixel" for ScrollState (px units) or
     * "index" for LazyListState (item-index units; viewport = visible items).
     */
    fun scrollInfo(id: String): String? {
        val h = MobBridge.findScrollHandle(id) ?: return null

        h.scrollState?.let { s ->
            val vp = h.viewportPx.toDouble()
            val maxV = s.maxValue.toDouble()
            val content = maxV + vp
            val off = s.value.toDouble()
            val o = JSONObject()
            if (h.horizontal) {
                o.put("offset_x", off); o.put("offset_y", 0.0)
                o.put("content_w", content); o.put("content_h", vp)
                o.put("viewport_w", vp); o.put("viewport_h", vp)
                o.put("max_x", maxV); o.put("max_y", 0.0)
            } else {
                o.put("offset_x", 0.0); o.put("offset_y", off)
                o.put("content_w", vp); o.put("content_h", content)
                o.put("viewport_w", vp); o.put("viewport_h", vp)
                o.put("max_x", 0.0); o.put("max_y", maxV)
            }
            o.put("kind", "pixel")
            return o.toString()
        }

        h.lazyState?.let { ls ->
            val li = ls.layoutInfo
            val total = li.totalItemsCount.toDouble()
            val visible = li.visibleItemsInfo.size.toDouble()
            val first = ls.firstVisibleItemIndex.toDouble()
            val maxIdx = (total - visible).coerceAtLeast(0.0)
            val o = JSONObject()
            o.put("offset_x", 0.0); o.put("offset_y", first)
            o.put("content_w", 0.0); o.put("content_h", total)
            o.put("viewport_w", 0.0); o.put("viewport_h", visible)
            o.put("max_x", 0.0); o.put("max_y", maxIdx)
            o.put("kind", "index")
            return o.toString()
        }

        return null
    }

    /**
     * Scroll the view registered under `id` to absolute (x, y). Pixel views use
     * the relevant axis; index lists use y as an item index. Runs the suspend
     * scroll on the main thread and blocks the NIF thread until it completes.
     */
    fun scrollTo(id: String, x: Double, y: Double): Boolean {
        val h = MobBridge.findScrollHandle(id) ?: return false
        val latch = java.util.concurrent.CountDownLatch(1)
        var ok = false
        mainScope.launch {
            try {
                val s = h.scrollState
                val ls = h.lazyState
                when {
                    s != null -> {
                        val target = (if (h.horizontal) x else y).toInt()
                        s.scrollTo(target.coerceIn(0, s.maxValue))
                        ok = true
                    }
                    ls != null -> {
                        ls.scrollToItem(y.toInt().coerceAtLeast(0))
                        ok = true
                    }
                }
            } catch (e: Throwable) {
                ok = false
            } finally {
                latch.countDown()
            }
        }
        latch.await(2, java.util.concurrent.TimeUnit.SECONDS)
        return ok
    }

    // ── Test-harness synthetic input ──────────────────────────────────────────
    //
    // `Mob.Test.tap_xy/3`, `type_text/2` and friends. Without these the harness
    // can drive an app by tag over distribution but cannot touch anything
    // reachable only by coordinates — a native control, a webview, a canvas.
    // Every generated app shipped without them until MOB-160.
    //
    // Injected in-process by dispatching to the decor view. The obvious route,
    // `Instrumentation.sendPointerSync`, needs INJECT_EVENTS — a signature-level
    // permission no ordinary app can hold — so it is not available to us.
    //
    // Coordinates arrive in dp, matching `elementFrames()` which divides by
    // density on the way out. They are converted to px here.

    // One synthetic gesture at a time. These arrive as `:rpc` calls, so two
    // Erlang processes can issue them concurrently; without this a tap's DOWN
    // lands in the middle of a swipe's MOVE stream, with a different downTime,
    // and both gestures are garbage while both report success.
    private val gestureMutex = kotlinx.coroutines.sync.Mutex()

    // Loaded once. `load` walks the key layout files, and these run per input.
    private val virtualKeyboard: KeyCharacterMap by lazy {
        KeyCharacterMap.load(KeyCharacterMap.VIRTUAL_KEYBOARD)
    }

    // Runs `body` on the main thread and waits for it, because the caller is a
    // BEAM scheduler thread inside a NIF and needs an answer.
    //
    // Gestures must be dispatched over REAL elapsed time, not synthesised
    // timestamps inside one main-thread block, which is why `body` suspends.
    // Android's long-press detector and Compose's drag/slop handling both wait
    // on posted callbacks and frame boundaries, so a gesture that runs to
    // completion without ever yielding the main looper is seen as a single
    // instantaneous touch: a long press reads as a tap, and a drag never
    // clears touch slop.
    private fun onMain(timeoutMs: Long = 2000, body: suspend (Activity) -> Boolean): Boolean {
        val activity = MobBridge.activity() ?: return false

        // `Dispatchers.Main` always posts, so blocking the main thread here
        // would wait on a coroutine that can only run on the thread we just
        // blocked — a guaranteed timeout and a multi-second UI freeze. A NIF
        // runs on a scheduler thread today; refuse loudly if that ever changes
        // rather than hanging the app.
        if (Looper.myLooper() == Looper.getMainLooper()) {
            Log.w("MobBridge", "synthetic input called on the main thread; refusing")
            return false
        }

        val latch = java.util.concurrent.CountDownLatch(1)
        val ok = java.util.concurrent.atomic.AtomicBoolean(false)

        val job = mainScope.launch {
            try {
                gestureMutex.withLock { ok.set(body(activity)) }
            } catch (e: Throwable) {
                Log.w("MobBridge", "synthetic input failed", e)
                ok.set(false)
            } finally {
                latch.countDown()
            }
        }

        val finished =
            try {
                latch.await(timeoutMs, java.util.concurrent.TimeUnit.MILLISECONDS)
            } catch (e: InterruptedException) {
                // Letting this propagate would unwind into JNI with a pending
                // exception, and the callers in mob_nif.zig do not
                // ExceptionCheck — the next JNI call on this thread aborts
                // the VM.
                Thread.currentThread().interrupt()
                false
            }

        if (!finished) {
            // Don't leave a gesture running against a view the caller has
            // moved on from; a retry would interleave with it. Cancellation
            // unwinds through `withPointer`, which sends the CANCEL.
            job.cancel()
            return false
        }

        return ok.get()
    }

    // Guarantees the pointer stream is closed. If an exception or a
    // cancellation lands between DOWN and UP, the view tree is left believing
    // a finger is still down, and every later touch in the session is read as
    // a second pointer — silently, since nothing reports it.
    private suspend fun withPointer(
        root: View,
        x: Float,
        y: Float,
        down: Long,
        body: suspend () -> Boolean
    ): Boolean {
        var completed = false
        try {
            val result = body()
            completed = true
            return result
        } finally {
            if (!completed) {
                motion(root, MotionEvent.ACTION_CANCEL, x, y, down, SystemClock.uptimeMillis())
            }
        }
    }

    private fun motion(root: View, action: Int, x: Float, y: Float, down: Long, at: Long): Boolean {
        val event = MotionEvent.obtain(down, at, action, x, y, 0)
        // Without this the event carries SOURCE_UNKNOWN, and the paths that
        // branch on isFromSource(SOURCE_TOUCHSCREEN) — hover, mouse-vs-touch
        // slop — take the wrong one.
        event.source = InputDevice.SOURCE_TOUCHSCREEN

        return try {
            root.dispatchTouchEvent(event)
        } finally {
            event.recycle()
        }
    }

    private fun px(activity: Activity, dp: Float): Float =
        dp * activity.resources.displayMetrics.density

    // Every one of these returns whether the events were actually CONSUMED,
    // not whether they were sent. `dispatchTouchEvent` and `dispatchKeyEvent`
    // already tell us; discarding that and returning a bare `true` would make
    // mob_nif.zig's :dispatch_failed and :no_first_responder unreachable, and
    // a tap into empty space indistinguishable from one that hit a button.

    fun tapXy(x: Float, y: Float): Boolean =
        onMain { activity ->
            val root = activity.window?.decorView
            if (root == null) {
                false
            } else {
                val cx = px(activity, x)
                val cy = px(activity, y)
                val down = SystemClock.uptimeMillis()

                withPointer(root, cx, cy, down) {
                    val pressed = motion(root, MotionEvent.ACTION_DOWN, cx, cy, down, down)
                    val released =
                        motion(root, MotionEvent.ACTION_UP, cx, cy, down, SystemClock.uptimeMillis())
                    pressed || released
                }
            }
        }

    fun longPressXy(x: Float, y: Float, durationMs: Long): Boolean =
        onMain(durationMs + 3000) { activity ->
            val root = activity.window?.decorView
            if (root == null) {
                false
            } else {
                val cx = px(activity, x)
                val cy = px(activity, y)
                val down = SystemClock.uptimeMillis()

                withPointer(root, cx, cy, down) {
                    var handled = motion(root, MotionEvent.ACTION_DOWN, cx, cy, down, down)
                    // Hold for real time, reporting the stationary finger, so
                    // the long-press timeout actually elapses on the looper.
                    var now = down
                    while (now - down < durationMs) {
                        delay(50)
                        now = SystemClock.uptimeMillis()
                        handled = motion(root, MotionEvent.ACTION_MOVE, cx, cy, down, now) || handled
                    }
                    motion(root, MotionEvent.ACTION_UP, cx, cy, down, SystemClock.uptimeMillis()) ||
                        handled
                }
            }
        }

    fun swipeXy(x1: Float, y1: Float, x2: Float, y2: Float): Boolean =
        onMain(5000) { activity ->
            val root = activity.window?.decorView
            if (root == null) {
                false
            } else {
                val sx = px(activity, x1)
                val sy = px(activity, y1)
                val ex = px(activity, x2)
                val ey = px(activity, y2)
                val down = SystemClock.uptimeMillis()
                val steps = 16

                withPointer(root, sx, sy, down) {
                    var handled = motion(root, MotionEvent.ACTION_DOWN, sx, sy, down, down)
                    // Enough intermediate points, spread over real frames, to
                    // clear touch slop and give a fling a velocity to work
                    // with. A DOWN/UP pair with nothing between reads as a tap.
                    for (step in 1..steps) {
                        delay(16)
                        val f = step.toFloat() / steps
                        handled =
                            motion(
                                root,
                                MotionEvent.ACTION_MOVE,
                                sx + (ex - sx) * f,
                                sy + (ey - sy) * f,
                                down,
                                SystemClock.uptimeMillis()
                            ) || handled
                    }
                    motion(root, MotionEvent.ACTION_UP, ex, ey, down, SystemClock.uptimeMillis()) ||
                        handled
                }
            }
        }

    fun typeText(text: String): Boolean =
        onMain { activity ->
            // Key events rather than an InputConnection: Compose's text fields
            // own their own connection, and this is the path a real keyboard
            // takes, so it exercises what the user would.
            if (activity.currentFocus == null) {
                // Nothing focused. Dispatching anyway and returning true is
                // what makes :no_first_responder unreachable.
                false
            } else {
                val events = virtualKeyboard.getEvents(text.toCharArray())
                if (events == null) {
                    // getEvents returns null if ANY character has no key
                    // sequence on the virtual keyboard — non-ASCII, emoji,
                    // accented Latin. The whole string is rejected, so the
                    // call failed; saying otherwise would report a silent
                    // no-op as a success.
                    Log.w("MobBridge", "typeText: no key sequence available (ASCII only)")
                    false
                } else {
                    var handled = false
                    for (event in events) {
                        handled = activity.dispatchKeyEvent(event) || handled
                    }
                    handled
                }
            }
        }

    fun deleteBackward(): Boolean =
        onMain { activity ->
            if (activity.currentFocus == null) false
            else sendKey(activity, KeyEvent.KEYCODE_DEL)
        }

    // `clearText` is deliberately NOT implemented.
    //
    // Two approaches were tried on a physical device and both report success
    // while failing to clear. Backspacing in a loop is dispatched far faster
    // than the text field recomposes, so the events coalesce within a frame —
    // roughly four of two hundred registered. Ctrl+A then delete does not
    // select in a Compose text field either, and removes a single character.
    //
    // A method that returns true having cleared nothing is worse than an
    // absent one: the JNI lookup is a `cacheOptional`, so an absent method
    // leaves the handle null, `Mob.Test.capabilities/1` reports
    // `clear_text: false`, and a call returns `{:error, :not_loaded}`. That is
    // the truth, and an agent can plan around it. It cannot plan around a lie.

    private fun sendKey(activity: Activity, code: Int, meta: Int = 0): Boolean {
        val t = SystemClock.uptimeMillis()
        val pressed =
            activity.dispatchKeyEvent(KeyEvent(t, t, KeyEvent.ACTION_DOWN, code, 0, meta))
        val released =
            activity.dispatchKeyEvent(
                KeyEvent(t, SystemClock.uptimeMillis(), KeyEvent.ACTION_UP, code, 0, meta)
            )
        return pressed || released
    }

    /**
     * Called from nif_safe_area via JNI — returns [top, right, bottom, left] in dp.
     * Reads the window's system bar insets on the UI thread.
     */
    fun getSafeArea(): FloatArray {
        val activity = MobBridge.activity() ?: return FloatArray(4)
        val density = activity.resources.displayMetrics.density
        val result = FloatArray(4)
        val latch = java.util.concurrent.CountDownLatch(1)
        activity.runOnUiThread {
            val insets = activity.window.decorView.rootWindowInsets
            if (insets != null) {
                result[0] = insets.systemWindowInsetTop    / density
                result[1] = insets.systemWindowInsetRight  / density
                result[2] = insets.systemWindowInsetBottom / density
                result[3] = insets.systemWindowInsetLeft   / density
            }
            latch.countDown()
        }
        try { latch.await() } catch (e: InterruptedException) { Thread.currentThread().interrupt() }
        return result
    }

    /**
     * Called from nif_screen_info via JNI. Returns
     * [width, height, density, top, bottom, left, right] in dp.
     */
    fun screenInfo(): FloatArray {
        val activity = MobBridge.activity() ?: return FloatArray(7)
        val displayMetrics = activity.resources.displayMetrics
        val density = displayMetrics.density
        val result = FloatArray(7)
        val latch = java.util.concurrent.CountDownLatch(1)
        activity.runOnUiThread {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val metrics = activity.windowManager.currentWindowMetrics
                val insets = metrics.windowInsets.getInsetsIgnoringVisibility(
                    WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout()
                )
                result[0] = metrics.bounds.width() / density
                result[1] = metrics.bounds.height() / density
                result[2] = density
                result[3] = insets.top / density
                result[4] = insets.bottom / density
                result[5] = insets.left / density
                result[6] = insets.right / density
            } else {
                val decor = activity.window.decorView
                val widthPx = decor.width.takeIf { it > 0 } ?: displayMetrics.widthPixels
                val heightPx = decor.height.takeIf { it > 0 } ?: displayMetrics.heightPixels
                result[0] = widthPx / density
                result[1] = heightPx / density
                result[2] = density

                val insets = decor.rootWindowInsets
                if (insets != null) {
                    val cutout = insets.displayCutout
                    result[3] = maxOf(insets.systemWindowInsetTop, cutout?.safeInsetTop ?: 0) / density
                    result[4] = maxOf(insets.systemWindowInsetBottom, cutout?.safeInsetBottom ?: 0) / density
                    result[5] = maxOf(insets.systemWindowInsetLeft, cutout?.safeInsetLeft ?: 0) / density
                    result[6] = maxOf(insets.systemWindowInsetRight, cutout?.safeInsetRight ?: 0) / density
                }
            }
            latch.countDown()
        }
        try { latch.await() } catch (e: InterruptedException) { Thread.currentThread().interrupt() }
        return result
    }
}
