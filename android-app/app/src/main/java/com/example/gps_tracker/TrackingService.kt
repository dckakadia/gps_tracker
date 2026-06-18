package com.example.gps_tracker

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.hardware.Sensor
import android.hardware.SensorManager
import android.hardware.TriggerEvent
import android.hardware.TriggerEventListener
import android.location.Location
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.work.Constraints
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlin.math.abs

class TrackingService : Service() {

    // Public-facing state — read by MainActivity and DebugActivity via companion fields.
    // Written only by enterMovingState() and enterStationaryState() inside this service.
    enum class State { MOVING, STATIONARY }

    companion object {
        const val ACTION_FORCE_UPLOAD = "com.example.gps_tracker.ACTION_FORCE_UPLOAD"

        // Observed by UI — updated on every state transition
        @Volatile var currentState: State = State.MOVING
        @Volatile var nextHeartbeatAt: Long = 0L          // epoch ms; 0 = not scheduled
        @Volatile var isMotionSensorAvailable: Boolean = false

        private const val MOVING_INTERVAL_MS        = 30_000L
        private const val STATIONARY_TIMEOUT_MS     = 3 * 60 * 1000L
        private const val STATIONARY_SPEED_MS       = 0.5f
        private const val HEADING_THRESHOLD_DEG     = 15f
        private const val SPEED_DELTA_THRESHOLD_MS  = 3f
        private const val HEARTBEAT_INTERVAL_MS     = 4 * 60 * 60 * 1000L
    }

    private val AUTH_NOTIFICATION_CHANNEL_ID = "gps_tracker_auth_channel"
    private val AUTH_NOTIFICATION_ID = 2

    private lateinit var fusedLocationClient: FusedLocationProviderClient
    private lateinit var locationCallback: LocationCallback
    private lateinit var locationHandlerThread: HandlerThread
    private lateinit var sensorManager: SensorManager

    private val serviceScope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val mainHandler  = Handler(Looper.getMainLooper())

    // Batch upload state
    private val pendingPoints    = mutableListOf<LocationEntity>()
    private var lastUploadTime   = 0L
    private val BATCH_SIZE       = 3
    private val BATCH_INTERVAL_MS = 8 * 60 * 1000L

    // Adaptive motion state — all written only from locationHandlerThread
    private var lastMovementTime  = System.currentTimeMillis()
    private var lastHeading: Float? = null
    private var lastSpeed: Float    = 0f

    // forceNextUpload: written inside synchronized(pendingPoints) from locationHandlerThread;
    // read and reset inside synchronized(pendingPoints) from Dispatchers.IO coroutines.
    // @Volatile ensures cross-thread read visibility even though synchronized is the primary gate.
    @Volatile private var forceNextUpload = false

    // Battery state
    @Volatile private var isLowBattery = false

    // ── Significant-motion accelerometer trigger ──────────────────────────────
    // TYPE_SIGNIFICANT_MOTION is a hardware coprocessor one-shot trigger: fires
    // once when the device starts moving, then auto-cancels. Zero CPU cost while idle.
    private var significantMotionSensor: Sensor? = null
    private val significantMotionListener = object : TriggerEventListener() {
        override fun onTrigger(event: TriggerEvent) {
            android.util.Log.i("TrackingService", "Accelerometer wake: motion detected")
            LogPersistor.append(this@TrackingService, "TrackingService", "Accelerometer wake → entering MOVING state")
            enterMovingState()
        }
    }

    // ── 4-hour stationary heartbeat ───────────────────────────────────────────
    private val heartbeatRunnable = object : Runnable {
        override fun run() {
            if (currentState != State.STATIONARY) return
            android.util.Log.i("TrackingService", "4-hour stationary heartbeat")
            LogPersistor.append(this@TrackingService, "TrackingService", "4-hour stationary heartbeat ping")
            sendHeartbeatPing()
            nextHeartbeatAt = System.currentTimeMillis() + HEARTBEAT_INTERVAL_MS
            mainHandler.postDelayed(this, HEARTBEAT_INTERVAL_MS)
        }
    }

