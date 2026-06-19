package com.example.gps_tracker

import android.Manifest
import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
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
import android.os.SystemClock
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.work.Constraints
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import com.google.android.gms.location.ActivityRecognition
import com.google.android.gms.location.ActivityTransition
import com.google.android.gms.location.ActivityTransitionRequest
import com.google.android.gms.location.DetectedActivity
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

    enum class State { MOVING, STATIONARY }

    companion object {
        const val ACTION_FORCE_UPLOAD       = "com.example.gps_tracker.ACTION_FORCE_UPLOAD"
        const val ACTION_WAKE_FROM_ACTIVITY = "com.example.gps_tracker.ACTION_WAKE_FROM_ACTIVITY"

        @Volatile var currentState: State = State.MOVING
        @Volatile var nextHeartbeatAt: Long = 0L
        @Volatile var isMotionSensorAvailable: Boolean = false

        private const val MOVING_INTERVAL_MS        = 30_000L
        private const val STATIONARY_TIMEOUT_MS     = 3 * 60 * 1000L
        private const val STATIONARY_SPEED_MS       = 0.5f
        private const val HEADING_THRESHOLD_DEG     = 15f
        private const val SPEED_DELTA_THRESHOLD_MS  = 3f
        private const val HEARTBEAT_INTERVAL_MS     = 4 * 60 * 60 * 1000L
        private const val ALARM_WAKE_INTERVAL_MS    = 15 * 60 * 1000L

        // GPS time is trusted up to ±5 min from system time. Beyond that we reject it
        // as potentially tampered or stale from a cold-start fix.
        private const val GPS_TIME_TOLERANCE_MS = 5 * 60 * 1000L
    }

    private val AUTH_NOTIFICATION_CHANNEL_ID = "gps_tracker_auth_channel"
    private val AUTH_NOTIFICATION_ID = 2

    private lateinit var fusedLocationClient: FusedLocationProviderClient
    private lateinit var locationCallback: LocationCallback
    private lateinit var locationHandlerThread: HandlerThread
    private lateinit var sensorManager: SensorManager
    private lateinit var alarmManager: AlarmManager

    private val serviceScope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val mainHandler  = Handler(Looper.getMainLooper())

    private val pendingPoints    = mutableListOf<LocationEntity>()
    private var lastUploadTime   = 0L
    private val BATCH_SIZE       = 3
    private val BATCH_INTERVAL_MS = 8 * 60 * 1000L

    private var lastMovementTime  = System.currentTimeMillis()
    private var lastHeading: Float? = null
    private var lastSpeed: Float    = 0f

    @Volatile private var forceNextUpload = false
    @Volatile private var isLowBattery = false

    // ── Significant-motion sensor ─────────────────────────────────────────────

    private var significantMotionSensor: Sensor? = null
    private val significantMotionListener = object : TriggerEventListener() {
        override fun onTrigger(event: TriggerEvent) {
            android.util.Log.i("TrackingService", "Accelerometer wake: motion detected")
            LogPersistor.append(this@TrackingService, "TrackingService",
                "Accelerometer wake → entering MOVING state")
            enterMovingState()
        }
    }

    // ── 4-hour stationary heartbeat ───────────────────────────────────────────

    private val heartbeatRunnable = object : Runnable {
        override fun run() {
            if (currentState != State.STATIONARY) return
            android.util.Log.i("TrackingService", "4-hour stationary heartbeat")
            LogPersistor.append(this@TrackingService, "TrackingService",
                "4-hour stationary heartbeat ping")
            sendHeartbeatPing()
            nextHeartbeatAt = System.currentTimeMillis() + HEARTBEAT_INTERVAL_MS
            mainHandler.postDelayed(this, HEARTBEAT_INTERVAL_MS)
        }
    }

    // ── Battery receiver ──────────────────────────────────────────────────────

    private val batteryReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
            val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
            if (scale <= 0) return
            val pct = level * 100 / scale
            val nowLow = pct in 1..19
            if (nowLow != isLowBattery) {
                isLowBattery = nowLow
                android.util.Log.i("TrackingService",
                    "Battery profile switched: low=$isLowBattery ($pct%)")
                LogPersistor.append(context, "TrackingService",
                    "Battery profile switched: low=$isLowBattery ($pct%)")
                if (currentState == State.MOVING) restartLocationUpdates()
            }
        }
    }

    // ── Lifecycle ─────────────────────────────────────────────────────────────

    override fun onCreate() {
        super.onCreate()
        try {
            android.util.Log.i("TrackingService", "===== TrackingService.onCreate() START =====")
            startForegroundServiceNotification()

            alarmManager = getSystemService(Context.ALARM_SERVICE) as AlarmManager

            val batteryFilter = IntentFilter(Intent.ACTION_BATTERY_CHANGED)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(batteryReceiver, batteryFilter, RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("UnspecifiedRegisterReceiverFlag")
                registerReceiver(batteryReceiver, batteryFilter)
            }

            sensorManager = getSystemService(Context.SENSOR_SERVICE) as SensorManager
            significantMotionSensor = sensorManager.getDefaultSensor(Sensor.TYPE_SIGNIFICANT_MOTION)
            isMotionSensorAvailable = significantMotionSensor != null
            android.util.Log.i("TrackingService",
                "Significant motion sensor: ${if (isMotionSensorAvailable) "available" else "NOT available — AlarmManager fallback will be used"}")

            fusedLocationClient = LocationServices.getFusedLocationProviderClient(this)

            locationCallback = object : LocationCallback() {
                override fun onLocationResult(result: LocationResult) {
                    super.onLocationResult(result)
                    result.locations.forEach { location ->
                        android.util.Log.d("TrackingService",
                            "Location: lat=${location.latitude}, lng=${location.longitude}, " +
                            "spd=${"%.1f".format(location.speed)}m/s, bearing=${location.bearing.toInt()}°, " +
                            "mock=${isMockLocation(location)}")
                        LiveLogManager.log("🔄",
                            "GPS: ${location.latitude}, ${location.longitude} " +
                            "(acc: ${location.accuracy.toInt()}m, spd: ${"%.1f".format(location.speed)}m/s" +
                            "${if (isMockLocation(location)) ", ⚠ MOCK" else ""})")
                        onLocationReceived(location)
                    }
                }
            }

            if (!hasRequiredLocationPermissions()) {
                android.util.Log.e("TrackingService", "Cannot start: missing location permissions")
                LogPersistor.append(this, "TrackingService",
                    "Cannot start location updates: required location permissions are missing")
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
        cancelStationaryWakeAlarm()
        deregisterActivityTransitions()

        updateNotificationText("Tracking active — monitoring movement")
        startLocationUpdates()
        android.util.Log.i("TrackingService",
            "→ MOVING: GPS on (${if (isLowBattery) 60 else 30}s, HIGH_ACCURACY)")
        LogPersistor.append(this, "TrackingService", "Entered MOVING state")
    }

    private fun enterStationaryState() {
        currentState = State.STATIONARY

        try {
            if (::fusedLocationClient.isInitialized && ::locationCallback.isInitialized) {
                fusedLocationClient.removeLocationUpdates(locationCallback)
            }
            if (::locationHandlerThread.isInitialized) locationHandlerThread.quitSafely()
        } catch (e: Exception) {
            android.util.Log.e("TrackingService",
                "Error stopping location updates: ${e.message}")
        }

        // Primary wake: hardware significant-motion sensor (zero CPU cost).
        // Fallback: AlarmManager polling for devices that lack the sensor.
        if (significantMotionSensor != null) {
            sensorManager.requestTriggerSensor(significantMotionListener, significantMotionSensor!!)
            android.util.Log.i("TrackingService", "Significant motion trigger armed")
        } else {
            android.util.Log.w("TrackingService",
                "No TYPE_SIGNIFICANT_MOTION sensor — scheduling 15-minute AlarmManager fallback")
            scheduleStationaryWakeAlarm()
        }

        // Always register Activity Recognition transitions as a secondary wake signal.
        registerActivityTransitions()

        nextHeartbeatAt = System.currentTimeMillis() + HEARTBEAT_INTERVAL_MS
        mainHandler.postDelayed(heartbeatRunnable, HEARTBEAT_INTERVAL_MS)

        updateNotificationText("Deep sleep — GPS off, accelerometer wake enabled")
        android.util.Log.i("TrackingService",
            "→ STATIONARY: GPS off, wake mechanisms armed, heartbeat in 4 h")
        LogPersistor.append(this, "TrackingService",
            "Entered STATIONARY state: GPS off, wake mechanisms armed, heartbeat scheduled")
    }

    // ── Location handling ─────────────────────────────────────────────────────

    internal fun onLocationReceived(location: Location) {
        val speed   = if (location.hasSpeed()) location.speed else 0f
        val heading = if (location.hasBearing()) location.bearing else null
        val isMock  = isMockLocation(location)

        if (isMock) {
            android.util.Log.w("TrackingService",
                "⚠ Mock location detected — recording with is_spoofed=true, " +
                "skipping maneuver/stationary logic")
            LogPersistor.append(this, "TrackingService",
                "Mock location detected: lat=${location.latitude}, lng=${location.longitude}")
            // Still capture and upload so the server audit trail shows the attempt;
            // the is_spoofed flag tells the backend to skip attendance and geofence checks.
            processLocation(location, isSpoofed = true)
            return
        }

        // Maneuver detection — force immediate upload on sharp turn or speed burst.
        var isManeuver = false
        if (heading != null && lastHeading != null) {
            val delta = headingDiff(heading, lastHeading!!)
            if (delta > HEADING_THRESHOLD_DEG) {
                android.util.Log.i("TrackingService",
                    "Sharp turn: ${delta.toInt()}° — forcing immediate upload")
                LiveLogManager.log("↩️", "Sharp turn: ${delta.toInt()}° change")
                isManeuver = true
            }
        }
        if (abs(speed - lastSpeed) > SPEED_DELTA_THRESHOLD_MS) {
            android.util.Log.i("TrackingService",
                "Speed change: ${"%.1f".format(abs(speed - lastSpeed))} m/s — forcing upload")
            LiveLogManager.log("⚡", "Speed change: ${"%.1f".format(abs(speed - lastSpeed))} m/s")
            isManeuver = true
        }
        if (isManeuver) synchronized(pendingPoints) { forceNextUpload = true }

        lastHeading = heading
        lastSpeed   = speed

        if (speed > STATIONARY_SPEED_MS) {
            lastMovementTime = System.currentTimeMillis()
        } else if (System.currentTimeMillis() - lastMovementTime > STATIONARY_TIMEOUT_MS) {
            android.util.Log.i("TrackingService",
                "No movement for 3 min — entering stationary deep sleep")
            processLocation(location, isSpoofed = false)
            enterStationaryState()
            return
        }

        processLocation(location, isSpoofed = false)
    }

    internal fun headingDiff(a: Float, b: Float): Float {
        var diff = abs(a - b) % 360f
        if (diff > 180f) diff = 360f - diff
        return diff
    }

    // ── GPS timestamp — anti-spoofing ─────────────────────────────────────────

    /**
     * Returns a trusted recording timestamp.
     *
     * Uses location.time (GNSS hardware epoch) which is derived from satellite signals
     * and is NOT affected by the user changing the system clock in Settings.
     * If the GPS time is absent or falls outside a ±5-minute window of the system clock
     * (which would indicate a stale fix or a mock provider), we fall back to system time
     * and mark the offset in the log for backend review.
     */
    private fun trustedTimestampMs(location: Location): Long {
        val gpsTime = location.time
        if (gpsTime <= 0L) return System.currentTimeMillis()

        val systemTime = System.currentTimeMillis()
        val drift = abs(gpsTime - systemTime)
        if (drift > GPS_TIME_TOLERANCE_MS) {
            android.util.Log.w("TrackingService",
                "GPS time drift ${drift / 1000}s — using system time (possible clock tamper or cold fix)")
            LogPersistor.append(this, "TrackingService",
                "GPS time drift ${drift / 1000}s detected (gps=$gpsTime, sys=$systemTime)")
            return systemTime
        }
        return gpsTime
    }

    /**
     * Returns true when the location came from a mock/simulated provider.
     * Uses the non-deprecated isMock property on API 31+ and the legacy flag on older devices.
     */
    private fun isMockLocation(location: Location): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            location.isMock
        } else {
            @Suppress("DEPRECATION")
            location.isFromMockProvider
        }
    }

    // ── GPS request builder ───────────────────────────────────────────────────

    private fun buildLocationRequest(): LocationRequest {
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
            fusedLocationClient.requestLocationUpdates(
                buildLocationRequest(), locationCallback, locationHandlerThread.looper)
            android.util.Log.i("TrackingService",
                "Location updates started — ${if (isLowBattery) 60 else 30}s, HIGH_ACCURACY")
        } catch (e: Exception) {
            android.util.Log.e("TrackingService", "Error requesting location updates", e)
        }
    }

    private fun restartLocationUpdates() {
        if (!hasRequiredLocationPermissions()) return
        try {
            fusedLocationClient.removeLocationUpdates(locationCallback)
            if (::locationHandlerThread.isInitialized && locationHandlerThread.isAlive)
                locationHandlerThread.quitSafely()
            locationHandlerThread = HandlerThread("LocationHandlerThread").also { it.start() }
            fusedLocationClient.requestLocationUpdates(
                buildLocationRequest(), locationCallback, locationHandlerThread.looper)
            android.util.Log.i("TrackingService",
                "Location updates restarted — ${if (isLowBattery) "LOW_BATTERY (60s)" else "NORMAL (30s)"}")
        } catch (e: Exception) {
            android.util.Log.e("TrackingService",
                "Error restarting location updates: ${e.message}", e)
        }
    }

    // ── Upload logic ──────────────────────────────────────────────────────────

    private fun processLocation(location: Location, isSpoofed: Boolean) {
        serviceScope.launch {
            try {
                val batteryLevel = getBatteryLevel()
                val point = LocationEntity(
                    latitude     = location.latitude,
                    longitude    = location.longitude,
                    recordedAt   = trustedTimestampMs(location),
                    batteryLevel = batteryLevel,
                    isSpoofed    = isSpoofed,
                    accuracy     = if (location.hasAccuracy())  location.accuracy  else -1f,
                    speed        = if (location.hasSpeed())     location.speed     else -1f,
                    bearing      = if (location.hasBearing())   location.bearing   else -1f,
                )
                LiveLogManager.log("🔋", "Battery: $batteryLevel%")

                val dao   = AppDatabase.getInstance(this@TrackingService).locationDao()
                val token = AuthManager.getToken(this@TrackingService)
                token?.let { ApiClient.setToken(it) }

                if (token == null) {
                    android.util.Log.w("TrackingService", "No auth token — storing offline")
                    showAuthMissingNotification()
                    LogPersistor.append(this@TrackingService, "TrackingService",
                        "No auth token; storing offline")
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
                    val maneuver = forceNextUpload
                    if (maneuver) forceNextUpload = false
                    maneuver ||
                        pendingPoints.size >= BATCH_SIZE ||
                        (now - lastUploadTime) >= BATCH_INTERVAL_MS
                }

                if (shouldUpload) {
                    val batch = synchronized(pendingPoints) {
                        val copy = pendingPoints.toList()
                        pendingPoints.clear()
                        copy
                    }
                    if (batch.isNotEmpty()) {
                        android.util.Log.d("TrackingService",
                            "Uploading batch of ${batch.size} points " +
                            "(${batch.count { it.isSpoofed }} spoofed)")
                        LogPersistor.append(this@TrackingService, "TrackingService",
                            "Uploading batch of ${batch.size} points")
                        val success = ApiClient.uploadLocations(this@TrackingService, batch)
                        lastUploadTime = now
                        if (success) {
                            android.util.Log.i("TrackingService",
                                "✓ Batch uploaded: ${batch.size} points")
                            LogPersistor.append(this@TrackingService, "TrackingService",
                                "Batch upload succeeded: ${batch.size} points")
                        } else {
                            android.util.Log.w("TrackingService",
                                "❌ Batch upload failed — storing offline")
                            for (p in batch) dao.insert(p)
                            scheduleSyncJob()
                        }
                    }
                }
            } catch (e: SecurityException) {
                android.util.Log.e("TrackingService", "❌ SECURITY EXCEPTION: ${e.message}", e)
            } catch (e: Exception) {
                android.util.Log.e("TrackingService",
                    "❌ ERROR processing location: ${e.message}", e)
            }
        }
    }

    private fun sendHeartbeatPing() {
        if (!hasRequiredLocationPermissions()) return
        try {
            fusedLocationClient.lastLocation.addOnSuccessListener { location ->
                if (location == null) return@addOnSuccessListener
                serviceScope.launch {
                    val batteryLevel = getBatteryLevel()
                    val point = LocationEntity(
                        latitude     = location.latitude,
                        longitude    = location.longitude,
                        recordedAt   = trustedTimestampMs(location),
                        batteryLevel = batteryLevel,
                        isSpoofed    = isMockLocation(location),
                        accuracy     = if (location.hasAccuracy()) location.accuracy else -1f,
                        speed        = if (location.hasSpeed())    location.speed    else -1f,
                        bearing      = if (location.hasBearing())  location.bearing  else -1f,
                    )
                    val token = AuthManager.getToken(this@TrackingService) ?: return@launch
                    ApiClient.setToken(token)
                    if (!NetworkUtils.isInternetAvailable(this@TrackingService)) return@launch
                    val ok = ApiClient.uploadLocations(this@TrackingService, listOf(point))
                    android.util.Log.i("TrackingService",
                        "Heartbeat ping: ${if (ok) "✓ sent" else "❌ failed"}")
                    LogPersistor.append(this@TrackingService, "TrackingService",
                        "Heartbeat ping: ${if (ok) "sent" else "failed"}")
                }
            }
        } catch (e: Exception) {
            android.util.Log.e("TrackingService", "Heartbeat error: ${e.message}", e)
        }
    }

    private fun scheduleSyncJob() {
        val workRequest = OneTimeWorkRequestBuilder<SyncWorker>()
            .setConstraints(
                Constraints.Builder()
                    .setRequiredNetworkType(NetworkType.CONNECTED)
                    .build()
            )
            .build()
        WorkManager.getInstance(this).enqueue(workRequest)
    }

    // ── AlarmManager fallback (no significant-motion sensor) ──────────────────

    private fun stationaryWakePendingIntent(): PendingIntent {
        val intent = Intent(this, StationaryWakeReceiver::class.java).apply {
            action = StationaryWakeReceiver.ACTION
        }
        return PendingIntent.getBroadcast(
            this, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun scheduleStationaryWakeAlarm() {
        val triggerAt = SystemClock.elapsedRealtime() + ALARM_WAKE_INTERVAL_MS
        // ELAPSED_REALTIME_WAKEUP fires even in Doze, but only in the next maintenance window
        // on API 23+. For our use-case (15-min check) this is sufficient and battery-safe.
        alarmManager.setAndAllowWhileIdle(
            AlarmManager.ELAPSED_REALTIME_WAKEUP,
            triggerAt,
            stationaryWakePendingIntent(),
        )
        android.util.Log.i("TrackingService", "Stationary wake alarm scheduled in 15 min")
    }

    private fun cancelStationaryWakeAlarm() {
        try { alarmManager.cancel(stationaryWakePendingIntent()) } catch (_: Exception) {}
    }

    // ── Activity Recognition transitions ──────────────────────────────────────

    private fun activityTransitionPendingIntent(): PendingIntent {
        val intent = Intent(ActivityTransitionReceiver.TRANSITION_ACTION)
            .setPackage(packageName)
        return PendingIntent.getBroadcast(
            this, 1, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
        )
    }

    private fun registerActivityTransitions() {
        if (ActivityCompat.checkSelfPermission(this, Manifest.permission.ACTIVITY_RECOGNITION)
            != PackageManager.PERMISSION_GRANTED) {
            android.util.Log.w("TrackingService",
                "ACTIVITY_RECOGNITION permission not granted — skipping transition registration")
            return
        }

        val transitions = listOf(
            ActivityTransition.Builder()
                .setActivityType(DetectedActivity.IN_VEHICLE)
                .setActivityTransition(ActivityTransition.ACTIVITY_TRANSITION_ENTER)
                .build(),
            ActivityTransition.Builder()
                .setActivityType(DetectedActivity.WALKING)
                .setActivityTransition(ActivityTransition.ACTIVITY_TRANSITION_ENTER)
                .build(),
            ActivityTransition.Builder()
                .setActivityType(DetectedActivity.RUNNING)
                .setActivityTransition(ActivityTransition.ACTIVITY_TRANSITION_ENTER)
                .build(),
            ActivityTransition.Builder()
                .setActivityType(DetectedActivity.ON_BICYCLE)
                .setActivityTransition(ActivityTransition.ACTIVITY_TRANSITION_ENTER)
                .build(),
        )

        ActivityRecognition.getClient(this)
            .requestActivityTransitionUpdates(
                ActivityTransitionRequest(transitions),
                activityTransitionPendingIntent(),
            )
            .addOnSuccessListener {
                android.util.Log.i("TrackingService",
                    "Activity Recognition transitions registered")
            }
            .addOnFailureListener { e ->
                android.util.Log.e("TrackingService",
                    "Failed to register activity transitions: ${e.message}", e)
            }
    }

    private fun deregisterActivityTransitions() {
        try {
            ActivityRecognition.getClient(this)
                .removeActivityTransitionUpdates(activityTransitionPendingIntent())
                .addOnSuccessListener {
                    android.util.Log.i("TrackingService",
                        "Activity Recognition transitions deregistered")
                }
        } catch (e: Exception) {
            android.util.Log.w("TrackingService",
                "deregisterActivityTransitions: ${e.message}")
        }
    }

    // ── Service lifecycle ─────────────────────────────────────────────────────

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_FORCE_UPLOAD        -> forceImmediateUpload()
            ACTION_WAKE_FROM_ACTIVITY  -> {
                android.util.Log.i("TrackingService",
                    "Wake action received — transitioning to MOVING")
                LogPersistor.append(this, "TrackingService",
                    "ACTION_WAKE_FROM_ACTIVITY received → entering MOVING state")
                if (currentState == State.STATIONARY) enterMovingState()
            }
        }
        return START_STICKY
    }

    @androidx.annotation.RequiresPermission(
        anyOf = [Manifest.permission.ACCESS_FINE_LOCATION,
                 Manifest.permission.ACCESS_COARSE_LOCATION]
    )
    private fun forceImmediateUpload() {
        lastUploadTime = 0L
        if (currentState == State.STATIONARY) enterMovingState()
        android.util.Log.i("TrackingService",
            "Force upload requested — fetching last known location")
        try {
            fusedLocationClient.lastLocation.addOnSuccessListener { location ->
                if (location != null) {
                    serviceScope.launch {
                        processLocation(location, isSpoofed = isMockLocation(location))
                    }
                } else {
                    android.util.Log.w("TrackingService",
                        "Force upload: last location null — will upload on next GPS fix")
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
            try { sensorManager.cancelTriggerSensor(significantMotionListener, it) }
            catch (_: Exception) {}
        }
        cancelStationaryWakeAlarm()
        deregisterActivityTransitions()
        try {
            if (::fusedLocationClient.isInitialized && ::locationCallback.isInitialized) {
                fusedLocationClient.removeLocationUpdates(locationCallback)
            }
        } catch (e: Exception) {
            android.util.Log.e("TrackingService",
                "Error removing location updates: ${e.message}", e)
        }
        if (::locationHandlerThread.isInitialized) locationHandlerThread.quitSafely()
        super.onDestroy()
    }

    // ── Notification helpers ──────────────────────────────────────────────────

    private fun startForegroundServiceNotification() {
        val channelId = "gps_tracker_channel"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId, "Location Tracking", NotificationManager.IMPORTANCE_LOW)
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
                NotificationManager.IMPORTANCE_HIGH,
            )
            channel.description = "Notifications when auth token is missing or expired"
            getSystemService(NotificationManager::class.java)
                ?.createNotificationChannel(channel)
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
            android.util.Log.w("TrackingService",
                "Failed to read battery level: ${e.message}")
            -1
        }
    }

    private fun hasRequiredLocationPermissions(): Boolean {
        val hasFine = ActivityCompat.checkSelfPermission(
            this, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        val hasCoarse = ActivityCompat.checkSelfPermission(
            this, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
        val hasBackground = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ActivityCompat.checkSelfPermission(
                this, Manifest.permission.ACCESS_BACKGROUND_LOCATION) == PackageManager.PERMISSION_GRANTED
        } else true
        val hasFgService = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            ActivityCompat.checkSelfPermission(
                this, Manifest.permission.FOREGROUND_SERVICE_LOCATION) == PackageManager.PERMISSION_GRANTED
        } else true
        return (hasFine || hasCoarse) && hasBackground && hasFgService
    }

    private fun warnBackgroundPermissionMissing() {
        android.util.Log.e("TrackingService",
            "Location permissions not granted or background access denied.")
        LogPersistor.append(this, "TrackingService",
            "Location permissions not granted or background access denied.")
    }
}
