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
                return Result.success()
            }

            AuthManager.getToken(applicationContext)?.let { ApiClient.setToken(it) }
            val success = ApiClient.uploadLocations(applicationContext, points)
            if (success) {
                dao.deleteByIds(points.map { it.id })
                Result.success()
            } else {
                Result.retry()
            }
        } catch (err: Exception) {
            err.printStackTrace()
            Result.retry()
        }
    }
}
