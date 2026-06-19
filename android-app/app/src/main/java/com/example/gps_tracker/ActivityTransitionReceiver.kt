package com.example.gps_tracker

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import com.google.android.gms.location.ActivityTransition
import com.google.android.gms.location.ActivityTransitionResult
import com.google.android.gms.location.DetectedActivity

/**
 * Receives Activity Recognition transition events from the Google API.
 * When a movement activity (IN_VEHICLE, WALKING, RUNNING, ON_BICYCLE) is detected
 * while the TrackingService is STATIONARY, it wakes the service back to MOVING state.
 * This is the primary mechanism for graceful stationary→moving transitions without
 * keeping GPS alive.
 */
class ActivityTransitionReceiver : BroadcastReceiver() {

    companion object {
        const val TRANSITION_ACTION = "com.example.gps_tracker.ACTIVITY_TRANSITION"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (!ActivityTransitionResult.hasResult(intent)) return
        val result = ActivityTransitionResult.extractResult(intent) ?: return

        for (event in result.transitionEvents) {
            val entering = event.transitionType == ActivityTransition.ACTIVITY_TRANSITION_ENTER
            if (!entering) continue

            val movementActivity = when (event.activityType) {
                DetectedActivity.IN_VEHICLE,
                DetectedActivity.WALKING,
                DetectedActivity.RUNNING,
                DetectedActivity.ON_BICYCLE,
                DetectedActivity.ON_FOOT -> true
                else -> false
            }

            if (movementActivity && TrackingService.currentState == TrackingService.State.STATIONARY) {
                android.util.Log.i("ActivityTransitionReceiver",
                    "Movement activity '${activityLabel(event.activityType)}' detected while STATIONARY → waking service")
                LogPersistor.append(context, "ActivityTransitionReceiver",
                    "Activity wake: ${activityLabel(event.activityType)} → MOVING")
                val wakeIntent = Intent(context, TrackingService::class.java).apply {
                    action = TrackingService.ACTION_WAKE_FROM_ACTIVITY
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(wakeIntent)
                } else {
                    context.startService(wakeIntent)
                }
                break
            }
        }
    }

    private fun activityLabel(type: Int) = when (type) {
        DetectedActivity.IN_VEHICLE  -> "IN_VEHICLE"
        DetectedActivity.WALKING     -> "WALKING"
        DetectedActivity.RUNNING     -> "RUNNING"
        DetectedActivity.ON_BICYCLE  -> "ON_BICYCLE"
        DetectedActivity.ON_FOOT     -> "ON_FOOT"
        DetectedActivity.STILL       -> "STILL"
        else                         -> "UNKNOWN($type)"
    }
}
