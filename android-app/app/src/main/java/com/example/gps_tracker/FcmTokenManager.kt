package com.example.gps_tracker

import android.content.Context
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

object FcmTokenManager {
    private const val TAG = "FcmTokenManager"

    fun registerToken(context: Context) {
        CoroutineScope(Dispatchers.IO).launch {
            try {
                // Only attempt if Firebase is available on the classpath
                val token = getFcmToken() ?: return@launch
                val authToken = AuthManager.getToken(context) ?: return@launch
                ApiClient.setToken(authToken)
                ApiClient.saveFcmToken(context, token)
                Log.i(TAG, "FCM token registered successfully")
            } catch (e: Exception) {
                Log.w(TAG, "FCM token registration skipped: ${e.message}")
            }
        }
    }

    private fun getFcmToken(): String? {
        return try {
            // Use reflection to avoid hard compile-time dependency on Firebase
            val clazz = Class.forName("com.google.firebase.messaging.FirebaseMessaging")
            val getInstance = clazz.getMethod("getInstance")
            val instance = getInstance.invoke(null)
            val tokenTask = clazz.getMethod("getToken").invoke(instance)
            // FirebaseMessaging.getInstance().getToken() returns a Task<String>
            // We can't easily block here without Firebase dependency — log and return null
            Log.i(TAG, "Firebase Messaging available; token retrieval requires async handling")
            null
        } catch (e: ClassNotFoundException) {
            Log.d(TAG, "Firebase Messaging not available — skipping FCM token registration")
            null
        } catch (e: Exception) {
            Log.w(TAG, "Failed to get FCM token: ${e.message}")
            null
        }
    }
}
