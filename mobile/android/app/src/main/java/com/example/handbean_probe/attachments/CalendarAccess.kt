package com.example.handbean_probe.attachments

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import androidx.core.app.ActivityCompat
import java.util.ArrayDeque

/**
 * Runtime READ/WRITE_CALENDAR grant, independent of Mob.Permissions.
 *
 * The dialog result is delivered to every waiter, including a platform command
 * that is not the HomeScreen. Already-granted calls complete immediately.
 * A missing or finishing activity denies rather than hanging.
 */
object CalendarAccess {
    const val REQUEST_CODE = 4701

    private val lock = Any()
    private val waiters = ArrayDeque<(Boolean) -> Unit>()
    @Volatile private var requesting = false

    fun ensure(activity: Activity, onResult: (Boolean) -> Unit) {
        if (DeviceCalendar.granted(activity)) {
            onResult(true)
            return
        }
        val start = synchronized(lock) {
            waiters.add(onResult)
            if (requesting) {
                false
            } else {
                requesting = true
                true
            }
        }
        if (!start) return
        activity.runOnUiThread {
            if (activity.isFinishing) {
                complete(false)
                return@runOnUiThread
            }
            ActivityCompat.requestPermissions(
                activity,
                arrayOf(Manifest.permission.READ_CALENDAR, Manifest.permission.WRITE_CALENDAR),
                REQUEST_CODE,
            )
        }
    }

    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val granted = grantResults.isNotEmpty() &&
            grantResults.all { it == PackageManager.PERMISSION_GRANTED }
        complete(granted)
        return true
    }

    private fun complete(granted: Boolean) {
        val pending = synchronized(lock) {
            requesting = false
            val copy = waiters.toList()
            waiters.clear()
            copy
        }
        pending.forEach { it(granted) }
    }
}
