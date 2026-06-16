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
import android.os.IBinder
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
            fusedLocationClient.requestLocationUpdates(request, locationCallback, mainLooper)
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

    private fun processLocation(location: Location) {
        CoroutineScope(Dispatchers.IO).launch {
            try {
                android.util.Log.d("TrackingService", ">>> processLocation() START")
                val point = LocationEntity(
                    latitude = location.latitude,
                    longitude = location.longitude,
                    recordedAt = System.currentTimeMillis(),
                )
                android.util.Log.d("TrackingService", "Processing location: lat=${location.latitude}, lng=${location.longitude}")
                
                val dao = AppDatabase.getInstance(this@TrackingService).locationDao()
                android.util.Log.d("TrackingService", "✓ Database DAO initialized")
                
                val token = AuthManager.getToken(this@TrackingService)
                android.util.Log.d("TrackingService", "Auth token: ${if (token != null) "present" else "MISSING"}")
                token?.let { ApiClient.setToken(it) }

                if (token == null) {
                    android.util.Log.w("TrackingService", "No auth token found. Storing location offline.")
                    android.util.Log.d("TrackingService", "Offline point details: lat=${point.latitude}, lng=${point.longitude}, recordedAt=${point.recordedAt}")
                    showAuthMissingNotification()
                    LogPersistor.append(this@TrackingService, "TrackingService", "No auth token; storing offline point: lat=${point.latitude}, lng=${point.longitude}, recordedAt=${point.recordedAt}")
                    dao.insert(point)
                    scheduleSyncJob()
                    LogPersistor.append(this@TrackingService, "TrackingService", "Offline point persisted to DB and sync job scheduled")
                    return@launch
                }

                if (!NetworkUtils.isInternetAvailable(this@TrackingService)) {
                    android.util.Log.w("TrackingService", "No internet connection. Storing location offline.")
                    dao.insert(point)
                    scheduleSyncJob()
                    return@launch
                }

                android.util.Log.d("TrackingService", "Attempting to upload location... payload: lat=${point.latitude}, lng=${point.longitude}, recordedAt=${point.recordedAt}")
                LogPersistor.append(this@TrackingService, "TrackingService", "Attempting upload for point: lat=${point.latitude}, lng=${point.longitude}, recordedAt=${point.recordedAt}")
                val success = ApiClient.uploadLocations(this@TrackingService, listOf(point))
                if (success) {
                    android.util.Log.i("TrackingService", "✓ Location uploaded successfully: lat=${point.latitude}, lng=${point.longitude}")
                    LogPersistor.append(this@TrackingService, "TrackingService", "Upload succeeded for point: lat=${point.latitude}, lng=${point.longitude}")
                } else {
                    android.util.Log.w("TrackingService", "❌ Upload failed. Storing location offline.")
                    LogPersistor.append(this@TrackingService, "TrackingService", "Upload failed; persisting offline point: lat=${point.latitude}, lng=${point.longitude}")
                    dao.insert(point)
                    scheduleSyncJob()
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
        super.onDestroy()
    }
}
