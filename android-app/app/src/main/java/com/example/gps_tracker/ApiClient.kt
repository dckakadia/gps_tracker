package com.example.gps_tracker

import android.content.Context
import com.squareup.moshi.JsonAdapter
import com.squareup.moshi.Moshi
import com.squareup.moshi.Types
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

object ApiClient {
    const val BASE_URL = "http://116.74.77.22:8095/api"
    private var authToken: String? = null

    private val client = OkHttpClient.Builder()
        .callTimeout(java.time.Duration.ofSeconds(20))
        .build()

    private val moshi = Moshi.Builder().build()
    private val listType = Types.newParameterizedType(List::class.java, Map::class.java)
    private val adapter: JsonAdapter<List<Map<String, Any>>> = moshi.adapter(listType)
    private val mapType = Types.newParameterizedType(Map::class.java, String::class.java, Any::class.java)
    private val mapAdapter: JsonAdapter<Map<String, Any>> = moshi.adapter(mapType)

    fun setToken(token: String) {
        authToken = token
    }

    fun clearToken() {
        authToken = null
    }

    suspend fun login(email: String, password: String): LoginResult {
        return withContext(Dispatchers.IO) {
            try {
                val bodyJson = mapAdapter.toJson(mapOf(
                    "identifier" to email,
                    "password" to password,
                ))
                val request = Request.Builder()
                    .url("$BASE_URL/auth/login")
                    .post(bodyJson.toRequestBody("application/json; charset=utf-8".toMediaType()))
                    .build()

                client.newCall(request).execute().use { response ->
                    val responseBody = response.body?.string()
                    if (!response.isSuccessful || responseBody == null) {
                        return@withContext LoginResult(
                            false, null, null,
                            "Login failed",
                            statusCode = response.code
                        )
                    }
                    val parsed = mapAdapter.fromJson(responseBody)
                    val token = parsed?.get("token") as? String
                    val refreshToken = parsed?.get("refreshToken") as? String
                    val error = parsed?.get("error") as? String
                    return@withContext if (token != null) {
                        LoginResult(true, token, refreshToken, null, statusCode = response.code)
                    } else {
                        LoginResult(false, null, null, error ?: "Login failed", statusCode = response.code)
                    }
                }
            } catch (err: Exception) {
                android.util.Log.e("ApiClient", "Login exception", err)
                err.printStackTrace()
                return@withContext LoginResult(
                    false, null, null,
                    err.message ?: "Network error",
                    networkError = true
                )
            }
        }
    }

    private fun isTokenExpiringSoon(token: String, withinSeconds: Long = 300): Boolean {
        try {
            val parts = token.split('.')
            if (parts.size < 2) return true
            val payload = parts[1]
            val decoded = java.util.Base64.getUrlDecoder().decode(payload)
            val map = mapAdapter.fromJson(String(decoded))
            val exp = (map?.get("exp") as? Double)?.toLong() ?: (map?.get("exp") as? Long)
            exp?.let {
                val nowSec = System.currentTimeMillis() / 1000
                return (it - nowSec) <= withinSeconds
            }
        } catch (e: Exception) {
            android.util.Log.e("ApiClient", "Failed to parse token expiry: ${e.message}", e)
        }
        return true
    }

