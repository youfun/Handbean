package com.example.handbean_probe

import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Bundle
import android.util.Log
import android.os.Build
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.core.view.WindowCompat
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.result.contract.ActivityResultContract
import android.content.Intent
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.imePadding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.onSizeChanged
import java.io.File
import java.util.ArrayList

class MainActivity : ComponentActivity() {

    companion object {
        private const val TAG = "HandbeanProbe"
        private const val SAVE_REQUEST_KEY = "sigil_pending_save_request_id"
        private const val SHARE_INTAKE_KEY = "sigil_share_intake_id"
        private const val PHOTO_REQUEST_KEY = "sigil_pending_photo_request_id"
        private const val PHOTO_GENERATION_KEY = "sigil_pending_photo_generation"
        // Activity recreation must reattach, not start a second VM in this process.
        private val beamStarted = java.util.concurrent.atomic.AtomicBoolean(false)
        // NativeUI :surface. Status/nav bars and the edge-to-edge window
        // must use this even when MaterialTheme is still on dark fallbacks.
        private val SURFACE_CREAM = 0xFFFAF9F7.toInt()
        init { System.loadLibrary("handbean_probe") }
    }

    external fun nativeSetActivity(activity: Activity)
    external fun nativeStartBeam()
    external fun nativeNotifyOrientation(orient: String)
    external fun nativeNotifyConnectivity(
        online: Boolean,
        transport: String,
        expensive: Boolean,
        validated: Boolean,
    )

    // ── Network connectivity ──────────────────────────────────────────────
    // A ConnectivityManager.NetworkCallback drives Mob.Device.network_state/0
    // and the :network subscription. registerDefaultNetworkCallback fires an
    // initial onCapabilitiesChanged, so the BEAM-side cache is seeded at start.
    private var connectivityManager: ConnectivityManager? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    private fun registerNetworkCallback() {
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return
        connectivityManager = cm
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                pushConnectivity(caps)
            }

