package com.example.handbean_probe.attachments

import android.app.Activity
import android.content.ActivityNotFoundException
import android.net.Uri
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import java.io.File
import java.io.IOException
import java.lang.ref.WeakReference
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

data class PhotoPickSession(
    val requestId: String,
    val generation: Int,
    val cancelled: AtomicBoolean = AtomicBoolean(false),
    val files: MutableList<File> = mutableListOf(),
)

/**
 * One Photo Picker request at a time. Per-request session lives until
 * final JNI delivery. Not a per-file request id registry.
 */
object PhotoPickerHost {
    private val io: Executor = Executors.newCachedThreadPool()
    private val lock = Any()
    private var activityRef = WeakReference<Activity>(null)
    private var visualLauncher: ActivityResultLauncher<PickVisualMediaRequest>? = null
    private var fallbackLauncher: ActivityResultLauncher<String>? = null
    private val slot = PhotoPickSlot()
    @Volatile private var session: PhotoPickSession? = null

    fun attach(
        activity: Activity,
        visual: ActivityResultLauncher<PickVisualMediaRequest>,
        fallback: ActivityResultLauncher<String>,
    ) {
        synchronized(lock) {
            activityRef = WeakReference(activity)
            visualLauncher = visual
            fallbackLauncher = fallback
        }
    }

    fun detach(activity: Activity) {
        synchronized(lock) {
            if (activityRef.get() === activity) {
                if (activity.isFinishing) {
                    cancel(slot.requestId())
                    slot.clearAfterActivityFinish()
                    session = null
                }
                activityRef = WeakReference(null)
            }
        }
    }

    fun savedRequestId(): String? = slot.requestId()

    fun savedGeneration(): Int = session?.generation ?: 1

    fun currentSession(): PhotoPickSession? = session

    fun restore(requestId: String?, restoredGeneration: Int) {
        if (requestId.isNullOrBlank()) return
        slot.restoreAccepted(requestId)
        val current = session
        if (current == null || current.requestId != requestId) {
            session = PhotoPickSession(requestId, restoredGeneration)
        }
    }

    fun launch(requestId: String, requestGeneration: Int): Boolean {
        val activity = activityRef.get() ?: return false
        if (!slot.reserve(requestId)) return false
        session = PhotoPickSession(requestId, requestGeneration)
        activity.runOnUiThread {
            val live = session
            if (live == null || live.requestId != requestId || live.cancelled.get()) {
                slot.cancel(requestId)
                deliver(requestId, requestGeneration, """{"cancelled":true}""", null)
                return@runOnUiThread
            }
            if (!slot.beginDispatch(requestId)) {
                deliver(requestId, requestGeneration, null, "picker_busy")
                return@runOnUiThread
            }
            try {
                if (ActivityResultContracts.PickVisualMedia.isPhotoPickerAvailable(activity)) {
                    visualLauncher?.launch(
                        PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly),
                    )
                } else {
                    fallbackLauncher?.launch("image/*")
                }
                slot.accepted(requestId)
            } catch (_: ActivityNotFoundException) {
                slot.finish(requestId)
                deliver(requestId, requestGeneration, null, "activity_not_found")
            } catch (_: IllegalStateException) {
                slot.finish(requestId)
                deliver(requestId, requestGeneration, null, "needs_foreground")
            } catch (_: IllegalArgumentException) {
                slot.finish(requestId)
                deliver(requestId, requestGeneration, null, "invalid_picker")
            }
        }
        return true
    }

    fun cancel(requestId: String?) {
        if (requestId.isNullOrBlank()) return
        val live = session
        if (live == null || live.requestId != requestId) return
        live.cancelled.set(true)
        synchronized(live.files) {
            live.files.forEach { it.delete() }
            live.files.clear()
        }
        slot.cancel(requestId)
    }

    fun onPicked(uris: List<Uri>) {
        val requestId = slot.requestId() ?: return
        val live = session
        if (live == null || live.requestId != requestId) {
            slot.finish(requestId)
            return
        }
        if (uris.isEmpty() || live.cancelled.get()) {
            slot.finish(requestId)
            deliver(live.requestId, live.generation, """{"cancelled":true}""", null)
            return
        }
        val activity = activityRef.get() ?: run {
            slot.finish(requestId)
            deliver(live.requestId, live.generation, null, "needs_foreground")
            return
        }
        io.execute {
            try {
                importAll(activity, live, uris.take(AttachmentLimits.MAX_COUNT))
            } catch (_: ActivityNotFoundException) {
                deliver(live.requestId, live.generation, null, "activity_not_found")
            } catch (_: IllegalArgumentException) {
                deliver(live.requestId, live.generation, null, "invalid_uri")
            } catch (_: IOException) {
                deliver(live.requestId, live.generation, null, "resolver_failed")
            } finally {
                slot.finish(live.requestId)
            }
        }
    }

    private fun importAll(
        activity: Activity,
        live: PhotoPickSession,
        uris: List<Uri>,
    ) {
        val importer = ControlledImport(
            stagingRoot = File(activity.cacheDir, "controlled_import"),
            imageRewriter = { file, mime -> ImageNormalizer.normalize(file, mime) },
        )
        val attachments = ArrayList<ImportedAttachment>()
        val errors = ArrayList<String>()
        uris.forEach { uri ->
            if (live.cancelled.get()) return@forEach
            try {
                val source = UriImportSource.fromResolver(activity, uri)
                when (val result = importer.importNow(source, "photo", live.cancelled)) {
                    is ImportResult.Ok -> {
                        val produced = File(result.attachment.controlledPath)
                        synchronized(live.files) { live.files.add(produced) }
                        attachments.add(result.attachment)
                    }
                    ImportResult.Cancelled -> {}
                    is ImportResult.Error -> errors.add(result.reason)
                }
            } catch (_: SecurityException) {
                errors.add("no_grant")
            } catch (_: IllegalArgumentException) {
                errors.add("invalid_uri")
            } catch (_: IllegalStateException) {
                errors.add("resolver_failed")
            } catch (_: IOException) {
                errors.add("resolver_failed")
            }
        }
        if (live.cancelled.get()) {
            synchronized(live.files) {
                live.files.forEach { it.delete() }
                live.files.clear()
            }
            deliver(live.requestId, live.generation, """{"cancelled":true}""", null)
            return
        }
        val json = StringBuilder()
        json.append("{\"attachments\":[")
        json.append(attachments.joinToString(",") { it.toSmallJson() })
        json.append("],\"errors\":[")
        json.append(errors.joinToString(",") { ImportedAttachment.json(it) })
        json.append("]}")
        deliver(live.requestId, live.generation, json.toString(), null)
    }

    private fun deliver(requestId: String, requestGeneration: Int, result: String?, error: String?) {
        PlatformHost.completeExternal(requestId, requestGeneration, result, error)
    }
}