    private fun notifySessionExpired(context: Context) {
        val channelId = "gps_tracker_auth_channel"
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            val channel = android.app.NotificationChannel(channelId, "GPS Tracker Auth Alerts", android.app.NotificationManager.IMPORTANCE_HIGH)
            channel.description = "Notifications when auth token is missing or expired"
            val manager = context.getSystemService(android.app.NotificationManager::class.java)
            manager?.createNotificationChannel(channel)
        }
        val notification = androidx.core.app.NotificationCompat.Builder(context, channelId)
            .setContentTitle("Session expired, please login again.")
            .setContentText("Tap to open app and re-login")
            .setSmallIcon(android.R.drawable.ic_dialog_alert)
            .setPriority(androidx.core.app.NotificationCompat.PRIORITY_HIGH)
            .build()
        val manager = context.getSystemService(android.app.NotificationManager::class.java)
        manager?.notify(9999, notification)
    }

    private suspend fun ensureFreshToken(context: Context): Boolean {
        return withContext(Dispatchers.IO) {
            try {
                val token = authToken ?: AuthManager.getToken(context)
                if (token == null) return@withContext false
                if (!isTokenExpiringSoon(token, 300)) return@withContext true

                // Attempt refresh
                val refreshToken = AuthManager.getRefreshToken(context)
                if (refreshToken == null) {
                    AuthManager.clearToken(context)
                    clearToken()
                    notifySessionExpired(context)
                    return@withContext false
                }

                val bodyJson = mapAdapter.toJson(mapOf("refreshToken" to refreshToken))
                val request = Request.Builder()
                    .url("$BASE_URL/auth/refresh")
                    .post(bodyJson.toRequestBody("application/json; charset=utf-8".toMediaType()))
                    .build()

                client.newCall(request).execute().use { response ->
                    val responseBody = response.body?.string()
                    if (!response.isSuccessful || responseBody == null) {
                        AuthManager.clearToken(context)
                        clearToken()
                        notifySessionExpired(context)
                        return@withContext false
                    }
                    val parsed = mapAdapter.fromJson(responseBody)
                    val newToken = parsed?.get("token") as? String
                    if (newToken != null) {
                        AuthManager.saveToken(context, newToken)
                        setToken(newToken)
                        android.util.Log.i("ApiClient", "Token refreshed successfully")
                        return@withContext true
                    } else {
                        AuthManager.clearToken(context)
                        clearToken()
                        notifySessionExpired(context)
                        return@withContext false
                    }
                }
            } catch (e: Exception) {
                android.util.Log.e("ApiClient", "Token refresh failed: ${e.message}", e)
                AuthManager.clearToken(context)
                clearToken()
                notifySessionExpired(context)
                return@withContext false
            }
        }
    }

    suspend fun uploadLocations(context: Context, points: List<LocationEntity>): Boolean {
        return withContext(Dispatchers.IO) {
            try {
                // Ensure token is fresh/valid before attempting upload
                if (!ensureFreshToken(context)) {
                    android.util.Log.e("ApiClient", "UPLOAD BLOCKED — No valid auth token. User must log in.")
                    LogPersistor.append(context, "ApiClient", "UPLOAD BLOCKED — No valid auth token. User must log in.")
                    LiveLogManager.log("⚠️", "Token missing/expired — skipped")
                    return@withContext false
                }

                if (authToken == null) {
                    android.util.Log.e("ApiClient", "UPLOAD BLOCKED — No auth token. User must log in.")
                    LogPersistor.append(context, "ApiClient", "UPLOAD BLOCKED — No auth token. User must log in.")
                    LiveLogManager.log("⚠️", "Token missing — skipped")
                    return@withContext false
                }

                val payload = points.map { point ->
                    val pointMap = mutableMapOf<String, Any>(
                        "latitude" to point.latitude,
                        "longitude" to point.longitude,
                        "recorded_at" to point.recordedAt
                    )
                    if (point.batteryLevel >= 0) {
                        pointMap["battery_level"] = point.batteryLevel
                    }
                    pointMap
                }

                val json = adapter.toJson(payload)
                android.util.Log.d("ApiClient", "Uploading ${points.size} location(s) payload: $json")
                LogPersistor.append(context, "ApiClient", "Uploading ${points.size} location(s) payload: $json")

                val maxAttempts = 3
                var attempt = 1
                while (attempt <= maxAttempts) {
                    try {
                        LiveLogManager.log("📡", "Uploading to server...")
                        val requestUrl = "$BASE_URL/locations"
                        val builder = Request.Builder()
                            .url(requestUrl)
                            .addHeader("Content-Type", "application/json")
                            .post(json.toRequestBody("application/json; charset=utf-8".toMediaType()))

                        val tokenPresent = authToken != null
                        authToken?.let {
                            builder.addHeader("Authorization", "Bearer $it")
                        }

                        val request = builder.build()
                        android.util.Log.d("ApiClient", "Uploading locations to $requestUrl tokenPresent=$tokenPresent")
                        client.newCall(request).execute().use { response ->
                            val body = response.body?.string()
                            if (response.isSuccessful) {
                                android.util.Log.i("ApiClient", "Upload SUCCESS — ${points.size} points sent")
                                LogPersistor.append(context, "ApiClient", "Upload SUCCESS — ${points.size} points sent")
                                LiveLogManager.totalCount++
                                LiveLogManager.successCount++
                                ServerStats.incrementSuccess()
                                LiveLogManager.log("✅", "Server: ${response.code} OK — saved")
                                return@withContext true
                            } else {
                                android.util.Log.e("ApiClient", "Upload FAILED — HTTP status: ${response.code}, body: $body, tokenPresent=$tokenPresent")
                                LogPersistor.append(context, "ApiClient", "Upload FAILED — HTTP status: ${response.code}, body: $body, tokenPresent=$tokenPresent")
                                LiveLogManager.totalCount++
                                ServerStats.incrementTotal()
                                LiveLogManager.log("❌", "Failed: HTTP ${response.code}")
                                if (response.code == 401) {
                                    android.util.Log.w("ApiClient", "401 Invalid token detected, clearing saved token")
                                    AuthManager.clearToken(context)
                                    clearToken()
                                }
                            }
                        }
                    } catch (innerErr: Exception) {
                        android.util.Log.e("ApiClient", "Upload exception on attempt $attempt", innerErr)
                        LogPersistor.append(context, "ApiClient", "Upload exception on attempt $attempt: ${innerErr.message}")
                        LiveLogManager.totalCount++
                        ServerStats.incrementTotal()
                        LiveLogManager.log("❌", "Error: ${innerErr.message}")
                    }

                    if (attempt < maxAttempts) {
                        val backoff = 1000L * (1 shl (attempt - 1)) // 1s, 2s, ...
                        android.util.Log.d("ApiClient", "Retrying upload in ${backoff}ms (attempt ${attempt + 1})")
                        delay(backoff)
                    }
                    attempt++
                }

                android.util.Log.e("ApiClient", "All upload attempts failed")
                LogPersistor.append(context, "ApiClient", "All upload attempts failed for payload: $json")
                return@withContext false
            } catch (err: Exception) {
                android.util.Log.e("ApiClient", "Upload exception", err)
                LogPersistor.append(context, "ApiClient", "Upload exception: ${err.message}")
                return@withContext false
            }
        }
    }

    suspend fun saveFcmToken(context: Context, fcmToken: String): Boolean {
        return withContext(Dispatchers.IO) {
            try {
                if (!ensureFreshToken(context)) return@withContext false
                val bodyJson = mapAdapter.toJson(mapOf("fcm_token" to fcmToken))
                val request = Request.Builder()
                    .url("$BASE_URL/users/fcm-token")
                    .addHeader("Authorization", "Bearer ${authToken ?: ""}")
                    .post(bodyJson.toRequestBody("application/json; charset=utf-8".toMediaType()))
                    .build()
                client.newCall(request).execute().use { response ->
                    android.util.Log.i("ApiClient", "FCM token save: HTTP ${response.code}")
                    response.isSuccessful
                }
            } catch (e: Exception) {
                android.util.Log.e("ApiClient", "saveFcmToken exception: ${e.message}", e)
                false
            }
        }
    }

    /**
     * [statusCode] carries the HTTP response code on a server response, or null when the
     * request never reached the server (network error / timeout). Callers use this to tell
     * bad-credential failures (401) apart from connectivity problems.
     */
    data class LoginResult(
        val success: Boolean,
        val token: String?,
        val refreshToken: String?,
        val error: String?,
        val statusCode: Int? = null,
        val networkError: Boolean = false
    )
}
