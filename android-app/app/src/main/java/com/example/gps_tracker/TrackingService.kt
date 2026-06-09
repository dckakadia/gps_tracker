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
        val request = LocationRequest.create().apply {
            interval = 10 * 60 * 1000L
            fastestInterval = 5 * 60 * 1000L
            smallestDisplacement = 100f
            priority = LocationRequest.PRIORITY_BALANCED_POWER_ACCURACY
        }

        if (ActivityCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED &&
            ActivityCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
            return
        }

        fusedLocationClient.requestLocationUpdates(request, locationCallback, mainLooper)
    }

    private fun processLocation(location: Location) {
        CoroutineScope(Dispatchers.IO).launch {
            val point = LocationEntity(
                latitude = location.latitude,
                longitude = location.longitude,
                recordedAt = System.currentTimeMillis(),
            )
            val dao = AppDatabase.getInstance(this@TrackingService).locationDao()
            val token = AuthManager.getToken(this@TrackingService)
            token?.let { ApiClient.setToken(it) }

            if (NetworkUtils.isInternetAvailable(this@TrackingService) && token != null) {
                val success = ApiClient.uploadLocations(this@TrackingService, listOf(point))
                if (!success) {
                    dao.insert(point)
                    scheduleSyncJob()
                }
            } else {
                dao.insert(point)
                scheduleSyncJob()
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
