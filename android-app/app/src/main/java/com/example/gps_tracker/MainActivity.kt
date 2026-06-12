package com.example.gps_tracker

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.google.android.material.button.MaterialButton
import kotlinx.coroutines.GlobalScope
import kotlinx.coroutines.launch

class MainActivity : AppCompatActivity() {
    private val LOCATION_PERMISSION_REQUEST_CODE = 100

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        findViewById<MaterialButton>(R.id.startTrackingButton).setOnClickListener {
            android.util.Log.i("MainActivity", "Start tracking clicked")
            ensureLocationPermissionsAndStart()
        }

        // TEST/DEBUG: Manual upload trigger
        findViewById<MaterialButton>(R.id.testUploadButton)?.setOnClickListener {
            android.util.Log.d("MainActivity", "Test upload button clicked")
            GlobalScope.launch {
                try {
                    val dao = AppDatabase.getInstance(this@MainActivity).locationDao()
                    val points = dao.getAll()
                    if (points.isEmpty()) {
                        android.util.Log.w("MainActivity", "No offline locations to upload")
                    } else {
                        android.util.Log.i("MainActivity", "Uploading ${points.size} test location(s)")
                        val token = AuthManager.getToken(this@MainActivity)
                        if (token != null) {
                            ApiClient.setToken(token)
                            val success = ApiClient.uploadLocations(this@MainActivity, points)
                            if (success) {
                                android.util.Log.i("MainActivity", "Test upload succeeded")
                                dao.deleteByIds(points.map { it.id })
                            } else {
                                android.util.Log.e("MainActivity", "Test upload failed")
                            }
                        } else {
                            android.util.Log.w("MainActivity", "No auth token for test upload")
                        }
                    }
                } catch (e: Exception) {
                    android.util.Log.e("MainActivity", "Test upload exception: ${e.message}", e)
                }
            }
        }
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
}