class PhotoPickSlot {
    sealed class State {
        object Empty : State()
        data class Pending(val requestId: String) : State()
        data class Dispatching(val requestId: String) : State()
        data class Accepted(val requestId: String) : State()
        data class Unknown(val requestId: String) : State()
    }

    private var state: State = State.Empty

    @Synchronized
    fun reserve(requestId: String): Boolean {
        if (requestId.isBlank() || state !is State.Empty) return false
        state = State.Pending(requestId)
        return true
    }

    @Synchronized
    fun beginDispatch(requestId: String): Boolean {
        if (state != State.Pending(requestId)) return false
        state = State.Dispatching(requestId)
        return true
    }

    @Synchronized
    fun accepted(requestId: String): Boolean {
        if (state != State.Dispatching(requestId)) return false
        state = State.Accepted(requestId)
        return true
    }

    @Synchronized
    fun restoreAccepted(requestId: String) {
        if (requestId.isBlank()) return
        state = State.Accepted(requestId)
    }

    @Synchronized
    fun cancel(requestId: String): Boolean = when (state) {
        State.Pending(requestId) -> {
            state = State.Empty
            false
        }
        State.Dispatching(requestId), State.Accepted(requestId) -> {
            state = State.Unknown(requestId)
            true
        }
        else -> false
    }

    @Synchronized
    fun finish(requestId: String): String? {
        val expected = when (val current = state) {
            is State.Accepted -> current.requestId
            is State.Unknown -> current.requestId
            is State.Pending -> current.requestId
            is State.Dispatching -> current.requestId
            State.Empty -> return null
        }
        if (requestId != expected) return null
        state = State.Empty
        return expected
    }

    @Synchronized
    fun consume(callbackRequestId: String?): String? {
        if (callbackRequestId == null) return null
        return finish(callbackRequestId)
    }

    @Synchronized
    fun requestId(): String? = when (val current = state) {
        is State.Pending -> current.requestId
        is State.Dispatching -> current.requestId
        is State.Accepted -> current.requestId
        is State.Unknown -> current.requestId
        State.Empty -> null
    }

    @Synchronized
    fun clearAfterActivityFinish() {
        state = State.Empty
    }
}
