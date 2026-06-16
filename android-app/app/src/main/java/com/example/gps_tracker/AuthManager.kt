package com.example.gps_tracker

import android.content.Context

object AuthManager {
    private const val PREFS_NAME = "gps_tracker_prefs"
    private const val KEY_TOKEN = "auth_token"
    private const val KEY_REFRESH = "refresh_token"

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

    fun saveRefreshToken(context: Context, refreshToken: String) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_REFRESH, refreshToken)
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

    fun hasToken(context: Context): Boolean {
        return getToken(context) != null
    }

    fun clearToken(context: Context) {
        // clear in-memory cache
        inMemoryToken = null
        // clear from SharedPreferences
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .remove(KEY_TOKEN)
            .commit()
        // also clear refresh token
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .remove(KEY_REFRESH)
            .commit()
    }

    fun getRefreshToken(context: Context): String? {
        return context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getString(KEY_REFRESH, null)
    }
}