    // ── Battery change receiver ───────────────────────────────────────────────
    // ACTION_BATTERY_CHANGED is sticky — fires immediately on register.
    private val batteryReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
            val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
            if (scale <= 0) return
            val pct = level * 100 / scale
            val nowLow = pct in 1..19
            if (nowLow != isLowBattery) {
                isLowBattery = nowLow
                android.util.Log.i("TrackingService", "Battery profile switched: low=$isLowBattery ($pct%)")
                LogPersistor.append(context, "TrackingService", "Battery profile switched: low=$isLowBattery ($pct%)")
                if (currentState == State.MOVING) restartLocationUpdates()
            }
        }
    }

    // ── Lifecycle ─────────────────────────────────────────────────────────────

    override fun onCreate() {
        super.onCreate()
        try {
            android.util.Log.i("TrackingService", "===== TrackingService.onCreate() START =====")

            // CRITICAL: startForeground must be called before any other work on Android 12+
            startForegroundServiceNotification()
            android.util.Log.i("TrackingService", "✓ Foreground notification started FIRST")

            val batteryFilter = IntentFilter(Intent.ACTION_BATTERY_CHANGED)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(batteryReceiver, batteryFilter, RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("UnspecifiedRegisterReceiverFlag")
                registerReceiver(batteryReceiver, batteryFilter)
            }
            android.util.Log.i("TrackingService", "✓ Battery receiver registered")

            sensorManager = getSystemService(Context.SENSOR_SERVICE) as SensorManager
            significantMotionSensor = sensorManager.getDefaultSensor(Sensor.TYPE_SIGNIFICANT_MOTION)
            isMotionSensorAvailable = significantMotionSensor != null
            android.util.Log.i("TrackingService",
                "Significant motion sensor: ${if (isMotionSensorAvailable) "available" else "NOT available — stationary wake requires manual restart"}")

            fusedLocationClient = LocationServices.getFusedLocationProviderClient(this)
            android.util.Log.i("TrackingService", "✓ FusedLocationProviderClient initialized")

            locationCallback = object : LocationCallback() {
                override fun onLocationResult(result: LocationResult) {
                    super.onLocationResult(result)
                    android.util.Log.i("TrackingService", "Got ${result.locations.size} location update(s)")
                    result.locations.forEach { location ->
                        android.util.Log.d("TrackingService",
                            "Location: lat=${location.latitude}, lng=${location.longitude}, spd=${"%.1f".format(location.speed)}m/s, bearing=${location.bearing.toInt()}°")
                        LiveLogManager.log("🔄", "GPS: ${location.latitude}, ${location.longitude} (acc: ${location.accuracy.toInt()}m, spd: ${"%.1f".format(location.speed)}m/s)")
                        onLocationReceived(location)
                    }
                }
            }
            android.util.Log.i("TrackingService", "✓ LocationCallback initialized")

            if (!hasRequiredLocationPermissions()) {
                android.util.Log.e("TrackingService", "Cannot start: missing location permissions")
                LogPersistor.append(this, "TrackingService", "Cannot start location updates: required location permissions are missing")
                warnBackgroundPermissionMissing()
                return
            }

            enterMovingState()
            android.util.Log.i("TrackingService", "===== TrackingService.onCreate() SUCCESS =====")
        } catch (e: Exception) {
            android.util.Log.e("TrackingService", "❌ CRITICAL ERROR in onCreate(): ${e.message}", e)
        }
    }

    // ── State machine ─────────────────────────────────────────────────────────

    private fun enterMovingState() {
        // Guard: skip if already moving with a live handler thread
        if (currentState == State.MOVING
            && ::locationHandlerThread.isInitialized
            && locationHandlerThread.isAlive) return

        currentState     = State.MOVING
        nextHeartbeatAt  = 0L
        lastMovementTime = System.currentTimeMillis()
        lastHeading      = null
        lastSpeed        = 0f

        mainHandler.removeCallbacks(heartbeatRunnable)
        significantMotionSensor?.let {
            sensorManager.cancelTriggerSensor(significantMotionListener, it)
        }

        updateNotificationText("Tracking active — monitoring movement")
        startLocationUpdates()
        android.util.Log.i("TrackingService", "→ MOVING: GPS on (30 s, HIGH_ACCURACY${if (isLowBattery) ", low-battery" else ""})")
        LogPersistor.append(this, "TrackingService", "Entered MOVING state")
    }

    private fun enterStationaryState() {
        currentState    = State.STATIONARY

        // Stop GPS to cut power draw immediately
        try {
            if (::fusedLocationClient.isInitialized && ::locationCallback.isInitialized) {
                fusedLocationClient.removeLocationUpdates(locationCallback)
            }
            if (::locationHandlerThread.isInitialized) locationHandlerThread.quitSafely()
        } catch (e: Exception) {
            android.util.Log.e("TrackingService", "Error stopping location updates: ${e.message}")
        }

        // Arm one-shot accelerometer wake trigger
        significantMotionSensor?.let {
            sensorManager.requestTriggerSensor(significantMotionListener, it)
            android.util.Log.i("TrackingService", "Significant motion trigger armed")
        } ?: android.util.Log.w("TrackingService",
            "No TYPE_SIGNIFICANT_MOTION sensor — device will stay sleeping until manual resume")

        // Start 4-hour heartbeat and record its scheduled time for the debug UI
        nextHeartbeatAt = System.currentTimeMillis() + HEARTBEAT_INTERVAL_MS
        mainHandler.postDelayed(heartbeatRunnable, HEARTBEAT_INTERVAL_MS)

        updateNotificationText("Deep sleep — GPS off, accelerometer wake enabled")
        android.util.Log.i("TrackingService", "→ STATIONARY: GPS off, accelerometer armed, heartbeat in 4 h")
        LogPersistor.append(this, "TrackingService", "Entered STATIONARY state: GPS off, accelerometer armed, heartbeat scheduled")
    }

    // ── Location handling ─────────────────────────────────────────────────────

    internal fun onLocationReceived(location: Location) {
        val speed   = if (location.hasSpeed()) location.speed else 0f
        val heading = if (location.hasBearing()) location.bearing else null

        // Detect maneuver events: sharp turn or sudden speed change.
        // The flag write is inside synchronized(pendingPoints) to match the invariant:
        // all forceNextUpload mutations (write AND reset) happen under the same lock.
        var isManeuver = false
        if (heading != null && lastHeading != null) {
            val delta = headingDiff(heading, lastHeading!!)
            if (delta > HEADING_THRESHOLD_DEG) {
                android.util.Log.i("TrackingService", "Sharp turn detected: ${delta.toInt()}° — forcing immediate upload")
                LiveLogManager.log("↩️", "Sharp turn: ${delta.toInt()}° change")
                isManeuver = true
            }
        }
        if (abs(speed - lastSpeed) > SPEED_DELTA_THRESHOLD_MS) {
            android.util.Log.i("TrackingService", "Speed change: ${"%.1f".format(abs(speed - lastSpeed))} m/s — forcing immediate upload")
            LiveLogManager.log("⚡", "Speed change: ${"%.1f".format(abs(speed - lastSpeed))} m/s")
            isManeuver = true
        }
        // Write inside the lock so any Dispatchers.IO coroutine reading the flag sees a
        // consistent value with respect to the pendingPoints list it will drain.
        if (isManeuver) synchronized(pendingPoints) { forceNextUpload = true }

        lastHeading = heading
        lastSpeed   = speed

        // Track last time the device was actually moving
        if (speed > STATIONARY_SPEED_MS) {
            lastMovementTime = System.currentTimeMillis()
        } else if (System.currentTimeMillis() - lastMovementTime > STATIONARY_TIMEOUT_MS) {
            android.util.Log.i("TrackingService", "No movement for 3 min — entering stationary deep sleep")
            // Capture this final point before sleeping
            processLocation(location)
            enterStationaryState()
            return
        }

        processLocation(location)
    }

    // Shortest angular distance between two compass headings (0–360°).
    // internal so unit tests in the same module can call it directly.
    internal fun headingDiff(a: Float, b: Float): Float {
        var diff = abs(a - b) % 360f
        if (diff > 180f) diff = 360f - diff
        return diff
    }

    // ── GPS request builder ───────────────────────────────────────────────────

    private fun buildLocationRequest(): LocationRequest {
        // Always HIGH_ACCURACY while moving so we get valid bearing + speed data.
        // Low battery doubles the interval to reduce wake-ups.
        val intervalMs = if (isLowBattery) MOVING_INTERVAL_MS * 2 else MOVING_INTERVAL_MS
        return LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, intervalMs)
            .setMinUpdateIntervalMillis(intervalMs / 2)
            .setMinUpdateDistanceMeters(if (isLowBattery) 30f else 10f)
            .build()
    }

    private fun startLocationUpdates() {
        if (!hasRequiredLocationPermissions()) { warnBackgroundPermissionMissing(); return }
        try {
            if (::locationHandlerThread.isInitialized && locationHandlerThread.isAlive) {
                locationHandlerThread.quitSafely()
            }
            locationHandlerThread = HandlerThread("LocationHandlerThread").also { it.start() }
            fusedLocationClient.requestLocationUpdates(buildLocationRequest(), locationCallback, locationHandlerThread.looper)
            android.util.Log.i("TrackingService",
                "Location updates started — ${if (isLowBattery) MOVING_INTERVAL_MS * 2 / 1000 else MOVING_INTERVAL_MS / 1000}s, HIGH_ACCURACY")
        } catch (e: Exception) {
            android.util.Log.e("TrackingService", "Error requesting location updates", e)
        }
    }

    // Called when the battery threshold crosses to re-subscribe with the updated interval
    private fun restartLocationUpdates() {
        if (!hasRequiredLocationPermissions()) return
        try {
            fusedLocationClient.removeLocationUpdates(locationCallback)
            if (::locationHandlerThread.isInitialized && locationHandlerThread.isAlive) locationHandlerThread.quitSafely()
            locationHandlerThread = HandlerThread("LocationHandlerThread").also { it.start() }
            fusedLocationClient.requestLocationUpdates(buildLocationRequest(), locationCallback, locationHandlerThread.looper)
            android.util.Log.i("TrackingService",
                "Location updates restarted — profile: ${if (isLowBattery) "LOW_BATTERY (60 s)" else "NORMAL (30 s)"}")
        } catch (e: Exception) {
            android.util.Log.e("TrackingService", "Error restarting location updates: ${e.message}", e)
        }
    }

    // ── Upload logic ──────────────────────────────────────────────────────────

    private fun processLocation(location: Location) {
        serviceScope.launch {
            try {
                android.util.Log.d("TrackingService", ">>> processLocation() START")
                val batteryLevel = getBatteryLevel()
                val point = LocationEntity(
                    latitude     = location.latitude,
                    longitude    = location.longitude,
                    recordedAt   = System.currentTimeMillis(),
                    batteryLevel = batteryLevel,
                )
                android.util.Log.d("TrackingService", "Processing: lat=${location.latitude}, lng=${location.longitude}, battery=$batteryLevel%")
                LiveLogManager.log("🔋", "Battery: $batteryLevel%")

                val dao   = AppDatabase.getInstance(this@TrackingService).locationDao()
                val token = AuthManager.getToken(this@TrackingService)
                token?.let { ApiClient.setToken(it) }

                if (token == null) {
                    android.util.Log.w("TrackingService", "No auth token — storing offline")
                    showAuthMissingNotification()
                    LogPersistor.append(this@TrackingService, "TrackingService", "No auth token; storing offline: lat=${point.latitude}, lng=${point.longitude}")
                    dao.insert(point)
                    scheduleSyncJob()
                    return@launch
                }

                if (!NetworkUtils.isInternetAvailable(this@TrackingService)) {
                    android.util.Log.w("TrackingService", "No internet — storing offline")
                    dao.insert(point)
                    scheduleSyncJob()
                    return@launch
                }

                synchronized(pendingPoints) { pendingPoints.add(point) }

                val now = System.currentTimeMillis()
                val shouldUpload = synchronized(pendingPoints) {
                    // forceNextUpload read and reset are both inside this lock —
                    // matching the write site in onLocationReceived.
                    val maneuver = forceNextUpload
                    if (maneuver) forceNextUpload = false
                    maneuver || pendingPoints.size >= BATCH_SIZE || (now - lastUploadTime) >= BATCH_INTERVAL_MS
                }

                if (shouldUpload) {
                    val batch = synchronized(pendingPoints) {
                        val copy = pendingPoints.toList()
                        pendingPoints.clear()
                        copy
                    }
                    if (batch.isNotEmpty()) {
                        android.util.Log.d("TrackingService", "Uploading batch of ${batch.size} points")
                        LogPersistor.append(this@TrackingService, "TrackingService", "Uploading batch of ${batch.size} points")
                        val success = ApiClient.uploadLocations(this@TrackingService, batch)
                        lastUploadTime = now
                        if (success) {
                            android.util.Log.i("TrackingService", "✓ Batch uploaded: ${batch.size} points")
                            LogPersistor.append(this@TrackingService, "TrackingService", "Batch upload succeeded: ${batch.size} points")
                        } else {
                            android.util.Log.w("TrackingService", "❌ Batch upload failed — storing offline")
                            LogPersistor.append(this@TrackingService, "TrackingService", "Batch upload failed; persisting offline")
                            for (p in batch) dao.insert(p)
                            scheduleSyncJob()
                        }
                    }
                }
                android.util.Log.d("TrackingService", "<<< processLocation() END")
            } catch (e: SecurityException) {
                android.util.Log.e("TrackingService", "❌ SECURITY EXCEPTION: ${e.message}", e)
            } catch (e: Exception) {
                android.util.Log.e("TrackingService", "❌ ERROR processing location: ${e.message}", e)
            }
        }
    }

    // Sends a single-point ping using the last cached location to prove the device is alive.
    // Called only while stationary, so last known coordinates are still accurate.
    private fun sendHeartbeatPing() {
        if (!hasRequiredLocationPermissions()) return
        try {
            fusedLocationClient.lastLocation.addOnSuccessListener { location ->
                if (location == null) {
                    android.util.Log.i("TrackingService", "Heartbeat: no cached location, skipping")
                    return@addOnSuccessListener
                }
                serviceScope.launch {
                    val batteryLevel = getBatteryLevel()
                    val point = LocationEntity(
                        latitude     = location.latitude,
                        longitude    = location.longitude,
                        recordedAt   = System.currentTimeMillis(),
                        batteryLevel = batteryLevel,
                    )
                    val token = AuthManager.getToken(this@TrackingService) ?: return@launch
                    ApiClient.setToken(token)
                    if (!NetworkUtils.isInternetAvailable(this@TrackingService)) return@launch
                    val ok = ApiClient.uploadLocations(this@TrackingService, listOf(point))
                    android.util.Log.i("TrackingService", "Heartbeat ping: ${if (ok) "✓ sent" else "❌ failed"}")
                    LogPersistor.append(this@TrackingService, "TrackingService", "Heartbeat ping: ${if (ok) "sent" else "failed"}")
                }
            }
        } catch (e: Exception) {
            android.util.Log.e("TrackingService", "Heartbeat error: ${e.message}", e)
        }
    }

    private fun scheduleSyncJob() {
        val workRequest = OneTimeWorkRequestBuilder<SyncWorker>()
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .build()
        WorkManager.getInstance(this).enqueue(workRequest)
    }

    // ── Service lifecycle ─────────────────────────────────────────────────────

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_FORCE_UPLOAD) forceImmediateUpload()
        return START_STICKY
    }

    @androidx.annotation.RequiresPermission(anyOf = [Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION])
    private fun forceImmediateUpload() {
        lastUploadTime = 0L
        if (currentState == State.STATIONARY) enterMovingState()
        android.util.Log.i("TrackingService", "Force upload requested — fetching last known location")
        try {
            fusedLocationClient.lastLocation.addOnSuccessListener { location ->
                if (location != null) {
                    android.util.Log.i("TrackingService", "Force upload: processing last known location")
                    serviceScope.launch { processLocation(location) }
                } else {
                    android.util.Log.w("TrackingService", "Force upload: last location null — will upload on next GPS fix")
                }
            }
        } catch (e: Exception) {
            android.util.Log.e("TrackingService", "Force upload error: ${e.message}", e)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        serviceScope.cancel()
        mainHandler.removeCallbacksAndMessages(null)
        try { unregisterReceiver(batteryReceiver) } catch (_: Exception) {}
        significantMotionSensor?.let {
            try { sensorManager.cancelTriggerSensor(significantMotionListener, it) } catch (_: Exception) {}
        }
        try {
            if (::fusedLocationClient.isInitialized && ::locationCallback.isInitialized) {
                fusedLocationClient.removeLocationUpdates(locationCallback)
            }
        } catch (e: Exception) {
            android.util.Log.e("TrackingService", "Error removing location updates: ${e.message}", e)
        }
        if (::locationHandlerThread.isInitialized) locationHandlerThread.quitSafely()
        super.onDestroy()
    }

    // ── Notification helpers ──────────────────────────────────────────────────

    private fun startForegroundServiceNotification() {
        val channelId = "gps_tracker_channel"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(channelId, "Location Tracking", NotificationManager.IMPORTANCE_LOW)
            getSystemService(NotificationManager::class.java)?.createNotificationChannel(channel)
        }
        val notification: Notification = NotificationCompat.Builder(this, channelId)
            .setContentTitle("Employee Location Tracking")
            .setContentText("Location service is running")
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
        startForeground(1, notification)
    }

    private fun updateNotificationText(text: String) {
        val channelId = "gps_tracker_channel"
        val notification: Notification = NotificationCompat.Builder(this, channelId)
            .setContentTitle("Employee Location Tracking")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
        getSystemService(NotificationManager::class.java)?.notify(1, notification)
    }

    private fun createAuthNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                AUTH_NOTIFICATION_CHANNEL_ID,
                "GPS Tracker Auth Alerts",
                NotificationManager.IMPORTANCE_HIGH
            )
            channel.description = "Notifications when auth token is missing or expired"
            getSystemService(NotificationManager::class.java)?.createNotificationChannel(channel)
        }
    }

    private fun showAuthMissingNotification() {
        createAuthNotificationChannel()
        val notification = NotificationCompat.Builder(this, AUTH_NOTIFICATION_CHANNEL_ID)
            .setContentTitle("Auth token missing")
            .setContentText("Upload disabled. Re-login to restore server sync.")
            .setSmallIcon(android.R.drawable.ic_dialog_alert)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .build()
        getSystemService(NotificationManager::class.java)?.notify(AUTH_NOTIFICATION_ID, notification)
    }

    // ── Utility ───────────────────────────────────────────────────────────────

    private fun getBatteryLevel(): Int {
        return try {
            val bm = getSystemService(BATTERY_SERVICE) as BatteryManager
            bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        } catch (e: Exception) {
            android.util.Log.w("TrackingService", "Failed to read battery level: ${e.message}")
            -1
        }
    }

    private fun hasRequiredLocationPermissions(): Boolean {
        val hasFine   = ActivityCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION)   == PackageManager.PERMISSION_GRANTED
        val hasCoarse = ActivityCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
        val hasBackground = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ActivityCompat.checkSelfPermission(this, Manifest.permission.ACCESS_BACKGROUND_LOCATION) == PackageManager.PERMISSION_GRANTED
        } else true
        val hasFgService = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            ActivityCompat.checkSelfPermission(this, Manifest.permission.FOREGROUND_SERVICE_LOCATION) == PackageManager.PERMISSION_GRANTED
        } else true
        return (hasFine || hasCoarse) && hasBackground && hasFgService
    }

    private fun warnBackgroundPermissionMissing() {
        android.util.Log.e("TrackingService", "Location permissions not granted or background access denied. Tracking cannot start.")
        LogPersistor.append(this, "TrackingService", "Location permissions not granted or background access denied.")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            android.util.Log.w("TrackingService", "Missing ACCESS_BACKGROUND_LOCATION on Android 10+.")
        }
    }
}
