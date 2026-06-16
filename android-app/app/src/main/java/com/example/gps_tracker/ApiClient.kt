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
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager
import java.security.cert.X509Certificate
import java.security.SecureRandom

object ApiClient {
    private const val BASE_URL = "http://116.74.77.22:8095/api"
    private var authToken: String? = null
    
    // Create permissive trust manager to accept all certificates
    private fun createPermissiveTrustManager(): X509TrustManager {
        return object : X509TrustManager {
            override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) {}
            override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {}
            override fun getAcceptedIssuers(): Array<X509Certificate>? = arrayOf()
        }
    }
    
    private val client = OkHttpClient.Builder()
        .callTimeout(java.time.Duration.ofSeconds(20))
        .also { builder ->
            try {
                val trustManager = createPermissiveTrustManager()
                val sslContext = SSLContext.getInstance("TLS").apply {
                    init(null, arrayOf<TrustManager>(trustManager), SecureRandom())
                }
                builder.sslSocketFactory(sslContext.socketFactory, trustManager)
                builder.hostnameVerifier { _, _ -> true }
            } catch (e: Exception) {
                android.util.Log.e("ApiClient", "SSL configuration error", e)
            }
        }
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
                        return@withContext LoginResult(false, null, "Invalid credentials or network error")
                    }
                    val parsed = mapAdapter.fromJson(responseBody)
                    val token = parsed?.get("token") as? String
                    val error = parsed?.get("error") as? String
                    return@withContext if (token != null) {
                        LoginResult(true, token, null)
                    } else {
                        LoginResult(false, null, error ?: "Login failed")
                    }
                }
            } catch (err: Exception) {
                android.util.Log.e("ApiClient", "Login exception", err)
                err.printStackTrace()
                return@withContext LoginResult(false, null, err.message ?: "Network error")
            }
        }
    }

    suspend fun uploadLocations(context: Context, points: List<LocationEntity>): Boolean {
        return withContext(Dispatchers.IO) {
            try {
                if (authToken == null) {
                    android.util.Log.e("ApiClient", "UPLOAD BLOCKED — No auth token. User must log in.")
                    LogPersistor.append(context, "ApiClient", "UPLOAD BLOCKED — No auth token. User must log in.")
                    LiveLogManager.log("⚠️", "Token missing — skipped")
                    return@withContext false
                }

                val payload = points.map { point ->
                    mapOf(
                        "latitude" to point.latitude,
                        "longitude" to point.longitude,
                        "recorded_at" to point.recordedAt
                    )
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

    data class LoginResult(val success: Boolean, val token: String?, val error: String?)
}
