package com.example.gps_tracker

import android.content.Context

object AuthManager {
    private const val PREFS_NAME = "gps_tracker_prefs"
    private const val KEY_TOKEN = "auth_token"

    fun saveToken(context: Context, token: String) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_TOKEN, token)
            .apply()
    }

    fun getToken(context: Context): String? {
        return context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getString(KEY_TOKEN, null)
    }
}
