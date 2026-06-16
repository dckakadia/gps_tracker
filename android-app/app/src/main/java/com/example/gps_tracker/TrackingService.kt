package com.example.gps_tracker

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.Location
import android.os.Build
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
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

class TrackingService : Service() {
    private val AUTH_NOTIFICATION_CHANNEL_ID = "gps_tracker_auth_channel"
    private val AUTH_NOTIFICATION_ID = 2

    private lateinit var fusedLocationClient: FusedLocationProviderClient
    private lateinit var locationCallback: LocationCallback
    private lateinit var locationHandlerThread: HandlerThread

    // Batch upload state
    private val pendingPoints = mutableListOf<LocationEntity>()
    private var lastUploadTime = 0L
    private val BATCH_SIZE = 10
    private val BATCH_INTERVAL_MS = 2 * 60 * 1000L // 2 minutes

    override fun onCreate() {
        super.onCreate()
        try {
            android.util.Log.i("TrackingService", "===== TrackingService.onCreate() START =====")
            
            // CRITICAL: Call startForeground FIRST, before any other operations
            // On Android 12+, if startForeground is not called within 5 seconds, the app crashes
            startForegroundServiceNotification()
            android.util.Log.i("TrackingService", "✓ Foreground notification started FIRST")
            
            fusedLocationClient = LocationServices.getFusedLocationProviderClient(this)
            android.util.Log.i("TrackingService", "✓ FusedLocationProviderClient initialized")
            
            locationCallback = object : LocationCallback() {
                override fun onLocationResult(result: LocationResult) {
                    super.onLocationResult(result)
                    android.util.Log.i("TrackingService", "Got ${result.locations.size} location update(s)")
                    result.locations.forEach { location -> 
                        android.util.Log.d("TrackingService", "Location received: lat=${location.latitude}, lng=${location.longitude}")
                        LiveLogManager.log("🔄", "GPS: ${location.latitude}, ${location.longitude} (acc: ${location.accuracy.toInt()}m)")
                        processLocation(location) 
                    }
                }
            }
            android.util.Log.i("TrackingService", "✓ LocationCallback initialized")

            if (!hasRequiredLocationPermissions()) {
                android.util.Log.e("TrackingService", "Cannot start location updates: required location permissions are missing")
                LogPersistor.append(this, "TrackingService", "Cannot start location updates: required location permissions are missing")
                warnBackgroundPermissionMissing()
                return
            }

            startLocationUpdates()
            android.util.Log.i("TrackingService", "✓ Location updates requested")
            android.util.Log.i("TrackingService", "===== TrackingService.onCreate() SUCCESS =====")
        } catch (e: Exception) {
            android.util.Log.e("TrackingService", "❌ CRITICAL ERROR in onCreate(): ${e.message}", e)
            e.printStackTrace()
        }
    }

    private fun startForegroundServiceNotification() {
        val channelId = "gps_tracker_channel"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(channelId, "Location Tracking", NotificationManager.IMPORTANCE_LOW)
            val manager = getSystemService(NotificationManager::class.java)
            manager?.createNotificationChannel(channel)
        }

        val notification: Notification = NotificationCompat.Builder(this, channelId)
            .setContentTitle("Employee Location Tracking")
            .setContentText("Location service is running")
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()

