package com.example.gps_tracker

import android.content.Context
import android.util.Log
import com.google.firebase.messaging.FirebaseMessaging
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await

object FcmTokenManager {
    private const val TAG = "FcmTokenManager"

    fun registerToken(context: Context) {
        CoroutineScope(Dispatchers.IO).launch {
            try {
                val token = FirebaseMessaging.getInstance().token.await()
                val authToken = AuthManager.getToken(context) ?: return@launch
                ApiClient.setToken(authToken)
                ApiClient.saveFcmToken(context, token)
                Log.i(TAG, "FCM token registered successfully")
            } catch (e: Exception) {
                Log.w(TAG, "FCM token registration failed: ${e.message}")
            }
        }
    }
}
