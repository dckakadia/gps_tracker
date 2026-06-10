package com.example.gps_tracker

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters

class SyncWorker(appContext: Context, workerParams: WorkerParameters) : CoroutineWorker(appContext, workerParams) {
    override suspend fun doWork(): Result {
        return try {
            val dao = AppDatabase.getInstance(applicationContext).locationDao()
            val points = dao.getAll()
            if (points.isEmpty()) {
                android.util.Log.d("SyncWorker", "No offline locations to sync")
                return Result.success()
            }

            android.util.Log.i("SyncWorker", "Syncing ${points.size} offline location(s)")
            AuthManager.getToken(applicationContext)?.let { ApiClient.setToken(it) }
            val success = ApiClient.uploadLocations(applicationContext, points)
            if (success) {
                android.util.Log.i("SyncWorker", "Successfully synced and deleted offline locations")
                dao.deleteByIds(points.map { it.id })
                Result.success()
            } else {
                android.util.Log.w("SyncWorker", "Sync upload failed. Will retry.")
                Result.retry()
            }
        } catch (err: Exception) {
            android.util.Log.e("SyncWorker", "Sync worker error", err)
            Result.retry()
        }
    }
}