        startForeground(1, notification)
    }

    private fun createAuthNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                AUTH_NOTIFICATION_CHANNEL_ID,
                "GPS Tracker Auth Alerts",
                NotificationManager.IMPORTANCE_HIGH
            )
            channel.description = "Notifications when auth token is missing or expired"
            val manager = getSystemService(NotificationManager::class.java)
            manager?.createNotificationChannel(channel)
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

        val manager = getSystemService(NotificationManager::class.java)
        manager?.notify(AUTH_NOTIFICATION_ID, notification)
    }

    private fun startLocationUpdates() {
        // TEST/DEBUG MODE: Use frequent updates with no displacement threshold
        // Production: interval = 10 * 60 * 1000L, smallestDisplacement = 100f
        val request = LocationRequest.create().apply {
            interval = 30 * 1000L  // 30 seconds for testing
            fastestInterval = 10 * 1000L  // 10 seconds
            smallestDisplacement = 0f  // No displacement threshold (allows rapid testing)
            priority = LocationRequest.PRIORITY_HIGH_ACCURACY
        }

        if (!hasRequiredLocationPermissions()) {
            warnBackgroundPermissionMissing()
            return
        }

        try {
            locationHandlerThread = HandlerThread("LocationHandlerThread").also { it.start() }
            fusedLocationClient.requestLocationUpdates(request, locationCallback, locationHandlerThread.looper)
            android.util.Log.i("TrackingService", "Location updates requested successfully")
        } catch (e: Exception) {
            android.util.Log.e("TrackingService", "Error requesting location updates", e)
        }
    }

    private fun hasRequiredLocationPermissions(): Boolean {
        val hasFineLocation = ActivityCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        val hasCoarseLocation = ActivityCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
        val hasBackgroundLocation = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ActivityCompat.checkSelfPermission(this, Manifest.permission.ACCESS_BACKGROUND_LOCATION) == PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
        val hasForegroundServiceLocation = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            ActivityCompat.checkSelfPermission(this, Manifest.permission.FOREGROUND_SERVICE_LOCATION) == PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
        return (hasFineLocation || hasCoarseLocation) && hasBackgroundLocation && hasForegroundServiceLocation
    }

    private fun warnBackgroundPermissionMissing() {
        android.util.Log.e("TrackingService", "Location permissions not granted or background access denied. Tracking cannot start.")
        LogPersistor.append(this, "TrackingService", "Location permissions not granted or background access denied. Tracking cannot start.")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            android.util.Log.w("TrackingService", "Missing ACCESS_BACKGROUND_LOCATION on Android 10+; request background location permission in app settings.")
            LogPersistor.append(this, "TrackingService", "Missing ACCESS_BACKGROUND_LOCATION on Android 10+; request background location permission in app settings.")
        }
    }

    private fun getBatteryLevel(): Int {
        return try {
            val batteryManager = getSystemService(BATTERY_SERVICE) as android.os.BatteryManager
            batteryManager.getIntProperty(android.os.BatteryManager.BATTERY_PROPERTY_CAPACITY)
        } catch (e: Exception) {
            android.util.Log.w("TrackingService", "Failed to read battery level: ${e.message}")
            -1
        }
    }

    private fun processLocation(location: Location) {
        CoroutineScope(Dispatchers.IO).launch {
            try {
                android.util.Log.d("TrackingService", ">>> processLocation() START")
                val batteryLevel = getBatteryLevel()
                val point = LocationEntity(
                    latitude = location.latitude,
                    longitude = location.longitude,
                    recordedAt = System.currentTimeMillis(),
                    batteryLevel = batteryLevel,
                )
                android.util.Log.d("TrackingService", "Processing location: lat=${location.latitude}, lng=${location.longitude}, battery=$batteryLevel%")
                LiveLogManager.log("🔋", "Battery: $batteryLevel%")

                val dao = AppDatabase.getInstance(this@TrackingService).locationDao()
                android.util.Log.d("TrackingService", "✓ Database DAO initialized")

                val token = AuthManager.getToken(this@TrackingService)
                android.util.Log.d("TrackingService", "Auth token: ${if (token != null) "present" else "MISSING"}")
                token?.let { ApiClient.setToken(it) }

                if (token == null) {
                    android.util.Log.w("TrackingService", "No auth token found. Storing location offline.")
                    showAuthMissingNotification()
                    LogPersistor.append(this@TrackingService, "TrackingService", "No auth token; storing offline point: lat=${point.latitude}, lng=${point.longitude}")
                    dao.insert(point)
                    scheduleSyncJob()
                    return@launch
                }

                if (!NetworkUtils.isInternetAvailable(this@TrackingService)) {
                    android.util.Log.w("TrackingService", "No internet connection. Storing location offline.")
                    dao.insert(point)
                    scheduleSyncJob()
                    return@launch
                }

                // Batch accumulation
                synchronized(pendingPoints) {
                    pendingPoints.add(point)
                }

                val now = System.currentTimeMillis()
                val shouldUpload = synchronized(pendingPoints) {
                    pendingPoints.size >= BATCH_SIZE || (now - lastUploadTime) >= BATCH_INTERVAL_MS
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
                            android.util.Log.w("TrackingService", "❌ Batch upload failed. Storing offline.")
                            LogPersistor.append(this@TrackingService, "TrackingService", "Batch upload failed; persisting offline")
                            for (p in batch) dao.insert(p)
                            scheduleSyncJob()
                        }
                    }
                }

                android.util.Log.d("TrackingService", "<<< processLocation() END")
            } catch (e: SecurityException) {
                android.util.Log.e("TrackingService", "❌ SECURITY EXCEPTION: Location permission denied? ${e.message}", e)
            } catch (e: Exception) {
                android.util.Log.e("TrackingService", "❌ ERROR processing location: ${e.message}", e)
                e.printStackTrace()
            }
        }
    }

    private fun scheduleSyncJob() {
        val constraints = Constraints.Builder()
            .setRequiredNetworkType(NetworkType.CONNECTED)
            .build()

        val workRequest = OneTimeWorkRequestBuilder<SyncWorker>()
            .setConstraints(constraints)
            .build()

        WorkManager.getInstance(this).enqueue(workRequest)
    }

    override fun onBind(intent: Intent?): IBinder? {
        return null
    }

    override fun onDestroy() {
        try {
            if (::fusedLocationClient.isInitialized && ::locationCallback.isInitialized) {
                fusedLocationClient.removeLocationUpdates(locationCallback)
            }
        } catch (e: Exception) {
            android.util.Log.e("TrackingService", "Error removing location updates: ${e.message}", e)
        }
        if (::locationHandlerThread.isInitialized) {
            locationHandlerThread.quitSafely()
        }
        super.onDestroy()
    }
}
