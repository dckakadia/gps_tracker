package com.example.gps_tracker

import android.app.Activity
import android.app.DownloadManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import android.os.Environment
import androidx.appcompat.app.AlertDialog
import androidx.core.content.FileProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.io.File

object UpdateChecker {
    private val client = OkHttpClient.Builder()
        .callTimeout(java.time.Duration.ofSeconds(10))
        .build()

    data class VersionInfo(
        val latestVersion: String,
        val versionCode: Int,
        val fileName: String,
        val releaseNotes: String,
    )

    suspend fun checkForUpdate(context: Context): VersionInfo? {
        return withContext(Dispatchers.IO) {
            try {
                val request = Request.Builder()
                    .url("${ApiClient.BASE_URL}/app/version")
                    .build()
                client.newCall(request).execute().use { response ->
                    if (!response.isSuccessful) return@withContext null
                    val body = response.body?.string() ?: return@withContext null
                    val json = JSONObject(body)
                    val serverCode = json.optInt("versionCode", 0)
                    if (serverCode <= BuildConfig.VERSION_CODE) return@withContext null
                    VersionInfo(
                        latestVersion = json.optString("latestVersion", ""),
                        versionCode = serverCode,
                        fileName = json.optString("fileName", ""),
                        releaseNotes = json.optString("releaseNotes", ""),
                    )
                }
            } catch (e: Exception) {
                android.util.Log.w("UpdateChecker", "Version check failed: ${e.message}")
                null
            }
        }
    }

    fun showUpdateDialog(activity: Activity, info: VersionInfo) {
        if (activity.isFinishing || activity.isDestroyed) return
        AlertDialog.Builder(activity)
            .setTitle("Update Available — v${info.latestVersion}")
            .setMessage(
                "A new version of GPS Tracker is available.\n\n" +
                "Current: v${BuildConfig.VERSION_NAME}\n" +
                "Latest:  v${info.latestVersion}\n\n" +
                if (info.releaseNotes.isNotBlank()) "What's new:\n${info.releaseNotes}" else ""
            )
            .setPositiveButton("Update Now") { _, _ ->
                downloadAndInstall(activity, info.fileName)
            }
            .setNegativeButton("Later", null)
            .setCancelable(true)
            .show()
    }

    private fun downloadAndInstall(context: Context, fileName: String) {
        val downloadUrl = "${ApiClient.BASE_URL}/app/download/$fileName"
        val dm = context.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager

        val destFile = File(
            context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS),
            fileName
        )
        if (destFile.exists()) destFile.delete()

        val request = DownloadManager.Request(Uri.parse(downloadUrl))
            .setTitle("GPS Tracker Update")
            .setDescription("Downloading v${fileName.removePrefix("gpstracker_ver_").removeSuffix(".apk").replace('_', '.')}")
            .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
            .setDestinationUri(Uri.fromFile(destFile))
            .setAllowedOverMetered(true)
            .setAllowedOverRoaming(true)

        val downloadId = dm.enqueue(request)
        android.util.Log.i("UpdateChecker", "Started download id=$downloadId url=$downloadUrl")

        val receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context, intent: Intent) {
                val id = intent.getLongExtra(DownloadManager.EXTRA_DOWNLOAD_ID, -1)
                if (id != downloadId) return
                ctx.unregisterReceiver(this)
                installApk(ctx, destFile)
            }
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(
                receiver,
                IntentFilter(DownloadManager.ACTION_DOWNLOAD_COMPLETE),
                Context.RECEIVER_NOT_EXPORTED
            )
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(receiver, IntentFilter(DownloadManager.ACTION_DOWNLOAD_COMPLETE))
        }
    }

    private fun installApk(context: Context, apkFile: File) {
        if (!apkFile.exists()) {
            android.util.Log.e("UpdateChecker", "APK file not found after download")
            return
        }
        val uri = FileProvider.getUriForFile(
            context,
            "${context.packageName}.fileprovider",
            apkFile
        )
        val install = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        context.startActivity(install)
    }
}
