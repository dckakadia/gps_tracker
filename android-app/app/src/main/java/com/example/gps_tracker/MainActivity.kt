package com.example.gps_tracker

import android.Manifest
import android.app.ActivityManager
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Typeface
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.view.View
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.app.AlertDialog
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.google.android.material.button.MaterialButton
import kotlinx.coroutines.GlobalScope
import kotlinx.coroutines.launch
import kotlin.concurrent.timer
import java.util.Timer

@Suppress("DEPRECATION")

class MainActivity : AppCompatActivity() {
    private val LOCATION_PERMISSION_REQUEST_CODE = 100
    private var locationManager: LocationManager? = null
    private var locationListener: LocationListener? = null
    private var updateTimer: Timer? = null
    private lateinit var authStatusText: TextView
    private lateinit var authBanner: View
    private lateinit var authRetryButton: MaterialButton
    private lateinit var btnUpdate: MaterialButton
    private var pendingUpdateInfo: UpdateChecker.VersionInfo? = null

    private val logUpdateCallback = {
        runOnUiThread { refreshLogPanel() }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        // Register the log listener before showing existing logs.
        LiveLogManager.addLogListener(logUpdateCallback)
        refreshLogPanel()

        // Start Tracking Button
        findViewById<MaterialButton>(R.id.startTrackingButton).setOnClickListener {
            android.util.Log.i("MainActivity", "Start tracking clicked")
            ensureLocationPermissionsAndStart()
        }

        // Logout button from footer
        findViewById<MaterialButton>(R.id.logoutButton)?.setOnClickListener {
            showLogoutDialog()
        }

        authStatusText = findViewById(R.id.tvAuthStatus)
        authBanner = findViewById(R.id.authBanner)
        authRetryButton = findViewById(R.id.authRetryButton)
        authRetryButton.setOnClickListener {
            startActivity(Intent(this, LoginActivity::class.java))
        }

        // Show current version in header
        findViewById<TextView>(R.id.tvAppVersion).text = "v${BuildConfig.VERSION_NAME}"

        // Update button wires to cached update info
        btnUpdate = findViewById(R.id.btnUpdate)
        btnUpdate.setOnClickListener {
            pendingUpdateInfo?.let { info ->
                UpdateChecker.showUpdateDialog(this, info)
            }
        }

        updateAuthStatus()

        // Check for updates silently in background
        GlobalScope.launch {
            val info = UpdateChecker.checkForUpdate(this@MainActivity)
            if (info != null) {
                pendingUpdateInfo = info
                runOnUiThread {
                    btnUpdate.visibility = View.VISIBLE
                    UpdateChecker.showUpdateDialog(this@MainActivity, info)
                }
            }
        }

        // Register FCM token if logged in
        if (AuthManager.hasToken(this)) {
            FcmTokenManager.registerToken(this)
        }

        // Initialize location manager
        locationManager = getSystemService(LOCATION_SERVICE) as LocationManager

        // Start updating UI every 2 seconds
        startUIRefresh()

        // Initialize with mock data for demonstration
        initializeMockData()

        // Auto-start tracking if permissions already granted
        val requiredPermissions = mutableListOf(
            Manifest.permission.ACCESS_FINE_LOCATION,
            Manifest.permission.ACCESS_COARSE_LOCATION
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            requiredPermissions.add(Manifest.permission.ACCESS_BACKGROUND_LOCATION)
        }

        val missingPermissions = requiredPermissions.filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }

