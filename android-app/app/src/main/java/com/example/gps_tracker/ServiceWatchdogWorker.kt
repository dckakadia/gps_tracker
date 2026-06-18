package com.example.gps_tracker

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import java.util.concurrent.TimeUnit

class ServiceWatchdogWorker(
    private val context: Context,
    workerParams: WorkerParameters
) : CoroutineWorker(context, workerParams) {

    override suspend fun doWork(): Result {
        if (!isTrackingServiceRunning()) {
            android.util.Log.w("ServiceWatchdog", "TrackingService not running — restarting")
            LogPersistor.append(context, "ServiceWatchdog", "TrackingService was dead — restarting")
            try {
                ContextCompat.startForegroundService(
                    context,
                    Intent(context, TrackingService::class.java)
                )
                android.util.Log.i("ServiceWatchdog", "TrackingService restarted successfully")
            } catch (e: Exception) {
                android.util.Log.e("ServiceWatchdog", "Failed to restart TrackingService: ${e.message}", e)
                return Result.retry()
            }
        } else {
            android.util.Log.d("ServiceWatchdog", "TrackingService is running — no action needed")
        }
        return Result.success()
    }

    @Suppress("DEPRECATION")
    private fun isTrackingServiceRunning(): Boolean {
        val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        return manager.getRunningServices(Int.MAX_VALUE).any {
            it.service.className == TrackingService::class.java.name
        }
    }

    companion object {
        private const val WORK_NAME = "service_watchdog"

        fun schedule(context: Context) {
            val request = PeriodicWorkRequestBuilder<ServiceWatchdogWorker>(
                15, TimeUnit.MINUTES
            ).build()

            WorkManager.getInstance(context).enqueueUniquePeriodicWork(
                WORK_NAME,
                ExistingPeriodicWorkPolicy.KEEP,
                request
            )
            android.util.Log.i("ServiceWatchdog", "Watchdog scheduled every 15 minutes")
        }
    }
}
