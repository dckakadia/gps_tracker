package com.example.gps_tracker

import android.content.Context
import java.io.File
import java.io.FileWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

object LogPersistor {
    private const val LOG_DIR = "logs"
    private const val LOG_FILE = "client_debug.log"

    fun append(context: Context, tag: String, message: String) {
        try {
            val dir = File(context.filesDir, LOG_DIR)
            if (!dir.exists()) dir.mkdirs()
            val file = File(dir, LOG_FILE)
            val ts = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(Date())
            FileWriter(file, true).use { fw ->
                fw.append("$ts [$tag] $message\n")
            }
        } catch (e: Exception) {
            android.util.Log.e("LogPersistor", "Failed to persist log", e)
        }
    }

    fun getLogFile(context: Context): File? {
        return try {
            val dir = File(context.filesDir, LOG_DIR)
            if (!dir.exists()) return null
            File(dir, LOG_FILE).takeIf { it.exists() }
        } catch (e: Exception) {
            android.util.Log.e("LogPersistor", "Failed to get log file", e)
            null
        }
    }
}
