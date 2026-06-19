package com.example.gps_tracker

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters

class SyncWorker(appContext: Context, workerParams: WorkerParameters) :
    CoroutineWorker(appContext, workerParams) {

    override suspend fun doWork(): Result {
        return try {
            val db = AppDatabase.getInstance(applicationContext)
            AuthManager.getToken(applicationContext)?.let { ApiClient.setToken(it) }

            // Flush offline location points.
            val locations = db.locationDao().getAll()
            if (locations.isNotEmpty()) {
                android.util.Log.i("SyncWorker", "Syncing ${locations.size} offline location(s)")
                val ok = ApiClient.uploadLocations(applicationContext, locations)
                if (ok) {
                    db.locationDao().deleteByIds(locations.map { it.id })
                    android.util.Log.i("SyncWorker", "Offline locations synced and deleted")
                } else {
                    android.util.Log.w("SyncWorker", "Location sync failed — will retry")
                    return Result.retry()
                }
            }

            // Flush unsynced device events (GPS disable, airplane mode, shutdown).
            val events = db.systemEventDao().getUnsynced()
            if (events.isNotEmpty()) {
                android.util.Log.i("SyncWorker", "Reporting ${events.size} device event(s)")
                val ok = ApiClient.reportDeviceEvents(applicationContext, events)
                if (ok) {
                    db.systemEventDao().markSynced(events.map { it.id })
                    android.util.Log.i("SyncWorker", "Device events reported and marked synced")
                } else {
                    android.util.Log.w("SyncWorker", "Device event report failed — will retry")
                    return Result.retry()
                }
            }

            Result.success()
        } catch (err: Exception) {
            android.util.Log.e("SyncWorker", "Sync worker error", err)
            Result.retry()
        }
    }
}
