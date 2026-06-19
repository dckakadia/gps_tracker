package com.example.gps_tracker

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

object NotificationStore {
    private const val PREFS = "notification_store"
    private const val KEY = "notifications"
    private const val MAX = 30

    data class Entry(val title: String, val body: String, val timestampMs: Long)

    fun save(context: Context, title: String, body: String) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val arr = try { JSONArray(prefs.getString(KEY, "[]")) } catch (_: Exception) { JSONArray() }
        val entry = JSONObject().apply {
            put("title", title)
            put("body", body)
            put("ts", System.currentTimeMillis())
        }
        arr.put(entry)
        // Keep only the most recent MAX entries
        val trimmed = JSONArray()
        val start = maxOf(0, arr.length() - MAX)
        for (i in start until arr.length()) trimmed.put(arr.get(i))
        prefs.edit().putString(KEY, trimmed.toString()).apply()
    }

    fun load(context: Context): List<Entry> {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val arr = try { JSONArray(prefs.getString(KEY, "[]")) } catch (_: Exception) { JSONArray() }
        val list = mutableListOf<Entry>()
        for (i in arr.length() - 1 downTo 0) {
            val o = arr.getJSONObject(i)
            list.add(Entry(o.optString("title", "GPS Tracker"), o.optString("body"), o.optLong("ts")))
        }
        return list
    }

    fun clear(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().remove(KEY).apply()
    }
}
