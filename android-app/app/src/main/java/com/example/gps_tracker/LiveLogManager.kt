package com.example.gps_tracker

import java.text.SimpleDateFormat
import java.util.*

object LiveLogManager {
    private val _logs = mutableListOf<String>()
    val logs: List<String> get() = _logs.toList()
    var onLogAdded: (() -> Unit)? = null
    var successCount = 0
    var totalCount = 0

    fun log(emoji: String, message: String) {
        val time = SimpleDateFormat("HH:mm:ss", Locale.getDefault()).format(Date())
        val entry = "[$time] $emoji $message"
        synchronized(_logs) {
            _logs.add(0, entry)
            if (_logs.size > 20) _logs.removeAt(_logs.size - 1)
        }
        onLogAdded?.invoke()
    }

    fun clear() {
        _logs.clear()
        successCount = 0
        totalCount = 0
        onLogAdded?.invoke()
    }
}
