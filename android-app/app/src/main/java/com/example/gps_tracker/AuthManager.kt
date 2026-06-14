package com.example.gps_tracker

import android.content.Context

object AuthManager {
    private const val PREFS_NAME = "gps_tracker_prefs"
    private const val KEY_TOKEN = "auth_token"

    // In-memory cache to avoid read-after-write races when the service
    // starts immediately after login.
    @Volatile
    private var inMemoryToken: String? = null

    fun saveToken(context: Context, token: String) {
        // update in-memory first
        inMemoryToken = token
        // persist synchronously to ensure availability for other components
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_TOKEN, token)
            .commit()
    }

    fun getToken(context: Context): String? {
        // prefer in-memory cached token if available
        inMemoryToken?.let { return it }
        val token = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getString(KEY_TOKEN, null)
        // cache for subsequent fast reads
        inMemoryToken = token
        return token
    }
}
