package com.example.gps_tracker

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat

class GpsWatchdogReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (TrackingService.currentState != TrackingService.State.MOVING) return
        android.util.Log.w("GpsWatchdog",
            "No GPS callback for 2 min while MOVING — restarting FLP")
        LogPersistor.append(context, "GpsWatchdog",
            "GPS callback watchdog fired: no location update for 2 min")
        val svc = Intent(context, TrackingService::class.java).apply {
            action = TrackingService.ACTION_RESTART_FLP
        }
        ContextCompat.startForegroundService(context, svc)
    }
}
