package com.example.handbean_probe

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.view.View
import android.view.ViewGroup
import android.webkit.ValueCallback
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import java.lang.ref.WeakReference

/**
 * Independent bridgeless WebView engine.
 *
 * Not Mob.UI.webview. Never writes MobBridge.webView. Never injects
 * MobNative / window.mob. Commands are addressed by sessionId + requestId
 * + generation.
 */
object BrowserEngine {
    data class Instance(
        val sessionId: String,
        val owner: String,
        val conversationId: String,
        val generation: Int,
        val webView: WebView,
        val chrome: LinearLayout,
        val container: LinearLayout,
        var url: String = "",
        var control: String = "agent",
        var visible: Boolean = false,
        var navigating: Boolean = false,
        var currentRequestId: String? = null,
        var callerPid: Long = 0L,
    )

    private val instances = HashMap<String, Instance>()
    private var foregroundKey: String? = null
    private var overlayRoot: FrameLayout? = null
    private var activityRef: WeakReference<Activity>? = null

    fun attach(activity: Activity) {
        nativeInitClass()
        activityRef = WeakReference(activity)
        if (overlayRoot == null) {
            val root = FrameLayout(activity)
            root.visibility = View.GONE
            overlayRoot = root
            val decor = activity.window.decorView as ViewGroup
            decor.addView(
                root,
                FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT,
                ),
            )
        }
    }

    fun onActivityDestroyed(activity: Activity) {
        if (activityRef?.get() === activity) {
            overlayRoot = null
            // Sessions stay owned by OTP; Activity rebuild must remount or
            // report loss rather than returning fake success.
            instances.values.forEach { inst ->
                failPending(inst, "activity_recreated")
            }
        }
    }

    @JvmStatic
    fun create(sessionId: String, owner: String, conversationId: String, generation: Int, pid: Long) {
        runOnUi { createUnlocked(sessionId, owner, conversationId, generation, pid) }
    }

    private fun createUnlocked(sessionId: String, owner: String, conversationId: String, generation: Int, pid: Long) {
        val activity = activityRef?.get() ?: return
        destroyUnlocked(sessionId, "replaced")
        val wv = bridgelessWebView(activity, sessionId)
        val chrome = chromeBar(activity, sessionId)
        val container = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            visibility = View.INVISIBLE
            addView(chrome, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(activity, 48)))
            addView(wv, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        }
        // Non-zero hidden viewport: 360x640 off-screen, not 0x0.
        val hidden = FrameLayout.LayoutParams(dp(activity, 360), dp(activity, 640))
        hidden.leftMargin = dp(activity, 4000)
        overlayRoot?.addView(container, hidden)
        instances[key(owner, sessionId)] = Instance(
            sessionId = sessionId,
            owner = owner,
            conversationId = conversationId,
            generation = generation,
            webView = wv,
            chrome = chrome,
            container = container,
            callerPid = pid,
        )
    }

    @JvmStatic
    fun load(sessionId: String, requestId: String, generation: Int, url: String, pid: Long) {
        runOnUi {
            val inst = instance(sessionId) ?: return@runOnUi failLost(sessionId, requestId, generation, pid)
            if (inst.generation != generation) return@runOnUi
            if (!httpUrl(url)) {
                deliver(pid, sessionId, requestId, generation, error = "only http(s) URLs are allowed")
                return@runOnUi
            }
            inst.currentRequestId = requestId
            inst.callerPid = pid
            inst.navigating = true
            inst.url = url
            inst.webView.loadUrl(url)
        }
    }

    @JvmStatic
    fun eval(sessionId: String, requestId: String, generation: Int, js: String, pid: Long) {
        runOnUi {
            val inst = instance(sessionId) ?: return@runOnUi failLost(sessionId, requestId, generation, pid)
            if (inst.generation != generation) return@runOnUi
            if (inst.navigating) {
                deliver(pid, sessionId, requestId, generation, error = "navigation in progress")
                return@runOnUi
            }
            inst.currentRequestId = requestId
            inst.callerPid = pid
            inst.webView.evaluateJavascript(js) { raw ->
                if (inst.generation != generation || inst.currentRequestId != requestId) return@evaluateJavascript
                inst.currentRequestId = null
                deliver(pid, sessionId, requestId, generation, result = raw ?: "null")
            }
        }
    }

    @JvmStatic
    fun back(sessionId: String, requestId: String, generation: Int, pid: Long) {
        runOnUi {
            val inst = instance(sessionId) ?: return@runOnUi failLost(sessionId, requestId, generation, pid)
            if (inst.generation != generation) return@runOnUi
            inst.currentRequestId = requestId
            inst.callerPid = pid
            if (inst.webView.canGoBack()) {
                inst.navigating = true
                inst.webView.goBack()
            } else {
                inst.currentRequestId = null
                deliver(pid, sessionId, requestId, generation, result = "{\"action\":\"back\",\"ok\":false,\"error\":\"no history\"}")
            }
        }
    }

    @JvmStatic
    fun show(owner: String, sessionId: String, conversationId: String, url: String?, control: String) {
        runOnUi {
            if (instance(sessionId, owner) == null) {
                createUnlocked(sessionId, owner, conversationId, 1, 0L)
            }
            val inst = instance(sessionId, owner) ?: return@runOnUi
            if (foregroundKey != null && foregroundKey != key(owner, sessionId)) {
                instances[foregroundKey]?.let { hideInstance(it, destroy = false) }
            }
            inst.control = control
            inst.visible = true
            inst.container.visibility = View.VISIBLE
            inst.container.translationX = 0f
            inst.container.layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            )
            overlayRoot?.visibility = View.VISIBLE
            overlayRoot?.bringToFront()
            foregroundKey = key(owner, sessionId)
            updateChrome(inst, url)
            if (!url.isNullOrEmpty() && owner == "preview") {
                if (previewShellUrl(url, sessionId)) inst.webView.loadUrl(url)
            }
        }
    }

    @JvmStatic
    fun hide(owner: String, sessionId: String) {
        runOnUi {
            val inst = instance(sessionId, owner) ?: return@runOnUi
            hideInstance(inst, destroy = false)
            if (foregroundKey == key(owner, sessionId)) {
                overlayRoot?.visibility = View.GONE
                foregroundKey = null
            }
        }
    }

    @JvmStatic
    fun destroy(sessionId: String, generation: Int) {
        runOnUi { destroyUnlocked(sessionId, "closed", generation) }
    }

    fun handleReturn(uri: Uri, fromMainFrame: Boolean): Boolean {
        if (uri.scheme != "sigil" || uri.host != "c") return false
        if (!fromMainFrame) return false
        val conv = uri.path?.trim('/') ?: return false
        val inst = foregroundInstance() ?: return false
        if (inst.conversationId != conv) return false
        hide(inst.owner, inst.sessionId)
        return true
    }

    @JvmStatic
    fun openExternal(url: String) {
        val activity = activityRef?.get() ?: return
        if (!httpUrl(url)) return
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
        activity.startActivity(intent)
    }

    private fun hideInstance(inst: Instance, destroy: Boolean) {
        inst.visible = false
        inst.container.visibility = View.INVISIBLE
        val activity = activityRef?.get() ?: return
        inst.container.layoutParams = FrameLayout.LayoutParams(dp(activity, 360), dp(activity, 640)).apply {
            leftMargin = dp(activity, 4000)
        }
        if (destroy) destroyUnlocked(inst.sessionId, "closed", inst.generation)
    }

    private fun destroyUnlocked(sessionId: String, reason: String, generation: Int? = null) {
        val inst = instance(sessionId) ?: return
        if (generation != null && inst.generation != generation) return
        failPending(inst, reason)
        overlayRoot?.removeView(inst.container)
        inst.webView.destroy()
        instances.remove(key(inst.owner, inst.sessionId))
        if (foregroundKey == key(inst.owner, inst.sessionId)) {
            overlayRoot?.visibility = View.GONE
            foregroundKey = null
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun bridgelessWebView(activity: Activity, sessionId: String): WebView {
        return WebView(activity).apply {
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.allowFileAccess = false
            settings.allowContentAccess = false
            settings.allowFileAccessFromFileURLs = false
            settings.allowUniversalAccessFromFileURLs = false
            settings.mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            settings.javaScriptCanOpenWindowsAutomatically = false
            settings.setSupportMultipleWindows(false)
            webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                    val uri = request.url
                    if (uri.scheme == "sigil") {
                        return handleReturn(uri, request.isForMainFrame)
                    }
                    if (uri.scheme != "http" && uri.scheme != "https") return true
                    return false
                }

                override fun onPageFinished(view: WebView, pageUrl: String) {
                    val inst = instance(sessionId) ?: return
                    inst.url = pageUrl
                    inst.navigating = false
                    updateChrome(inst, pageUrl)
                    val req = inst.currentRequestId ?: return
                    inst.currentRequestId = null
                    deliver(inst.callerPid, inst.sessionId, req, inst.generation, result = "{\"action\":\"open\",\"url\":\"$pageUrl\"}", url = pageUrl)
                }

                override fun onReceivedError(view: WebView, errorCode: Int, description: String?, failingUrl: String?) {
                    val inst = instance(sessionId) ?: return
                    inst.navigating = false
                    val req = inst.currentRequestId ?: return
                    inst.currentRequestId = null
                    deliver(inst.callerPid, inst.sessionId, req, inst.generation, error = description ?: "webview error")
                }
            }
        }
    }

    private fun chromeBar(activity: Activity, sessionId: String): LinearLayout {
        val bar = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            setBackgroundColor(Color.parseColor("#1C1B1F"))
            setPadding(dp(activity, 12), dp(activity, 8), dp(activity, 12), dp(activity, 8))
        }
        val back = TextView(activity).apply {
            text = "返回聊天"
            setTextColor(Color.parseColor("#9CDCFE"))
            textSize = 14f
            setOnClickListener {
                val inst = instance(sessionId) ?: return@setOnClickListener
                hide(inst.owner, inst.sessionId)
            }
        }
        val meta = TextView(activity).apply {
            tag = "chrome-meta"
            setTextColor(Color.parseColor("#AAAAAA"))
            textSize = 12f
            setPadding(dp(activity, 12), 0, 0, 0)
        }
        val handback = TextView(activity).apply {
            tag = "chrome-handback"
            text = "交还 Agent"
            setTextColor(Color.parseColor("#9CDCFE"))
            textSize = 14f
            visibility = View.GONE
            setOnClickListener {
                val inst = instance(sessionId) ?: return@setOnClickListener
                nativeHandback(inst.sessionId, inst.callerPid)
            }
        }
        bar.addView(back)
        bar.addView(meta, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        bar.addView(handback)
        return bar
    }

    private fun updateChrome(inst: Instance, url: String?) {
        val meta = inst.chrome.findViewWithTag<TextView>("chrome-meta")
        val handback = inst.chrome.findViewWithTag<TextView>("chrome-handback")
        val status = if (inst.control == "user") "用户接管中" else "Agent 操作中"
        meta?.text = "${url ?: inst.url} · $status"
        handback?.visibility = if (inst.control == "user") View.VISIBLE else View.GONE
        inst.webView.isEnabled = inst.control == "user"
    }

    private fun previewShellUrl(url: String, previewId: String): Boolean {
        val uri = Uri.parse(url)
        if (uri.scheme != "http" && uri.scheme != "https") return false
        if (uri.host != "127.0.0.1" && uri.host != "localhost") return false
        return uri.path == "/preview/$previewId"
    }

    private fun httpUrl(url: String): Boolean {
        val uri = Uri.parse(url)
        return (uri.scheme == "http" || uri.scheme == "https") && !uri.host.isNullOrEmpty()
    }

    private fun instance(sessionId: String, owner: String? = null): Instance? {
        if (owner != null) return instances[key(owner, sessionId)]
        return instances.values.firstOrNull { it.sessionId == sessionId }
    }

    private fun foregroundInstance(): Instance? = foregroundKey?.let { instances[it] }

    private fun key(owner: String, id: String) = "$owner:$id"

    private fun failPending(inst: Instance, reason: String) {
        val req = inst.currentRequestId ?: return
        inst.currentRequestId = null
        deliver(inst.callerPid, inst.sessionId, req, inst.generation, error = reason)
    }

    private fun failLost(sessionId: String, requestId: String, generation: Int, pid: Long) {
        deliver(pid, sessionId, requestId, generation, error = "session_lost")
    }

    private fun deliver(
        pid: Long,
        sessionId: String,
        requestId: String,
        generation: Int,
        result: String? = null,
        error: String? = null,
        url: String? = null,
    ) {
        nativeDeliver(
            pid,
            sessionId.toByteArray(Charsets.UTF_8),
            requestId.toByteArray(Charsets.UTF_8),
            generation,
            result?.toByteArray(Charsets.UTF_8),
            error?.toByteArray(Charsets.UTF_8),
            url?.toByteArray(Charsets.UTF_8),
        )
    }

    private fun runOnUi(block: () -> Unit) {
        val activity = activityRef?.get()
        if (activity == null) return
        activity.runOnUiThread(block)
    }

    private fun dp(activity: Activity, value: Int): Int {
        return (value * activity.resources.displayMetrics.density).toInt()
    }

    @JvmStatic
    private external fun nativeInitClass()

    @JvmStatic
    external fun nativeDeliver(
        pid: Long,
        sessionId: ByteArray,
        requestId: ByteArray,
        generation: Int,
        result: ByteArray?,
        error: ByteArray?,
        url: ByteArray?,
    )

    @JvmStatic
    external fun nativeHandback(sessionId: String, pid: Long)

    @JvmStatic
    external fun nativeShareIntakeReady(intakeId: String, status: String)
}
