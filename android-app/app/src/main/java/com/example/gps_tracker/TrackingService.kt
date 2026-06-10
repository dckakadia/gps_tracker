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
    private lateinit var fusedLocationClient: FusedLocationProviderClient
    private lateinit var locationCallback: LocationCallback

    override fun onCreate() {
        super.onCreate()
        fusedLocationClient = LocationServices.getFusedLocationProviderClient(this)
        locationCallback = object : LocationCallback() {
            override fun onLocationResult(result: LocationResult) {
                super.onLocationResult(result)
                result.locations.forEach { location -> processLocation(location) }
            }
        }
        startForegroundServiceNotification()
        startLocationUpdates()
    }

    private fun startForegroundServiceNotification() {
        val channelId = "gps_tracker_channel"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(channelId, "Location Tracking", NotificationManager.IMPORTANCE_LOW)
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }

        val notification: Notification = NotificationCompat.Builder(this, channelId)
            .setContentTitle("Employee Location Tracking")
            .setContentText("Location service is running")
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()

        startForeground(1, notification)
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

        if (ActivityCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED &&
            ActivityCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
            android.util.Log.e("TrackingService", "Location permissions not granted. Tracking cannot start.")
            return
        }

        try {
            fusedLocationClient.requestLocationUpdates(request, locationCallback, mainLooper)
            android.util.Log.i("TrackingService", "Location updates requested successfully")
        } catch (e: Exception) {
            android.util.Log.e("TrackingService", "Error requesting location updates", e)
        }
    }

    private fun processLocation(location: Location) {
        CoroutineScope(Dispatchers.IO).launch {
            try {
                val point = LocationEntity(
                    latitude = location.latitude,
                    longitude = location.longitude,
                    recordedAt = System.currentTimeMillis(),
                )
                android.util.Log.d("TrackingService", "Processing location: lat=${location.latitude}, lng=${location.longitude}")
                val dao = AppDatabase.getInstance(this@TrackingService).locationDao()
                val token = AuthManager.getToken(this@TrackingService)
                token?.let { ApiClient.setToken(it) }

                if (token == null) {
                    android.util.Log.w("TrackingService", "No auth token found. Storing location offline.")
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

                val success = ApiClient.uploadLocations(this@TrackingService, listOf(point))
                if (success) {
                    android.util.Log.i("TrackingService", "Location uploaded successfully: lat=${point.latitude}, lng=${point.longitude}")
                } else {
                    android.util.Log.w("TrackingService", "Upload failed (status unknown). Storing location offline.")
                    dao.insert(point)
                    scheduleSyncJob()
                }
            } catch (e: Exception) {
                android.util.Log.e("TrackingService", "Error processing location", e)
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
        fusedLocationClient.removeLocationUpdates(locationCallback)
        super.onDestroy()
    }
}
