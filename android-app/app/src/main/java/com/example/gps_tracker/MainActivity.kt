package com.example.gps_tracker

import android.content.Intent
import android.os.Bundle
import androidx.appcompat.app.AppCompatActivity
import com.google.android.material.button.MaterialButton
import kotlinx.coroutines.GlobalScope
import kotlinx.coroutines.launch

class MainActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        findViewById<MaterialButton>(R.id.startTrackingButton).setOnClickListener {
            startForegroundService(Intent(this, TrackingService::class.java))
            android.util.Log.i("MainActivity", "TrackingService started")
        }

        // TEST/DEBUG: Manual upload trigger
        findViewById<MaterialButton>(R.id.testUploadButton)?.setOnClickListener {
            android.util.Log.d("MainActivity", "Test upload button clicked")
            GlobalScope.launch {
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
            }
        }
    }
}