            override fun onLost(network: Network) {
                // Don't blindly report offline: on a wifi->cellular handoff the
                // lost default's onLost can arrive after the new default has
                // settled, which would leave us stuck offline. Re-check the
                // current active network before concluding there's no path.
                val active = connectivityManager?.activeNetwork
                val caps = active?.let { connectivityManager?.getNetworkCapabilities(it) }
                pushConnectivity(caps)
            }
        }
        networkCallback = callback
        try {
            cm.registerDefaultNetworkCallback(callback)
        } catch (_: Throwable) {
        }
    }

    private fun pushConnectivity(caps: NetworkCapabilities?) {
        if (caps == null) {
            notifyConnectivitySafe(false, "none", false, false)
            return
        }
        val transport = when {
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "wired"
            else -> "other"
        }
        val expensive = !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
        // Android actively probes for real internet reachability — false on a
        // captive portal / before validation. iOS has no equivalent (:unavailable).
        val validated = caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
        notifyConnectivitySafe(true, transport, expensive, validated)
    }

    private fun notifyConnectivitySafe(
        online: Boolean,
        transport: String,
        expensive: Boolean,
        validated: Boolean,
    ) {
        try {
            nativeNotifyConnectivity(online, transport, expensive, validated)
        } catch (_: Throwable) {
        }
    }

    // ── File picker launcher ──────────────────────────────────────────────
    private val filePickerLauncher =
        registerForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
            MobBridge.handleFilesResult(uris)
        }

    private val directoryPickerLauncher =
        registerForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
            HandbeanBridge.handleDirectoryResult(uri)
        }

    fun launchFilePicker() {
        filePickerLauncher.launch(arrayOf("*/*"))
    }

    fun launchDirectoryPicker() {
        directoryPickerLauncher.launch(null)
    }

    private val photoPickerLauncher =
        registerForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(4)) { uris ->
            com.example.handbean_probe.attachments.PhotoPickerHost.onPicked(uris)
        }

    private val photoFallbackLauncher =
        registerForActivityResult(ActivityResultContracts.GetMultipleContents()) { uris ->
            com.example.handbean_probe.attachments.PhotoPickerHost.onPicked(uris.take(4))
        }

    private var pendingSaveRequestId: String? = null
    private var pendingShareIntakeId: String? = null

    private class CreateDocumentWithMime : ActivityResultContract<Pair<String, String>, android.net.Uri?>() {
        override fun createIntent(context: Context, input: Pair<String, String>): Intent =
            Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = input.second.ifBlank { "application/octet-stream" }
                putExtra(Intent.EXTRA_TITLE, input.first)
            }

        override fun parseResult(resultCode: Int, intent: Intent?): android.net.Uri? =
            if (resultCode == Activity.RESULT_OK) intent?.data else null
    }

    private val createDocumentLauncher =
        registerForActivityResult(CreateDocumentWithMime()) { uri ->
            val requestId = pendingSaveRequestId
            pendingSaveRequestId = null
            com.example.handbean_probe.attachments.PlatformHost.onCreateDocument(requestId, uri)
        }

    fun launchCreateDocument(requestId: String, name: String, mime: String) {
        pendingSaveRequestId = requestId
        createDocumentLauncher.launch(name to mime)
    }

    // ── Permission result ─────────────────────────────────────────────────
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (com.example.handbean_probe.attachments.CalendarAccess.onRequestPermissionsResult(requestCode, grantResults)) {
            return
        }
        if (requestCode == 9001) {
            val granted = grantResults.isNotEmpty() &&
                grantResults.all { it == PackageManager.PERMISSION_GRANTED }
            MobBridge.onPermissionResult(granted)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        applyLightSystemBars()
        pendingSaveRequestId = savedInstanceState?.getString(SAVE_REQUEST_KEY)
        pendingShareIntakeId = savedInstanceState?.getString(SHARE_INTAKE_KEY)
        com.example.handbean_probe.attachments.ShareIntake.scheduleRecover(filesDir)

        // This worktree installs alongside the LiveView probe, including its
        // debug BEAM distribution listener. Do not steal the original's port.
        val nodeSuffix = when {
            BuildConfig.DEVELOPER_SIDELOAD -> "developer"
            BuildConfig.FOUNDATION_TEST_APP -> "foundationtest"
            else -> "nativechat"
        }
        val distPort = when {
            BuildConfig.DEVELOPER_SIDELOAD -> "9400"
            BuildConfig.FOUNDATION_TEST_APP -> "9300"
            else -> "9200"
        }
        val httpPort = when {
            BuildConfig.DEVELOPER_SIDELOAD -> "5288"
            BuildConfig.FOUNDATION_TEST_APP -> "5188"
            else -> "5088"
        }
        android.system.Os.setenv("MOB_NODE_SUFFIX", nodeSuffix, true)
        android.system.Os.setenv("MOB_DIST_PORT", distPort, true)
        android.system.Os.setenv("HANDBEAN_HTTP_PORT", httpPort, true)

        MobBridge.init(this)
        com.example.handbean_probe.attachments.PhotoPickerHost.attach(
            this,
            photoPickerLauncher,
            photoFallbackLauncher,
        )
        savedInstanceState?.getString(PHOTO_REQUEST_KEY)?.let { photoId ->
            com.example.handbean_probe.attachments.PhotoPickerHost.restore(
                photoId,
                savedInstanceState.getInt(PHOTO_GENERATION_KEY, 1),
            )
        }
        AgentNotify.attach(this)
        AgentNotify.setAppVisible(true)
        maybeRequestNotifyPermission()
        HandbeanBridge.startMonitor(this)

        registerNetworkCallback()

        // Register activated plugins' Kotlin bridge classes (generated by
        // mob_dev at build time). Each register() caches its own jclass +
        // method IDs natively so the plugin's NIF can call into it; the
        // Activity is then handed to any bridge implementing
        // io.mob.plugin.MobActivityAware. Must run before the BEAM starts.
        io.mob.plugin.MobPluginBootstrap.registerAll(this)

        // Forward launcher-supplied env vars into the BEAM process. Set BEFORE
        // nativeStartBeam below so the BEAM (and Mob.Dist in particular) sees
        // them when it reads getenv()/System.get_env/1.
        //
        //   mob_node_suffix — appended to the configured node name
        //                     (`<app>_android` → `<app>_android_<suffix>`).
        //                     Lets multiple Android phones running the same
        //                     app coexist in Mac's shared EPMD.
        //   mob_dist_port   — Erlang dist listen port (default 9100).
        intent?.extras?.getString("mob_node_suffix")?.takeIf { it.isNotEmpty() }?.let { suffix ->
            android.system.Os.setenv("MOB_NODE_SUFFIX", suffix, true)
            Log.i(TAG, "onCreate: MOB_NODE_SUFFIX=$suffix")
        }

        intent?.extras?.getInt("mob_dist_port", -1)?.takeIf { it > 0 }?.let { port ->
            android.system.Os.setenv("MOB_DIST_PORT", port.toString(), true)
            Log.i(TAG, "onCreate: MOB_DIST_PORT=$port")
        }

        // Check if launched from a notification tap
        intent?.extras?.getString("mob_notification_json")?.let { json ->
            if (!AgentNotify.openConversation(json)) {
                MobBridge.setLaunchNotification(json)
            }
        }
        BrowserEngine.attach(this)
        maybeHandleHandbeanReturn(intent)
        dispatchShare(intent, pendingShareIntakeId, savedInstanceState != null)

        setContent {
            val state by MobBridge.rootState
            val themeColors by MobBridge.themeColors

            BackHandler(enabled = state.node != null) {
                // HomeScreen has native subpages inside one Mob route. Route
                // system Back through their existing action before exiting it.
                val target = state.node?.props?.get(BridgeIds.Props.BACK_TARGET) as? String
                if (!HandbeanBridge.sendTapTo(state.node, target)) MobBridge.nativeHandleBack()
            }

            // Material 3 chrome (NavigationBar, Button, …) pulls its colours
            // from `MaterialTheme.colorScheme`. We want those to match the
            // BEAM-side `Mob.Theme` so the system widgets don't clash with
            // mob's own primitives. `themeColors` updates via
            // `:mob_nif.set_theme/1` whenever `Mob.Theme.set(...)` runs.
            //
            // There's a brief window at launch — Compose evaluates setContent
            // before the BEAM finishes `mount/3` and pushes the first theme.
            // NativeUI is a light cream surface (#FAF9F7); falling back to
            // Material's stock dark scheme paints the whole window black until
            // the first node arrives, which looks like a hung launch.
            val colorScheme = lightColorScheme(
                primary = colorFromMap(themeColors, "primary", 0xFF1A1815),
                onPrimary = colorFromMap(themeColors, "on_primary", 0xFFFFFFFF),
                secondary = colorFromMap(themeColors, "secondary", 0xFF6B6560),
                onSecondary = colorFromMap(themeColors, "on_secondary", 0xFFFFFFFF),
                background = colorFromMap(themeColors, "background", 0xFFFAF9F7),
                onBackground = colorFromMap(themeColors, "on_background", 0xFF1A1815),
                surface = colorFromMap(themeColors, "surface", 0xFFFAF9F7),
                onSurface = colorFromMap(themeColors, "on_surface", 0xFF1A1815),
                surfaceVariant = colorFromMap(themeColors, "surface_raised", 0xFFF4F3F0),
                onSurfaceVariant = colorFromMap(themeColors, "muted", 0xFF6B6560),
                outline = colorFromMap(themeColors, "border", 0xFFE4E0DA),
                error = colorFromMap(themeColors, "error", 0xFFB42318),
                onError = colorFromMap(themeColors, "on_error", 0xFFFFFFFF),
            )

            MaterialTheme(colorScheme = colorScheme) {
                MobNavHost(state)
            }
        }

        // If the project ships embedded Python (mix mob.enable pythonx), the
        // APK contains assets/python/{stdlib,lib-dynload}/. Extract those to
        // filesDir on first launch and tell the BEAM where they landed via
        // env vars consumed by <App>.PythonPaths. Idempotent — re-launches
        // skip extraction once the marker file is present.
        extractPythonAssetsIfNeeded()

        Log.i(TAG, "onCreate — handing off to BEAM")
        nativeSetActivity(this)
        if (beamStarted.compareAndSet(false, true)) {
            Thread({
                try {
                    if (BuildConfig.DEVELOPER_SIDELOAD) prepareDeveloperRuntime()
                    nativeStartBeam()
                } catch (error: Throwable) {
                    beamStarted.set(false)
                    Log.e(TAG, "Developer runtime preparation failed; BEAM was not started", error)
                }
            }, "beam-main").start()
        }
    }

    private fun prepareDeveloperRuntime() {
        val installer = Class.forName("com.example.handbean_probe.DeveloperRuntimeInstaller")
        val install = installer.getMethod("install", Context::class.java)
        install.invoke(null, applicationContext)
    }

    private fun extractPythonAssetsIfNeeded() {
        val pythonRoot = File(filesDir, "python")
        val marker = File(pythonRoot, ".extracted")

        // libpython3.13.so is auto-extracted by the APK installer to the
        // app's nativeLibraryDir — point Pythonx.init/4 at it.
        val libPython = File(applicationInfo.nativeLibraryDir, "libpython3.13.so")

        if (libPython.exists()) {
            android.system.Os.setenv("MOB_PYTHON_DL", libPython.absolutePath, true)
        }

        // Skip extraction if no assets ship Python (project doesn't use Pythonx)
        // or if extraction has already happened.
        val assetList = try { assets.list("python") ?: emptyArray() } catch (_: Throwable) { emptyArray() }
        if (assetList.isEmpty() || marker.exists()) {
            if (pythonRoot.exists()) {
                android.system.Os.setenv("MOB_PYTHON_HOME", pythonRoot.absolutePath, true)
            }
            return
        }

        Log.i(TAG, "extractPythonAssets: extracting assets/python → ${pythonRoot.absolutePath}")
        copyAssetTree("python", pythonRoot)
        flattenLibDynload(pythonRoot)
        marker.createNewFile()
        android.system.Os.setenv("MOB_PYTHON_HOME", pythonRoot.absolutePath, true)
        Log.i(TAG, "extractPythonAssets: done")
    }

    // Chaquopy ships lib-dynload/<abi>/*.so per architecture; CPython expects
    // them flat in lib-dynload/. Move the device's primary-abi `.so` files
    // up one level and discard the rest.
    private fun flattenLibDynload(pythonRoot: File) {
        val libDynload = File(pythonRoot, "lib/python3.13/lib-dynload")
        if (!libDynload.isDirectory) return

        val deviceAbi = android.os.Build.SUPPORTED_ABIS.firstOrNull() ?: return
        val abiDir = File(libDynload, deviceAbi)
        if (!abiDir.isDirectory) return

        abiDir.listFiles()?.forEach { src ->
            val dst = File(libDynload, src.name)
            if (!dst.exists()) src.renameTo(dst)
        }
        // Drop the other-abi dirs to free space.
        libDynload.listFiles { f -> f.isDirectory }?.forEach { it.deleteRecursively() }
    }

    private fun copyAssetTree(srcPath: String, destDir: File) {
        val children = assets.list(srcPath) ?: emptyArray()

        if (children.isEmpty()) {
            // Leaf: copy the file
            destDir.parentFile?.mkdirs()
            assets.open(srcPath).use { input ->
                destDir.outputStream().use { output -> input.copyTo(output) }
            }
            return
        }

        destDir.mkdirs()
        for (child in children) {
            copyAssetTree("$srcPath/$child", File(destDir, child))
        }
    }

    // Called when a notification is tapped and the activity already exists at
    // the top of the stack (singleTop launch mode). If BEAM is running, deliver
    // the notification directly; otherwise store it for delivery on boot.
    override fun onStart() {
        super.onStart()
        AgentNotify.setAppVisible(true)
    }

    override fun onStop() {
        AgentNotify.setAppVisible(false)
        super.onStop()
    }

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        maybeHandleHandbeanReturn(intent)
        dispatchShare(intent, null, false)
        intent.extras?.getString("mob_notification_json")?.let { json ->
            val pid = io.mob.plugin.MobNotifyHub.notifyPid
            if (pid != 0L) {
                MobBridge.nativeDeliverNotification(pid, json)
            } else if (!AgentNotify.openConversation(json)) {
                MobBridge.setLaunchNotification(json)
            }
        }
    }

    // Manifest declares `android:configChanges` including `uiMode`, so a
    // dark/light toggle delivers here instead of recreating the activity.
    // Forward to MobBridge so Mob.Device :appearance subscribers can react
    // (e.g. re-resolve Mob.Theme.Adaptive without an app restart).
    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        val nightMode = newConfig.uiMode and Configuration.UI_MODE_NIGHT_MASK
        val scheme = if (nightMode == Configuration.UI_MODE_NIGHT_YES) "dark" else "light"
        MobBridge.notifyColorSchemeChanged(scheme)

        // Forward the new orientation to the BEAM so Mob.Device.orientation/0 and
        // the :display subscription reflect a rotation (mob_send_orientation_changed).
        val orient = when (display?.rotation) {
            android.view.Surface.ROTATION_90 -> "landscape_left"
            android.view.Surface.ROTATION_270 -> "landscape_right"
            android.view.Surface.ROTATION_180 -> "portrait_upside_down"
            else -> "portrait"
        }
        try {
            nativeNotifyOrientation(orient)
        } catch (_: Throwable) {
        }
    }

    /**
     * Every SEND/SEND_MULTIPLE enters ShareIntake. Manifest is the source of
     * truth; saved-state ID is only for same-process resume. Missing ID must
     * not swallow the Intent.
     */
    private fun dispatchShare(
        intent: android.content.Intent?,
        savedIntakeId: String?,
        recreate: Boolean,
    ) {
        val current = intent ?: return
        if (!com.example.handbean_probe.attachments.ShareIntentParser.isShare(current)) return
        pendingShareIntakeId =
            com.example.handbean_probe.attachments.ShareIntake.submit(
                this,
                current,
                savedIntakeId,
                recreate,
            ) ?: pendingShareIntakeId
    }

    private fun maybeHandleHandbeanReturn(intent: android.content.Intent?) {
        val uri = intent?.data ?: return
        if (uri.scheme == "sigil") {
            BrowserEngine.handleReturn(uri, true)
        }
    }

    private fun maybeRequestNotifyPermission() {
        if (android.os.Build.VERSION.SDK_INT < 33) return
        if (
            checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 9002)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putString(SAVE_REQUEST_KEY, pendingSaveRequestId)
        outState.putString(SHARE_INTAKE_KEY, pendingShareIntakeId)
        outState.putString(
            PHOTO_REQUEST_KEY,
            com.example.handbean_probe.attachments.PhotoPickerHost.savedRequestId(),
        )
        outState.putInt(
            PHOTO_GENERATION_KEY,
            com.example.handbean_probe.attachments.PhotoPickerHost.savedGeneration(),
        )
        super.onSaveInstanceState(outState)
    }

    override fun onDestroy() {
        com.example.handbean_probe.attachments.PhotoPickerHost.detach(this)
        HandbeanBridge.detachPlatform(this)
        BrowserEngine.onActivityDestroyed(this)
        if (!AgentKeepAliveService.isRunning()) {
            try {
                HandbeanBridge.recordClose()
            } catch (_: Throwable) {
            }
        }
        super.onDestroy()
        val cm = connectivityManager
        val cb = networkCallback
        if (cm != null && cb != null) {
            try {
                cm.unregisterNetworkCallback(cb)
            } catch (_: Throwable) {
            }
        }
    }

    // Pulls an ARGB long out of the BEAM-pushed theme map, falling back to
    // a Material 3 stock dark value when the key isn't present (e.g. a
    // custom theme that doesn't define every Material 3 slot).
    private fun applyLightSystemBars() {
        // NativeUI is always cream. Do not use enableEdgeToEdge(): on this
        // Android 16 OEM it leaves an opaque black status strip even with
        // SystemBarStyle.light. The theme opts out of edge-to-edge
        // enforcement so these colors stick.
        window.addFlags(WindowManager.LayoutParams.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS)
        window.statusBarColor = SURFACE_CREAM
        window.navigationBarColor = SURFACE_CREAM
        WindowCompat.setDecorFitsSystemWindows(window, true)
        WindowCompat.getInsetsController(window, window.decorView).apply {
            isAppearanceLightStatusBars = true
            isAppearanceLightNavigationBars = true
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.isStatusBarContrastEnforced = false
            window.isNavigationBarContrastEnforced = false
        }
    }

    private fun colorFromMap(map: Map<String, Long>?, key: String, fallback: Long): Color =
        Color(map?.get(key) ?: fallback)
}

