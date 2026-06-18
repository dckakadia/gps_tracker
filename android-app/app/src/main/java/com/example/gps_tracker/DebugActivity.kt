package com.example.gps_tracker

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Typeface
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Bundle
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import kotlin.concurrent.timer
import java.util.Timer
import java.util.Locale

/**
 * Hidden diagnostics screen. Shows raw GPS coordinates, request counters and the
 * live log panel. Reachable only via a long-press on the version label in MainActivity.
 */
@Suppress("DEPRECATION")
class DebugActivity : AppCompatActivity() {

    private var locationManager: LocationManager? = null
    private var locationListener: LocationListener? = null
    private var updateTimer: Timer? = null

    private val logUpdateCallback = {
        runOnUiThread { refreshLogPanel() }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_debug)

        locationManager = getSystemService(LOCATION_SERVICE) as LocationManager

        // Show "Waiting for GPS fix…" until a real location arrives.
        findViewById<TextView>(R.id.tvLatitude).text = "Waiting for GPS fix…"
        findViewById<TextView>(R.id.tvLongitude).text = "Waiting for GPS fix…"
        findViewById<TextView>(R.id.tvAccuracy).text = "—"

        LiveLogManager.addLogListener(logUpdateCallback)
        refreshLogPanel()

        startLocationUpdates()
        startUIRefresh()
    }

    private fun startLocationUpdates() {
        val hasFine = ContextCompat.checkSelfPermission(
            this, Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
        val hasCoarse = ContextCompat.checkSelfPermission(
            this, Manifest.permission.ACCESS_COARSE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED

        if (!hasFine && !hasCoarse) return

        val listener = object : LocationListener {
            override fun onLocationChanged(location: Location) {
                showLocation(location)
            }

            override fun onProviderEnabled(provider: String) {}
            override fun onProviderDisabled(provider: String) {}
            @Deprecated("Deprecated in API 29")
            override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
        }
        locationListener = listener

        try {
            locationManager?.requestLocationUpdates(
                LocationManager.GPS_PROVIDER, 2000L, 0f, listener
            )
            // Show last known location immediately if available.
            val last = locationManager?.getLastKnownLocation(LocationManager.GPS_PROVIDER)
                ?: locationManager?.getLastKnownLocation(LocationManager.NETWORK_PROVIDER)
            last?.let { showLocation(it) }
        } catch (e: SecurityException) {
            android.util.Log.e("DebugActivity", "Location permission missing: ${e.message}")
        }
    }

    private fun showLocation(location: Location) {
        runOnUiThread {
            findViewById<TextView>(R.id.tvLatitude).text =
                String.format("%.6f", location.latitude)
            findViewById<TextView>(R.id.tvLongitude).text =
                String.format("%.6f", location.longitude)
            findViewById<TextView>(R.id.tvAccuracy).text =
                String.format("%.1fm", location.accuracy)
        }
    }

    private fun startUIRefresh() {
        updateTimer = timer(initialDelay = 1000, period = 2000) {
            runOnUiThread { updateServerStats() }
        }
    }

    private fun updateServerStats() {
        findViewById<TextView>(R.id.tvSuccessCount).text =
            ServerStats.successfulRequests.toString()
        findViewById<TextView>(R.id.tvTotalCount).text =
            ServerStats.totalRequests.toString()
        updateTrackingStatePanel()
    }

    private fun updateTrackingStatePanel() {
        val stateView     = findViewById<TextView>(R.id.tvTrackingState)
        val sensorView    = findViewById<TextView>(R.id.tvMotionSensor)
        val heartbeatView = findViewById<TextView>(R.id.tvNextHeartbeat)

        val state = TrackingService.currentState

        stateView.text = when (state) {
            TrackingService.State.MOVING      -> "MOVING  (GPS active, 30 s interval)"
            TrackingService.State.STATIONARY  -> "STANDBY  (GPS off, accelerometer armed)"
        }
        stateView.setTextColor(when (state) {
            TrackingService.State.MOVING     -> Color.parseColor("#2E7D32")
            TrackingService.State.STATIONARY -> Color.parseColor("#E65100")
        })

        val available = TrackingService.isMotionSensorAvailable
        sensorView.text = when {
            !available                       -> "Not available on this device"
            state == TrackingService.State.STATIONARY -> "Armed  (TYPE_SIGNIFICANT_MOTION)"
            else                             -> "Standby  (disarmed while moving)"
        }
        sensorView.setTextColor(when {
            !available                       -> Color.parseColor("#C62828")
            state == TrackingService.State.STATIONARY -> Color.parseColor("#2E7D32")
            else                             -> Color.parseColor("#1565C0")
        })

        val nextHb = TrackingService.nextHeartbeatAt
        heartbeatView.text = if (nextHb == 0L || state == TrackingService.State.MOVING) {
            "n/a  (only active in standby)"
        } else {
            val diffMs = nextHb - System.currentTimeMillis()
            if (diffMs <= 0) "Overdue — pending network" else {
                val h = diffMs / 3_600_000
                val m = (diffMs % 3_600_000) / 60_000
                val s = (diffMs % 60_000) / 1_000
                String.format(Locale.US, "in %02d:%02d:%02d", h, m, s)
            }
        }
    }

    private fun refreshLogPanel() {
        val logContainer = findViewById<LinearLayout>(R.id.logContainer)
        logContainer.removeAllViews()
        LiveLogManager.logs.forEach { entry ->
            val tv = TextView(this)
            tv.text = entry
            tv.typeface = Typeface.MONOSPACE
            tv.textSize = 10f
            tv.setPadding(8, 4, 8, 4)
            tv.setTextColor(when {
                entry.contains("✅") -> Color.parseColor("#2E7D32")
                entry.contains("❌") -> Color.parseColor("#C62828")
                entry.contains("⚠️") -> Color.parseColor("#E65100")
                else -> Color.parseColor("#1565C0")
            })
            logContainer.addView(tv)
        }
    }

    override fun onDestroy() {
        LiveLogManager.removeLogListener(logUpdateCallback)
        updateTimer?.cancel()
        locationListener?.let {
            try {
                locationManager?.removeUpdates(it)
            } catch (e: SecurityException) {
                // ignore
            }
        }
        super.onDestroy()
    }
}
