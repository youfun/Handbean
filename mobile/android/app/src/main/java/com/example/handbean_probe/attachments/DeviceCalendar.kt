package com.example.handbean_probe.attachments

import android.Manifest
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.provider.CalendarContract
import androidx.core.content.ContextCompat
import org.json.JSONArray
import org.json.JSONObject

/**
 * System calendar through CalendarContract.
 *
 * Reads and inserts happen in-process after READ/WRITE_CALENDAR. An authorized
 * insert does not open the calendar app. Callers must already hold both
 * permissions; this object does not request them.
 */
object DeviceCalendar {
    private const val MAX_EVENTS = 50
    private const val MAX_CALENDARS = 20

    fun granted(context: Context): Boolean {
        return readGranted(context) && writeGranted(context)
    }

    fun readGranted(context: Context): Boolean {
        return ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CALENDAR) ==
            PackageManager.PERMISSION_GRANTED
    }

    fun writeGranted(context: Context): Boolean {
        return ContextCompat.checkSelfPermission(context, Manifest.permission.WRITE_CALENDAR) ==
            PackageManager.PERMISSION_GRANTED
    }

    fun listCalendars(context: Context): JSONObject {
        val calendars = JSONArray()
        val projection = arrayOf(
            CalendarContract.Calendars._ID,
            CalendarContract.Calendars.CALENDAR_DISPLAY_NAME,
            CalendarContract.Calendars.ACCOUNT_NAME,
            CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL,
            CalendarContract.Calendars.IS_PRIMARY,
        )
        context.contentResolver.query(
            CalendarContract.Calendars.CONTENT_URI,
            projection,
            null,
            null,
            "${CalendarContract.Calendars.IS_PRIMARY} DESC",
        )?.use { cursor ->
            val idIdx = cursor.getColumnIndex(CalendarContract.Calendars._ID)
            val nameIdx = cursor.getColumnIndex(CalendarContract.Calendars.CALENDAR_DISPLAY_NAME)
            val accountIdx = cursor.getColumnIndex(CalendarContract.Calendars.ACCOUNT_NAME)
            val accessIdx = cursor.getColumnIndex(CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL)
            val primaryIdx = cursor.getColumnIndex(CalendarContract.Calendars.IS_PRIMARY)
            while (cursor.moveToNext() && calendars.length() < MAX_CALENDARS) {
                val access = if (accessIdx >= 0) cursor.getInt(accessIdx) else 0
                if (access < CalendarContract.Calendars.CAL_ACCESS_CONTRIBUTOR) continue
                calendars.put(
                    JSONObject()
                        .put("id", cursor.getLong(idIdx).toString())
                        .put("name", if (nameIdx >= 0) cursor.getString(nameIdx) ?: "" else "")
                        .put("account", if (accountIdx >= 0) cursor.getString(accountIdx) ?: "" else "")
                        .put("writable", true)
                        .put("primary", primaryIdx >= 0 && cursor.getInt(primaryIdx) == 1),
                )
            }
        }
        return JSONObject().put("outcome", "listed").put("calendars", calendars)
    }

    fun listEvents(context: Context, payload: JSONObject): JSONObject {
        val start = payload.optLong("start_ms", System.currentTimeMillis())
        val end = payload.optLong("end_ms", start + 7L * 86_400_000L)
        if (end <= start) throw IllegalArgumentException("invalid_time")
        val limit = payload.optInt("limit", 20).coerceIn(1, MAX_EVENTS)
        val calendarId = payload.optString("calendar_id").ifBlank { null }
        val query = payload.optString("query").trim().ifBlank { null }

        val selection = buildString {
            append("${CalendarContract.Events.DTSTART} < ? AND ${CalendarContract.Events.DTEND} > ?")
            append(" AND ${CalendarContract.Events.DELETED} = 0")
            if (calendarId != null) append(" AND ${CalendarContract.Events.CALENDAR_ID} = ?")
            if (query != null) append(" AND ${CalendarContract.Events.TITLE} LIKE ?")
        }
        val like = if (query == null) null else "%${query.replace("%", "").replace("_", "")}%"
        val args = mutableListOf(end.toString(), start.toString())
        if (calendarId != null) args += calendarId
        if (like != null) args += like

        val events = JSONArray()
        val projection = arrayOf(
            CalendarContract.Events._ID,
            CalendarContract.Events.TITLE,
            CalendarContract.Events.DTSTART,
            CalendarContract.Events.DTEND,
            CalendarContract.Events.EVENT_LOCATION,
            CalendarContract.Events.ALL_DAY,
            CalendarContract.Events.CALENDAR_ID,
        )
        context.contentResolver.query(
            CalendarContract.Events.CONTENT_URI,
            projection,
            selection,
            args.toTypedArray(),
            "${CalendarContract.Events.DTSTART} ASC",
        )?.use { cursor ->
            val idIdx = cursor.getColumnIndex(CalendarContract.Events._ID)
            val titleIdx = cursor.getColumnIndex(CalendarContract.Events.TITLE)
            val startIdx = cursor.getColumnIndex(CalendarContract.Events.DTSTART)
            val endIdx = cursor.getColumnIndex(CalendarContract.Events.DTEND)
            val locationIdx = cursor.getColumnIndex(CalendarContract.Events.EVENT_LOCATION)
            val allDayIdx = cursor.getColumnIndex(CalendarContract.Events.ALL_DAY)
            val calendarIdx = cursor.getColumnIndex(CalendarContract.Events.CALENDAR_ID)
            while (cursor.moveToNext() && events.length() < limit) {
                events.put(
                    JSONObject()
                        .put("id", cursor.getLong(idIdx).toString())
                        .put("title", if (titleIdx >= 0) cursor.getString(titleIdx) ?: "" else "")
                        .put("start_ms", if (startIdx >= 0) cursor.getLong(startIdx) else 0L)
                        .put("end_ms", if (endIdx >= 0) cursor.getLong(endIdx) else 0L)
                        .put("location", if (locationIdx >= 0) cursor.getString(locationIdx) ?: "" else "")
                        .put("all_day", allDayIdx >= 0 && cursor.getInt(allDayIdx) == 1)
                        .put("calendar_id", if (calendarIdx >= 0) cursor.getLong(calendarIdx).toString() else ""),
                )
            }
        }
        return JSONObject().put("outcome", "listed").put("events", events)
    }

    fun insertEvent(context: Context, payload: JSONObject): JSONObject {
        val title = payload.optString("title").trim()
        val start = payload.optLong("start_ms", -1L)
        val end = payload.optLong("end_ms", -1L)
        if (title.isEmpty()) throw IllegalArgumentException("invalid_title")
        if (start < 0 || end <= start) throw IllegalArgumentException("invalid_time")

        val calendarId = payload.optString("calendar_id").ifBlank { null }?.toLongOrNull()
            ?: primaryCalendarId(context)
            ?: throw IllegalStateException("no_calendar")

        val values = ContentValues().apply {
            put(CalendarContract.Events.CALENDAR_ID, calendarId)
            put(CalendarContract.Events.TITLE, title)
            put(CalendarContract.Events.DTSTART, start)
            put(CalendarContract.Events.DTEND, end)
            put(CalendarContract.Events.EVENT_TIMEZONE, java.util.TimeZone.getDefault().id)
            put(CalendarContract.Events.ALL_DAY, if (payload.optBoolean("all_day", false)) 1 else 0)
            payload.optString("description").ifBlank { null }?.let {
                put(CalendarContract.Events.DESCRIPTION, it)
            }
            payload.optString("location").ifBlank { null }?.let {
                put(CalendarContract.Events.EVENT_LOCATION, it)
            }
        }
        val uri = context.contentResolver.insert(CalendarContract.Events.CONTENT_URI, values)
            ?: throw IllegalStateException("insert_failed")
        val eventId = ContentUris.parseId(uri)
        return JSONObject()
            .put("outcome", "inserted")
            .put("event_id", eventId.toString())
            .put("calendar_id", calendarId.toString())
    }

    private fun primaryCalendarId(context: Context): Long? {
        val projection = arrayOf(
            CalendarContract.Calendars._ID,
            CalendarContract.Calendars.IS_PRIMARY,
            CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL,
        )
        context.contentResolver.query(
            CalendarContract.Calendars.CONTENT_URI,
            projection,
            "${CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL} >= ?",
            arrayOf(CalendarContract.Calendars.CAL_ACCESS_CONTRIBUTOR.toString()),
            "${CalendarContract.Calendars.IS_PRIMARY} DESC",
        )?.use { cursor ->
            if (!cursor.moveToFirst()) return null
            val idIdx = cursor.getColumnIndex(CalendarContract.Calendars._ID)
            return if (idIdx >= 0) cursor.getLong(idIdx) else null
        }
        return null
    }
}
