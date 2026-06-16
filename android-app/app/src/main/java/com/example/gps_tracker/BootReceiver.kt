package com.example.gps_tracker

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        if (action == Intent.ACTION_BOOT_COMPLETED || action == Intent.ACTION_MY_PACKAGE_REPLACED) {
            try {
                val startIntent = Intent(context, TrackingService::class.java)
                ContextCompat.startForegroundService(context, startIntent)
                android.util.Log.i("BootReceiver", "Started TrackingService after boot/package replace: $action")
            } catch (e: Exception) {
                android.util.Log.e("BootReceiver", "Failed to start TrackingService: ${e.message}", e)
            }
        }
    }
}
