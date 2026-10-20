package com.example.handbean_probe

import org.json.JSONArray

internal object MobAlertCodec {
    fun parseButtons(json: String): List<Map<String, String>> {
        return try {
            val arr = JSONArray(json)
            (0 until arr.length()).map { i ->
                val obj = arr.getJSONObject(i)
                mapOf("label"  to obj.optString("label"),
                      "style"  to obj.optString("style"),
                      "action" to obj.optString("action"))
            }
        } catch (e: Exception) { emptyList() }
    }
}
