package com.example.gps_tracker

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.Location
import android.os.Build
import androidx.core.app.ActivityCompat
import com.google.android.gms.location.LocationServices

/**
 * AlarmManager fallback for devices without a TYPE_SIGNIFICANT_MOTION hardware sensor.
 * Fires every 15 minutes while STATIONARY. Uses getLastLocation() (zero battery cost —
 * reads the OS location cache) to compare against the previous check's coordinates.
 * If the device has moved >50 m, it wakes TrackingService to MOVING state.
 */
class StationaryWakeReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION = "com.example.gps_tracker.STATIONARY_WAKE_CHECK"
        private const val PREFS = "stationary_wake"
        private const val KEY_LAT  = "last_lat"
        private const val KEY_LNG  = "last_lng"
        private const val KEY_TIME = "last_time"
        private const val MOVEMENT_THRESHOLD_M = 50f
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION) return
        if (TrackingService.currentState != TrackingService.State.STATIONARY) return

        val fineOk = ActivityCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) ==
                PackageManager.PERMISSION_GRANTED
        val coarseOk = ActivityCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) ==
                PackageManager.PERMISSION_GRANTED
        if (!fineOk && !coarseOk) return

        val fusedClient = LocationServices.getFusedLocationProviderClient(context)
        // getLastLocation reads the OS cache — no GPS wake, negligible battery cost.
        fusedClient.lastLocation.addOnSuccessListener { location: Location? ->
            location ?: return@addOnSuccessListener

            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val prevLat  = prefs.getFloat(KEY_LAT, Float.NaN).toDouble()
            val prevLng  = prefs.getFloat(KEY_LNG, Float.NaN).toDouble()

            prefs.edit()
                .putFloat(KEY_LAT, location.latitude.toFloat())
                .putFloat(KEY_LNG, location.longitude.toFloat())
                .putLong(KEY_TIME, System.currentTimeMillis())
                .apply()

            if (prevLat.isNaN() || prevLng.isNaN()) return@addOnSuccessListener

            val results = FloatArray(1)
            Location.distanceBetween(prevLat, prevLng, location.latitude, location.longitude, results)
            val movedMeters = results[0]

            android.util.Log.i("StationaryWakeReceiver",
                "AlarmManager fallback: ${movedMeters.toInt()} m moved since last check")

            if (movedMeters >= MOVEMENT_THRESHOLD_M) {
                android.util.Log.i("StationaryWakeReceiver",
                    "Significant movement (${movedMeters.toInt()} m) → waking TrackingService")
                LogPersistor.append(context, "StationaryWakeReceiver",
                    "Alarm fallback wake: moved ${movedMeters.toInt()} m → MOVING")
                val wakeIntent = Intent(context, TrackingService::class.java).apply {
                    action = TrackingService.ACTION_WAKE_FROM_ACTIVITY
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(wakeIntent)
                } else {
                    context.startService(wakeIntent)
                }
            }
        }
    }
}
