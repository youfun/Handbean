package com.example.handbean_probe

import android.app.Activity
import android.content.pm.PackageManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat

/** Owns the platform permission callback slot; MobBridge retains the JVM entry points. */
internal class MobPermissions(
    private val activity: () -> Activity?,
    private val deliver: (Long, String, String, String) -> Unit,
) {
    var pendingPid: Long = 0
    var pendingCap: String = ""

    fun request(pid: Long, cap: String) {
        pendingPid = pid
        pendingCap = cap
        val activity = activity() ?: run {
            deliver(pid, "permission", cap, "denied"); return
        }
        val perms = when (cap) {
            "camera"        -> arrayOf(android.Manifest.permission.CAMERA)
            "microphone"    -> arrayOf(android.Manifest.permission.RECORD_AUDIO)
            "photo_library" -> if (android.os.Build.VERSION.SDK_INT >= 33)
                arrayOf(android.Manifest.permission.READ_MEDIA_IMAGES, android.Manifest.permission.READ_MEDIA_VIDEO)
            else arrayOf(android.Manifest.permission.READ_EXTERNAL_STORAGE)
            "notifications" -> if (android.os.Build.VERSION.SDK_INT >= 33)
                arrayOf(android.Manifest.permission.POST_NOTIFICATIONS)
            else { deliver(pid, "permission", "notifications", "granted"); return }
            "calendar" -> arrayOf(
                android.Manifest.permission.READ_CALENDAR,
                android.Manifest.permission.WRITE_CALENDAR,
            )
            // Plugin-supplied capabilities keep the same fallback; unknown is denied.
            else -> io.mob.plugin.MobPluginBootstrap.permissionsFor(cap)
                ?: run { deliver(pid, "permission", cap, "denied"); return }
        }
        if (perms.all { ContextCompat.checkSelfPermission(activity, it) == PackageManager.PERMISSION_GRANTED }) {
            deliver(pid, "permission", cap, "granted")
        } else {
            ActivityCompat.requestPermissions(activity, perms, REQUEST_CODE)
        }
    }

    fun onResult(granted: Boolean) {
        deliver(pendingPid, "permission", pendingCap, if (granted) "granted" else "denied")
    }

    companion object {
        const val REQUEST_CODE = 9001
    }
}
