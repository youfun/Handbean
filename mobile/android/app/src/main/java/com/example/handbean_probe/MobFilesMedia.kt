package com.example.handbean_probe

import android.net.Uri
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.filled.List
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import java.io.File
import org.json.JSONArray
import org.json.JSONObject

internal object MobFilesMedia {
    // ── File picker ───────────────────────────────────────────────────────
    fun files_pick(pid: Long, typesJson: String) {
        if (HandbeanBridge.filesPick(pid, typesJson)) return
        MobBridge.pendingFilesPid = pid
        MobBridge.activity()?.let { (it as? MainActivity)?.launchFilePicker() }
            ?: MobBridge.nativeDeliverAtom2(pid, "files", "cancelled")
    }

    fun handleFilesResult(uris: List<Uri>) {
        val pid = MobBridge.pendingFilesPid
        if (uris.isEmpty()) { MobBridge.nativeDeliverAtom2(pid, "files", "cancelled"); return }
        val activity = MobBridge.activity() ?: return
        Thread {
            try {
                val items = uris.mapIndexed { i, uri ->
                    val name = uri.lastPathSegment ?: "file_$i"
                    val tmp = File(activity.cacheDir, "mob_file_${System.currentTimeMillis()}_$name")
                    activity.contentResolver.openInputStream(uri)?.use { it.copyTo(tmp.outputStream()) }
                    val size = tmp.length()
                    val mime = activity.contentResolver.getType(uri) ?: "application/octet-stream"
                    """{"path":"${tmp.absolutePath}","name":"$name","mime":"$mime","size":$size}"""
                }
                val json = "[${items.joinToString(",")}]"
                MobBridge.nativeDeliverFileResult(pid, "files", "picked", json)
            } catch (e: Exception) {
                MobBridge.nativeDeliverAtom2(pid, "files", "cancelled")
            }
        }.start()
    }


    // ── Storage ───────────────────────────────────────────────────────────
    fun storage_dir(type: String): String? {
        val ctx = MobBridge.activity() ?: return null
        return when (type) {
            "temp"        -> ctx.cacheDir.absolutePath + "/mob_temp"
            "documents"   -> ctx.filesDir.absolutePath + "/documents"
            "cache"       -> ctx.cacheDir.absolutePath
            "app_support" -> ctx.filesDir.absolutePath
            "icloud"      -> null
            else          -> null
        }.also { path -> path?.let { java.io.File(it).mkdirs() } }
    }

    fun storage_external_files_dir(type: String): String? {
        val ctx = MobBridge.activity() ?: return null
        val envType = when (type) {
            "documents"  -> android.os.Environment.DIRECTORY_DOCUMENTS
            "pictures"   -> android.os.Environment.DIRECTORY_PICTURES
            "movies"     -> android.os.Environment.DIRECTORY_MOVIES
            "music"      -> android.os.Environment.DIRECTORY_MUSIC
            "downloads"  -> android.os.Environment.DIRECTORY_DOWNLOADS
            "dcim"       -> android.os.Environment.DIRECTORY_DCIM
            else         -> android.os.Environment.DIRECTORY_DOCUMENTS
        }
        return ctx.getExternalFilesDir(envType)?.absolutePath
    }

    fun storage_save_to_media_store(pid: Long, path: String, type: String) {
        val ctx = MobBridge.activity() ?: run {
            MobBridge.nativeDeliverAtom3(pid, "storage", "error", "no_context")
            return
        }
        val file = java.io.File(path)
        val ext  = file.extension.lowercase()
        val mimeType = when {
            type == "image" || ext in listOf("jpg","jpeg","png","gif","webp","heic") -> "image/*"
            type == "video" || ext in listOf("mp4","mov","m4v","avi","mkv")          -> "video/*"
            type == "audio" || ext in listOf("m4a","mp3","aac","wav","flac","ogg")   -> "audio/*"
            else -> "*/*"
        }
        val collection = when {
            mimeType.startsWith("image") -> android.provider.MediaStore.Images.Media.getContentUri(
                android.provider.MediaStore.VOLUME_EXTERNAL_PRIMARY)
            mimeType.startsWith("video") -> android.provider.MediaStore.Video.Media.getContentUri(
                android.provider.MediaStore.VOLUME_EXTERNAL_PRIMARY)
            mimeType.startsWith("audio") -> android.provider.MediaStore.Audio.Media.getContentUri(
                android.provider.MediaStore.VOLUME_EXTERNAL_PRIMARY)
            else -> android.provider.MediaStore.Files.getContentUri(
                android.provider.MediaStore.VOLUME_EXTERNAL_PRIMARY)
        }
        try {
            val values = android.content.ContentValues().apply {
                put(android.provider.MediaStore.MediaColumns.DISPLAY_NAME, file.name)
                put(android.provider.MediaStore.MediaColumns.MIME_TYPE, mimeType)
                put(android.provider.MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = ctx.contentResolver.insert(collection, values)
                ?: throw Exception("insert returned null")
            ctx.contentResolver.openOutputStream(uri)?.use { out ->
                file.inputStream().use { it.copyTo(out) }
            }
            values.clear()
            values.put(android.provider.MediaStore.MediaColumns.IS_PENDING, 0)
            ctx.contentResolver.update(uri, values, null, null)
            val json = org.json.JSONArray().apply {
                put(org.json.JSONObject().put("path", path))
            }.toString()
            MobBridge.nativeDeliverFileResult(pid, "storage", "saved_to_library", json)
        } catch (e: Exception) {
            MobBridge.nativeDeliverAtom3(pid, "storage", "error", "save_failed")
        }
    }

    // ── Camera preview ────────────────────────────────────────────────────
    internal var previewCameraProvider: ProcessCameraProvider? = null

    fun camera_start_preview(pid: Long, optsJson: String) {
        try {
            val facing = JSONObject(optsJson).optString("facing", "back")
            _previewFacing.value = facing
        } catch (_: Exception) {}
    }

    fun camera_stop_preview() {
        _previewFacing.value = null
        previewCameraProvider?.unbindAll()
        previewCameraProvider = null
    }

    private val _previewFacing = mutableStateOf<String?>(null)
    val previewFacing: State<String?> get() = _previewFacing

}
