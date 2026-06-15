package com.example.gps_tracker

import android.content.Context
import android.os.Build
import android.provider.Settings
import android.util.Log

/**
 * Device compatibility helpers for handling manufacturer-specific differences
 */
object DeviceCompat {
    private const val TAG = "DeviceCompat"
    
    data class DeviceInfo(
        val manufacturer: String,
        val model: String,
        val androidVersion: Int,
        val isMotorolaDevice: Boolean,
        val isSamsungDevice: Boolean,
        val isXiaomiDevice: Boolean,
        val isOPPODevice: Boolean,
        val hasDozeMode: Boolean,
        val hasBatteryOptimization: Boolean
    )
    
    fun getDeviceInfo(): DeviceInfo {
        val manufacturer = Build.MANUFACTURER.uppercase()
        val model = Build.MODEL
        val version = Build.VERSION.SDK_INT
        
        return DeviceInfo(
            manufacturer = manufacturer,
            model = model,
            androidVersion = version,
            isMotorolaDevice = manufacturer.contains("MOTOROLA") || manufacturer.contains("MOTO"),
            isSamsungDevice = manufacturer.contains("SAMSUNG"),
            isXiaomiDevice = manufacturer.contains("XIAOMI"),
            isOPPODevice = manufacturer.contains("OPPO"),
            hasDozeMode = version >= Build.VERSION_CODES.M,
            hasBatteryOptimization = version >= Build.VERSION_CODES.M
        )
    }
    
    fun getDeviceDebugInfo(context: Context): String {
        val info = getDeviceInfo()
        val batteryOptimizationEnabled = isBatteryOptimizationEnabled(context)
        
        return """
            Device Info:
            - Manufacturer: ${info.manufacturer}
            - Model: ${info.model}
            - Android: ${info.androidVersion} (${Build.VERSION.RELEASE})
            - Motorola: ${info.isMotorolaDevice}
            - Samsung: ${info.isSamsungDevice}
            - Xiaomi: ${info.isXiaomiDevice}
            - OPPO: ${info.isOPPODevice}
            - Battery Optimization: $batteryOptimizationEnabled
        """.trimIndent()
    }
    
    fun isBatteryOptimizationEnabled(context: Context): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val pm = context.getSystemService(android.content.Context.POWER_SERVICE) as android.os.PowerManager?
                pm?.let { !it.isIgnoringBatteryOptimizations(context.packageName) } ?: false
            } else {
                false
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error checking battery optimization", e)
            false
        }
    }
    
    fun getMotorolaCompatibilityIssues(): List<String> {
        return listOf(
            "Strict Doze mode enforcement",
            "Aggressive battery optimization",
            "Background app restrictions",
            "Custom permission handling",
            "Network access may be restricted"
        )
    }
    
    fun logDeviceInfo(context: Context) {
        Log.i(TAG, "===== Device Information =====")
        Log.i(TAG, getDeviceDebugInfo(context))
        Log.i(TAG, "=============================")
        LiveLogManager.log("[DEVICE]", getDeviceDebugInfo(context).replace("\n", " | "))
    }
    
    fun applyDeviceSpecificFixes(context: Context) {
        val info = getDeviceInfo()
        
        if (info.isMotorolaDevice) {
            Log.w(TAG, "[WARN] Applying Motorola-specific compatibility fixes")
            // Motorola devices need explicit workarounds
            // These are handled in LocationRequest and foreground service
        }
        
        if (info.hasDozeMode && isBatteryOptimizationEnabled(context)) {
            Log.w(TAG, "[WARN] Battery optimization is enabled - app may have limited background execution")
            LiveLogManager.log("[BATTERY]", "Battery optimization enabled - background execution may be limited")
        }
    }
}
