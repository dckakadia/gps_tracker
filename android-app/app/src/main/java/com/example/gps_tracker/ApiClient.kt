package com.example.gps_tracker

import android.content.Context
import com.squareup.moshi.JsonAdapter
import com.squareup.moshi.Moshi
import com.squareup.moshi.Types
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

object ApiClient {
    private const val BASE_URL = "http://116.74.77.22:8095/api"
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
                    android.util.Log.w("ApiClient", "Upload attempted without auth token")
                    return@withContext false
                }

                val json = adapter.toJson(points.map { point ->
                    mapOf(
                        "latitude" to point.latitude,
                        "longitude" to point.longitude,
                        "recorded_at" to point.recordedAt
                    )
                })
                android.util.Log.d("ApiClient", "Uploading ${points.size} location(s)")
                val builder = Request.Builder()
                    .url("$BASE_URL/locations")
                    .post(json.toRequestBody("application/json; charset=utf-8".toMediaType()))

                authToken?.let {
                    builder.addHeader("Authorization", "Bearer $it")
                }

                val request = builder.build()
                client.newCall(request).execute().use { response ->
                    val success = response.isSuccessful
                    if (success) {
                        android.util.Log.d("ApiClient", "Upload succeeded (status: ${response.code})")
                    } else {
                        val body = response.body?.string()
                        android.util.Log.e("ApiClient", "Upload failed (status: ${response.code}, body: $body)")
                    }
                    return@withContext success
                }
            } catch (err: Exception) {
                android.util.Log.e("ApiClient", "Upload exception", err)
                return@withContext false
            }
        }
    }

    data class LoginResult(val success: Boolean, val token: String?, val error: String?)
}
