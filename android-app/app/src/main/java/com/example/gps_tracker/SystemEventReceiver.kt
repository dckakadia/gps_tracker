package com.example.gps_tracker

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.location.LocationManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * Records tamper-relevant system events to the local SQLite store so they can be uploaded
 * to the server for audit. Covers:
 *   - GPS provider enabled/disabled (PROVIDERS_CHANGED)
 *   - Airplane mode on/off (AIRPLANE_MODE_CHANGED)
 *   - Device shutdown (ACTION_SHUTDOWN)
 *
 * Declared in the manifest — no runtime registration required.
 */
class SystemEventReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val (eventType, detail) = when (intent.action) {
            Intent.ACTION_PROVIDER_CHANGED,
            "android.location.PROVIDERS_CHANGED" -> {
                val lm = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
                val gpsEnabled = lm?.isProviderEnabled(LocationManager.GPS_PROVIDER) ?: return
                val type = if (gpsEnabled) "gps_enabled" else "gps_disabled"
                Pair(type, null)
            }
            Intent.ACTION_AIRPLANE_MODE_CHANGED -> {
                val isOn = intent.getBooleanExtra("state", false)
                Pair(if (isOn) "airplane_on" else "airplane_off", null)
            }
            Intent.ACTION_SHUTDOWN -> Pair("shutdown", null)
            else -> return
        }

        val pendingResult = goAsync()
        CoroutineScope(Dispatchers.IO).launch {
            try {
                AppDatabase.getInstance(context).systemEventDao().insert(
                    SystemEventEntity(
                        eventType = eventType,
                        detail = detail,
                        occurredAt = System.currentTimeMillis(),
                    )
                )
                LogPersistor.append(context, "SystemEventReceiver", "Event logged: $eventType")
            } catch (e: Exception) {
                android.util.Log.e("SystemEventReceiver", "Failed to log event $eventType", e)
            } finally {
                pendingResult.finish()
            }
        }
    }
}
