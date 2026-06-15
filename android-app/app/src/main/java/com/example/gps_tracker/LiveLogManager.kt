package com.example.gps_tracker

import java.text.SimpleDateFormat
import java.util.*

object LiveLogManager {
    private val _logs = mutableListOf<String>()
    private val listeners = mutableSetOf<() -> Unit>()
    val logs: List<String>
        get() = synchronized(_logs) {
            _logs.toList()
        }
    var successCount = 0
    var totalCount = 0

    @Synchronized
    fun addLogListener(listener: () -> Unit) {
        listeners.add(listener)
    }

    @Synchronized
    fun removeLogListener(listener: () -> Unit) {
        listeners.remove(listener)
    }

    private fun notifyListeners() {
        val snapshot = synchronized(listeners) {
            listeners.toList()
        }
        snapshot.forEach { it() }
    }

    fun log(emoji: String, message: String) {
        val time = SimpleDateFormat("HH:mm:ss", Locale.getDefault()).format(Date())
        val entry = "[$time] $emoji $message"
        synchronized(_logs) {
            _logs.add(0, entry)
            if (_logs.size > 20) _logs.removeAt(_logs.size - 1)
        }
        notifyListeners()
    }

    fun clear() {
        synchronized(_logs) {
            _logs.clear()
        }
        successCount = 0
        totalCount = 0
        notifyListeners()
    }
}