        if (missingPermissions.isEmpty()) {
            android.util.Log.i("MainActivity", "Permissions already granted — auto-starting TrackingService")
            startTrackingService()
        } else {
            android.util.Log.i("MainActivity", "Permissions missing on startup: $missingPermissions — not auto-starting service")
        }
    }

    private fun initializeMockData() {
        // Set mock location for demonstration
        runOnUiThread {
            findViewById<TextView>(R.id.tvLatitude).text = "40.7128"
            findViewById<TextView>(R.id.tvLongitude).text = "-74.0060"
            findViewById<TextView>(R.id.tvAccuracy).text = "12.5m"
            updateServiceStatus()
        }
    }

    private fun startUIRefresh() {
        updateTimer = timer(initialDelay = 1000, period = 2000) {
            runOnUiThread {
                updateServiceStatus()
                updateServerStats()
                updateAuthStatus()
            }
        }
    }

    private fun updateServiceStatus() {
        val isServiceRunning = isTrackingServiceRunning()
        val statusText = if (isServiceRunning) "Running" else "Not Running"
        val statusIndicator = findViewById<View>(R.id.statusIndicator)
        val statusTextView = findViewById<TextView>(R.id.tvServiceStatus)

        statusTextView.text = statusText
        statusIndicator.setBackgroundResource(
            if (isServiceRunning) R.drawable.status_indicator_green else R.drawable.status_indicator
        )
    }

    private fun updateAuthStatus() {
        val hasToken = AuthManager.hasToken(this)
        val bannerVisible = !hasToken

        authStatusText.text = if (hasToken) {
            "Auth token loaded — uploads are enabled"
        } else {
            "No auth token — upload disabled. Please re-login."
        }
        authStatusText.setTextColor(
            ContextCompat.getColor(
                this,
                if (hasToken) R.color.success_green else R.color.error_red
            )
        )

        authBanner.visibility = if (bannerVisible) View.VISIBLE else View.GONE
    }

    private fun updateServerStats() {
        // Get stats from a shared tracking object
        val successCount = ServerStats.successfulRequests
        val totalCount = ServerStats.totalRequests

        findViewById<TextView>(R.id.tvSuccessCount).text = successCount.toString()
        findViewById<TextView>(R.id.tvTotalCount).text = totalCount.toString()
    }

    private fun isTrackingServiceRunning(): Boolean {
        val manager = getSystemService(ACTIVITY_SERVICE) as ActivityManager
        return manager.getRunningServices(Integer.MAX_VALUE).any {
            it.service.className == TrackingService::class.java.name
        }
    }

    override fun onResume() {
        super.onResume()
        refreshLogPanel()
        updateAuthStatus()
    }

    override fun onDestroy() {
        LiveLogManager.removeLogListener(logUpdateCallback)
        updateTimer?.cancel()
        super.onDestroy()
    }

    private fun showLogoutDialog() {
        android.util.Log.i("MainActivity", "Logout clicked")
        AlertDialog.Builder(this)
            .setTitle("Logout")
            .setMessage("Are you sure you want to logout?")
            .setPositiveButton("Yes") { _, _ ->
                AuthManager.clearToken(this@MainActivity)
                android.util.Log.i("MainActivity", "Token cleared, returning to LoginActivity")
                val intent = Intent(this@MainActivity, LoginActivity::class.java)
                intent.flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_NEW_TASK
                startActivity(intent)
                finish()
            }
            .setNegativeButton("No", null)
            .show()
    }

    private fun ensureLocationPermissionsAndStart() {
        val requiredPermissions = mutableListOf(
            Manifest.permission.ACCESS_FINE_LOCATION,
            Manifest.permission.ACCESS_COARSE_LOCATION
        )

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            requiredPermissions.add(Manifest.permission.ACCESS_BACKGROUND_LOCATION)
        }

        val missingPermissions = requiredPermissions.filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }

        if (missingPermissions.isEmpty()) {
            android.util.Log.i("MainActivity", "All location permissions granted")
            startTrackingService()
            return
        }

        android.util.Log.i("MainActivity", "Requesting location permissions: $missingPermissions")
        ActivityCompat.requestPermissions(
            this,
            missingPermissions.toTypedArray(),
            LOCATION_PERMISSION_REQUEST_CODE
        )
    }

    private fun startTrackingService() {
        try {
            ContextCompat.startForegroundService(this, Intent(this, TrackingService::class.java))
            android.util.Log.i("MainActivity", "TrackingService started successfully")
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "Failed to start TrackingService: ${e.message}", e)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        when (requestCode) {
            LOCATION_PERMISSION_REQUEST_CODE -> {
                if (grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }) {
                    android.util.Log.i("MainActivity", "Location permissions granted")
                    startTrackingService()
                } else {
                    android.util.Log.w("MainActivity", "Location permissions denied: ${permissions.joinToString()}")
                }
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
}
