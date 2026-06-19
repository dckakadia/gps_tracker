package com.example.gps_tracker

import android.Manifest
import android.app.ActivityManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.res.ColorStateList
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.view.View
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
    private val BACKGROUND_LOCATION_REQUEST_CODE = 101
    private val NOTIFICATION_PERMISSION_REQUEST_CODE = 102
    private var locationManager: LocationManager? = null
    private var updateTimer: Timer? = null
    private lateinit var authStatusText: TextView
    private lateinit var authBanner: View
    private lateinit var authRetryButton: MaterialButton
    private lateinit var btnUpdate: MaterialButton
    private var pendingUpdateInfo: UpdateChecker.VersionInfo? = null
    private var batteryBannerDismissed = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

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

        // Battery optimization warning banner
        findViewById<View>(R.id.batteryBanner).setOnClickListener {
            requestIgnoreBatteryOptimizations()
        }
        findViewById<TextView>(R.id.batteryBannerDismiss).setOnClickListener {
            batteryBannerDismissed = true
            findViewById<View>(R.id.batteryBanner).visibility = View.GONE
        }

        // Show current version in header. Long-press opens the hidden debug screen.
        findViewById<TextView>(R.id.tvAppVersion).apply {
            text = "v${BuildConfig.VERSION_NAME}"
            setOnLongClickListener {
                startActivity(Intent(this@MainActivity, DebugActivity::class.java))
                true
            }
        }

        // Update button wires to cached update info
        btnUpdate = findViewById(R.id.btnUpdate)
        btnUpdate.setOnClickListener {
            pendingUpdateInfo?.let { info ->
                UpdateChecker.showUpdateDialog(this, info)
            }
        }

        createNotificationChannel()
        requestNotificationPermission()

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

        // Schedule watchdog to restart TrackingService if Samsung battery optimizer kills it
        ServiceWatchdogWorker.schedule(this)

        // Initialize location manager
        locationManager = getSystemService(LOCATION_SERVICE) as LocationManager

        // Start updating UI every 2 seconds
        startUIRefresh()

        // Auto-start tracking if all permissions granted, or kick off the two-step request flow
        ensureLocationPermissionsAndStart()
    }

    private fun startUIRefresh() {
        updateTimer = timer(initialDelay = 1000, period = 2000) {
            runOnUiThread {
                updateServiceStatus()
                updateCheckIn()
                updateAuthStatus()
                updateOverallStatus()
            }
        }
    }

    private fun updateServiceStatus() {
        val isServiceRunning = isTrackingServiceRunning()
        val statusIndicator = findViewById<View>(R.id.statusIndicator)
        val statusTextView  = findViewById<TextView>(R.id.tvServiceStatus)

        if (!isServiceRunning) {
            statusTextView.text = "Tracking OFF"
            statusIndicator.setBackgroundResource(R.drawable.status_indicator)
        } else {
            statusIndicator.setBackgroundResource(R.drawable.status_indicator_green)
            statusTextView.text = when (TrackingService.currentState) {
                TrackingService.State.MOVING     -> "Tracking: Moving"
                TrackingService.State.STATIONARY -> "Tracking: Standby"
            }
        }
        updateStartButton(isServiceRunning)
    }

    private fun updateStartButton(isRunning: Boolean) {
        val btn = findViewById<MaterialButton>(R.id.startTrackingButton)
        when {
            !isRunning -> {
                btn.text = "START TRACKING"
                btn.backgroundTintList = ColorStateList.valueOf(
                    ContextCompat.getColor(this, R.color.success_green)
                )
                btn.setIconResource(android.R.drawable.ic_media_play)
            }
            TrackingService.currentState == TrackingService.State.STATIONARY -> {
                btn.text = "STANDBY — GPS OFF"
                btn.backgroundTintList = ColorStateList.valueOf(
                    android.graphics.Color.parseColor("#FF9800")
                )
                btn.setIconResource(android.R.drawable.ic_lock_idle_lock)
            }
            else -> {
                btn.text = "TRACKING ACTIVE ✓"
                btn.backgroundTintList = ColorStateList.valueOf(
                    ContextCompat.getColor(this, R.color.primary)
                )
                btn.setIconResource(android.R.drawable.ic_menu_mylocation)
            }
        }
    }

    private fun updateCheckIn() {
        // TODO: no check-in endpoint exists yet. Once a server endpoint is added,
        // populate today's check-in time and compute elapsed hours from it.
        findViewById<TextView>(R.id.tvCheckIn).text = "Check-in: —"
        findViewById<TextView>(R.id.tvElapsed).text = "Elapsed: —"
    }

    private fun updateOverallStatus() {
        val statusView       = findViewById<TextView>(R.id.tvOverallStatus)
        val hasToken         = AuthManager.hasToken(this)
        val isServiceRunning = isTrackingServiceRunning()

        when {
            !hasToken -> {
                statusView.text = "Tap to fix — re-login required"
                statusView.setTextColor(ContextCompat.getColor(this, R.color.error_red))
            }
            !isServiceRunning -> {
                statusView.text = "Tap to fix — start tracking"
                statusView.setTextColor(ContextCompat.getColor(this, R.color.error_red))
            }
            TrackingService.currentState == TrackingService.State.STATIONARY -> {
                statusView.text = "Standby — GPS off, accelerometer armed"
                statusView.setTextColor(android.graphics.Color.parseColor("#FF9800"))
            }
            else -> {
                statusView.text = "All good ✓"
                statusView.setTextColor(ContextCompat.getColor(this, R.color.success_green))
            }
        }
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

    private fun isTrackingServiceRunning(): Boolean {
        val manager = getSystemService(ACTIVITY_SERVICE) as ActivityManager
        return manager.getRunningServices(Integer.MAX_VALUE).any {
            it.service.className == TrackingService::class.java.name
        }
    }

    override fun onResume() {
        super.onResume()
        updateAuthStatus()
        updateBatteryBanner()
        // If the user just came back from the system Settings page after granting
        // background location, start the service without requiring another tap.
        if (!isTrackingServiceRunning()) {
            ensureLocationPermissionsAndStart()
        }
    }

    private fun updateBatteryBanner() {
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        val ignoring = pm.isIgnoringBatteryOptimizations(packageName)
        val banner = findViewById<View>(R.id.batteryBanner)
        banner.visibility = if (!ignoring && !batteryBannerDismissed) View.VISIBLE else View.GONE
    }

    private fun requestIgnoreBatteryOptimizations() {
        try {
            val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
            intent.data = Uri.parse("package:$packageName")
            startActivity(intent)
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "Could not open battery optimization settings: ${e.message}")
        }
    }

    override fun onDestroy() {
        updateTimer?.cancel()
        super.onDestroy()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                GpsTrackerMessagingService.CHANNEL_ID,
                "GPS Tracker Alerts",
                NotificationManager.IMPORTANCE_HIGH
            ).apply { description = "Admin alerts from GPS Tracker" }
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
    }

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED
            ) {
                ActivityCompat.requestPermissions(
                    this,
                    arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                    NOTIFICATION_PERMISSION_REQUEST_CODE
                )
            }
        }
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
        val hasFine = ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        val hasCoarse = ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED

        // Step 1 — foreground location (FINE + COARSE) must be granted first.
        if (!hasFine && !hasCoarse) {
            android.util.Log.i("MainActivity", "Requesting foreground location permissions")
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION),
                LOCATION_PERMISSION_REQUEST_CODE
            )
            return
        }

        // Step 2 — on Android 10+, background location ("Allow all the time") must be requested
        // in a SEPARATE requestPermissions call after foreground is granted.
        // Combining them in one call causes Android 11+ to silently ignore the background request.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val hasBackground = ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_BACKGROUND_LOCATION) == PackageManager.PERMISSION_GRANTED
            if (!hasBackground) {
                android.util.Log.i("MainActivity", "Requesting background location permission (Allow all the time)")
                ActivityCompat.requestPermissions(
                    this,
                    arrayOf(Manifest.permission.ACCESS_BACKGROUND_LOCATION),
                    BACKGROUND_LOCATION_REQUEST_CODE
                )
                return
            }
        }

        android.util.Log.i("MainActivity", "All location permissions granted — starting TrackingService")
        startTrackingService()
    }

    private fun startTrackingService() {
        try {
            ContextCompat.startForegroundService(this, Intent(this, TrackingService::class.java))
            android.util.Log.i("MainActivity", "TrackingService started successfully")
            // Immediately upload last known location so the user appears online without waiting
            val forceIntent = Intent(this, TrackingService::class.java).apply {
                action = TrackingService.ACTION_FORCE_UPLOAD
            }
            startService(forceIntent)
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
                val granted = grantResults.isNotEmpty() && grantResults.any { it == PackageManager.PERMISSION_GRANTED }
                if (granted) {
                    // Foreground granted — now run step 2 (background request) if needed
                    android.util.Log.i("MainActivity", "Foreground location granted — checking background")
                    ensureLocationPermissionsAndStart()
                } else {
                    android.util.Log.w("MainActivity", "Foreground location denied — tracking cannot start")
                }
            }
            BACKGROUND_LOCATION_REQUEST_CODE -> {
                if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                    android.util.Log.i("MainActivity", "Background location granted — starting TrackingService")
                    startTrackingService()
                } else {
                    android.util.Log.w("MainActivity", "Background location denied — tracking will not work in background")
                }
            }
            NOTIFICATION_PERMISSION_REQUEST_CODE -> {
                if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                    android.util.Log.i("MainActivity", "Notification permission granted")
                } else {
                    android.util.Log.w("MainActivity", "Notification permission denied — push notifications won't show")
                }
            }
        }
    }
}
