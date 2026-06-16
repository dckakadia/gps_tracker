package com.example.gps_tracker

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import java.net.HttpURLConnection
import java.net.URL

/**
 * Network connectivity and diagnostics helper
 */
object NetworkDiagnostics {
    private const val TAG = "NetworkDiagnostics"
    
    data class NetworkStatus(
        val isConnected: Boolean,
        val isWifi: Boolean,
        val isCellular: Boolean,
        val isMetered: Boolean,
        val backendReachable: Boolean = false,
        val backendUrl: String = "",
        val diagnosticMessage: String = ""
    )
    
    fun getNetworkStatus(context: Context): NetworkStatus {
        val connectivityManager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val network = connectivityManager.activeNetwork ?: return NetworkStatus(false, false, false, false)
            val capabilities = connectivityManager.getNetworkCapabilities(network) ?: return NetworkStatus(false, false, false, false)
            
            val isWifi = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
            val isCellular = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)
            val isMetered = !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
            
            return NetworkStatus(
                isConnected = true,
                isWifi = isWifi,
                isCellular = isCellular,
                isMetered = isMetered,
                diagnosticMessage = "Connected via ${if (isWifi) "WiFi" else "Cellular"}, Metered: $isMetered"
            )
        } else {
            @Suppress("DEPRECATION")
            val activeNetwork = connectivityManager.activeNetworkInfo ?: return NetworkStatus(false, false, false, false)
            @Suppress("DEPRECATION")
            val isWifi = activeNetwork.type == ConnectivityManager.TYPE_WIFI
            @Suppress("DEPRECATION")
            val isCellular = activeNetwork.type == ConnectivityManager.TYPE_MOBILE
            @Suppress("DEPRECATION")
            val isMetered = connectivityManager.isActiveNetworkMetered
            
            return NetworkStatus(
                isConnected = activeNetwork.isConnected,
                isWifi = isWifi,
                isCellular = isCellular,
                isMetered = isMetered,
                diagnosticMessage = "Connected via ${if (isWifi) "WiFi" else "Cellular"}, Metered: $isMetered"
            )
        }
    }
    
    fun checkBackendConnectivity(backendUrl: String, timeout: Int = 5000): Boolean {
        return try {
            Log.d(TAG, "Checking backend connectivity: $backendUrl")
            val url = URL(backendUrl)
            val connection = url.openConnection() as HttpURLConnection
            connection.connectTimeout = timeout
            connection.readTimeout = timeout
            connection.requestMethod = "GET"
            
            val responseCode = connection.responseCode
            Log.d(TAG, "Backend response code: $responseCode")
            
            connection.disconnect()
            responseCode in 200..299
        } catch (e: Exception) {
            Log.e(TAG, "Backend connectivity check failed: ${e.message}", e)
            false
        }
    }
    
    fun logNetworkDiagnostics(context: Context, backendUrl: String = "http://116.74.77.22:8095/health") {
        CoroutineScope(Dispatchers.IO).launch {
            try {
                val status = getNetworkStatus(context)
                val backendReachable = checkBackendConnectivity(backendUrl)
                
                val diagnosticInfo = """
                    Network Diagnostics:
                    - Connected: ${status.isConnected}
                    - Connection: ${status.diagnosticMessage}
                    - Backend ($backendUrl): ${if (backendReachable) "[OK] Reachable" else "[FAIL] Unreachable"}
                    - Device: ${DeviceCompat.getDeviceInfo().manufacturer} ${DeviceCompat.getDeviceInfo().model}
                """.trimIndent()
                
                Log.i(TAG, diagnosticInfo)
                LiveLogManager.log("[NETWORK]", diagnosticInfo.replace("\n", " | "))
            } catch (e: Exception) {
                Log.e(TAG, "Error logging network diagnostics", e)
            }
        }
    }
    
    fun isNetworkAvailable(context: Context): Boolean = getNetworkStatus(context).isConnected
}