// ── Identity-preserving screen presentation (MOB-146) ──────────────────────
//
// Navigation used to render through `AnimatedContent(contentKey = { navKey })`.
// AnimatedContent wraps each content in `key(contentKey)`, so a changing key
// disposes the outgoing composition and builds the incoming one from nothing —
// structurally the same thing `.id(currentNavVersion)` did on iOS before
// MOB-129. Measured on a 1600-node screen, physical moto g power: a push cost
// 818ms against a 221ms steady-state re-render.
//
// So navigation no longer changes identity. One mount point sits at a fixed
// structural position — that position IS its identity, and no key is used — and
// a navigation simply replaces the tree inside it. Compose then diffs the new
// tree against the one already mounted, which is what a re-render of the same
// screen has always done; the difference between a "navigation" and a
// "re-render" stops being a difference in kind and becomes a difference in how
// many nodes changed.
//
// The slide is driven by an animated offset on that mount point rather than by
// an enter/exit transition, because those only fire on insert/remove and
// insert/remove is precisely what costs the time.
//
// **Why one mount point and not two.** iOS uses two slots and keeps the
// outgoing tree parked, which buys depth-1 retention: popping back diffs
// against the screen still sitting in the other slot. That does not transfer.
// Measured here, a parked Compose subtree recomposes on every render of the
// active screen — 6 recompositions of the parked node across 6 re-renders —
// which took a steady-state re-render from 151ms to 273ms. Re-renders are far
// more frequent than navigations, so retention cost more than it saved. One
// slot keeps the whole win of identity preservation and none of that.
//
// The visible trade is that the outgoing screen does not slide out
// simultaneously; the incoming one slides in over the background. See mob's
// decisions/2026-09-04-two-slot-screen-presentation.md for the iOS original.
@Composable
private fun MobNavHost(state: RootState) {
    var containerWidth by remember { mutableIntStateOf(0) }
    val offset = remember { Animatable(0f) }

    // Keyed on navKey, NOT on `state`.
    //
    // `LaunchedEffect` cancels its coroutine when the key changes, and `state`
    // is a new RootState on every render. Keying on it meant any re-render
    // arriving during the 300ms slide — a timer, an async mount, a
    // subscription — cancelled `animateTo` and left the offset frozen wherever
    // it had reached. The screen stayed parked off-canvas and the app rendered
    // BLANK, while the BEAM went on reporting the correct screen and assigns:
    // an agent driving over dist would see nothing wrong. Reproduced on device
    // by sending one re-render 100ms after a navigation.
    //
    // navKey changes only on a real navigation, so an ordinary re-render
    // cannot cancel the slide, and a second navigation correctly interrupts
    // and restarts it.
    LaunchedEffect(state.navKey) {
        // Recovery first, before any early exit: an interrupted slide must not
        // be able to leave the screen displaced just because the width is not
        // known yet.
        if (containerWidth <= 0) {
            offset.snapTo(0f)
            return@LaunchedEffect
        }

        val width = containerWidth.toFloat()
        val from = when (state.transition) {
            "push" -> width
            "pop" -> -width
            else -> 0f
        }

        if (from == 0f) {
            // No slide for a reset or a first mount, but the offset still has
            // to be returned to rest in case a previous slide was interrupted.
            offset.snapTo(0f)
        } else {
            offset.snapTo(from)
            offset.animateTo(0f, tween(durationMillis = 300))
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            // Painted, not inherited. Only one screen is mounted now, so the
            // strip the incoming screen has not covered yet shows whatever is
            // behind the composition — and that is the window background,
            // hardcoded black in styles.xml. Without this a light-themed app
            // gets a black wedge sweeping across it for the whole slide.
            .background(Color(0xFFFAF9F7))
            // Clips drawing AND hit-testing to the container, so a screen
            // parked off-screen mid-slide cannot be tapped.
            .clipToBounds()
            .onSizeChanged { containerWidth = it.width }
    ) {
        // `graphicsLayer`, not `offset`. Both read the animating value in a
        // lambda, so neither recomposes the tree per frame — but
        // `Modifier.offset {}` is a layout modifier, so every frame of the
        // slide re-runs the placement pass down through 1600 mounted nodes.
        // A layer translation moves the same pixels in the draw phase with no
        // layout invalidation at all, which on a performance ticket is the
        // difference worth having.
        Box(Modifier.fillMaxSize().graphicsLayer { translationX = offset.value }) {
            // Rendered straight from `state`, exactly as the AnimatedContent
            // version was. Routing it through a state variable set by a
            // LaunchedEffect would leave the first frame after every set_root
            // showing nothing, because effects run after composition.
            state.node?.let { node ->
                // navKey IS the epoch, and needs to be nothing more.
                //
                // The frame-registry gate has each tracked node remember the
                // generation current when it first composed, and refuses
                // writes stamped older than the current one. That used to work
                // for free: AnimatedContent made the incoming tree a fresh
                // composition, so it always captured the bumped value. With
                // the mount point preserved it is not free — nodes Compose
                // reuses across a navigation keep the generation they captured
                // for the PREVIOUS screen, which setRootJson has just
                // superseded, and their frame writes would be refused for
                // ever. element_frames would quietly lose those ids and tap_id
                // would stop finding them, with nothing raised.
                //
                // navKey moves on exactly the right events — every non-"none"
                // transition and nothing else — so re-keying the trackers on
                // it re-captures the generation on navigation and leaves a
                // same-screen re-render alone. Providing it through a
                // CompositionLocal is what keeps trackers from reading the
                // root state directly, which would resubscribe every tagged
                // node to every root update.
                CompositionLocalProvider(MobBridge.LocalSlotEpoch provides state.navKey) {
                    RenderNode(node, modifier = Modifier.fillMaxSize().imePadding())
                }
            }
        }
    }
}
