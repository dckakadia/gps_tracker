package com.example.gps_tracker

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.ProgressBar
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.appcompat.app.AlertDialog
import androidx.core.content.ContextCompat
import android.provider.Settings
import android.net.Uri
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class LoginActivity : AppCompatActivity() {
    private lateinit var emailInput: EditText
    private lateinit var passwordInput: EditText
    private lateinit var loginButton: Button
    private lateinit var errorText: TextView
    private lateinit var loadingSpinner: ProgressBar
    private val LOCATION_PERMISSION_REQUEST = 100
    private val BACKGROUND_LOCATION_PERMISSION_REQUEST = 101

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_login)
        
        // Initialize device compatibility and diagnostics
        android.util.Log.i("LoginActivity", "===== App Startup =====")
        DeviceCompat.logDeviceInfo(this)
        DeviceCompat.applyDeviceSpecificFixes(this)
        NetworkDiagnostics.logNetworkDiagnostics(this)

        emailInput = findViewById(R.id.emailInput)
        passwordInput = findViewById(R.id.passwordInput)
        loginButton = findViewById(R.id.loginButton)
        errorText = findViewById(R.id.errorText)
        loadingSpinner = findViewById(R.id.loadingSpinner)

        loginButton.setOnClickListener {
            val email = emailInput.text.toString().trim()
            val password = passwordInput.text.toString().trim()
            attemptLogin(email, password)
        }

        AuthManager.getToken(this)?.let { token ->
            ApiClient.setToken(token)
            ensureBackgroundLocationPermissionAndStart()
        }
    }

    private fun hasRequiredLocationPermissions(): Boolean {
        return areHighAccuracyPermissionsGranted()
    }

    private fun areHighAccuracyPermissionsGranted(): Boolean {
        val fineGranted = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED

        val coarseGranted = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.ACCESS_COARSE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED

        val foregroundServicePermissionGranted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            ContextCompat.checkSelfPermission(this, Manifest.permission.FOREGROUND_SERVICE_LOCATION) == PackageManager.PERMISSION_GRANTED
        } else {
            true
        }

        return (fineGranted || coarseGranted) && foregroundServicePermissionGranted
    }

    private fun areBackgroundPermissionGranted(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.ACCESS_BACKGROUND_LOCATION
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
    }

    private fun attemptLogin(email: String, password: String) {
        if (email.isBlank() || password.isBlank()) {
            displayError("Email and password are required.")
            return
        }

        setLoading(true)
        CoroutineScope(Dispatchers.IO).launch {
            val loginResult = ApiClient.login(email, password)
            withContext(Dispatchers.Main) {
                setLoading(false)
                if (loginResult.success && loginResult.token != null) {
                    AuthManager.saveToken(this@LoginActivity, loginResult.token)
                    ApiClient.setToken(loginResult.token)
                    startTrackingService()
                } else {
                    displayError(loginResult.error ?: "Login failed")
                }
            }
        }
    }

    private fun startTrackingService() {
        ensureBackgroundLocationPermissionAndStart()
    }

    private fun ensureBackgroundLocationPermissionAndStart() {
        if (!areHighAccuracyPermissionsGranted()) {
            requestForegroundLocationPermissions()
            return
        }

        startServiceForReal()

        if (!areBackgroundPermissionGranted()) {
            requestBackgroundLocationPermission()
        }
    }

    private fun requestForegroundLocationPermissions() {
        val permissions = mutableListOf(
            Manifest.permission.ACCESS_FINE_LOCATION,
            Manifest.permission.ACCESS_COARSE_LOCATION
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            permissions.add(Manifest.permission.FOREGROUND_SERVICE_LOCATION)
        }
        ActivityCompat.requestPermissions(
            this,
            permissions.toTypedArray(),
            LOCATION_PERMISSION_REQUEST
        )
    }

    private fun requestBackgroundLocationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.ACCESS_BACKGROUND_LOCATION),
                BACKGROUND_LOCATION_PERMISSION_REQUEST
            )
        }
    }

    private fun startServiceForReal() {
        val intent = Intent(this, TrackingService::class.java)
        ContextCompat.startForegroundService(this, intent)
        errorText.visibility = View.GONE
        loginButton.isEnabled = false
        loginButton.text = "Tracking Enabled"
        
        // Navigate to MainActivity after successful login and service start
        val mainIntent = Intent(this, MainActivity::class.java)
        mainIntent.flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_NEW_TASK
        startActivity(mainIntent)
        finish()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        when (requestCode) {
            LOCATION_PERMISSION_REQUEST -> {
                if (areHighAccuracyPermissionsGranted()) {
                    startServiceForReal()
                    if (!areBackgroundPermissionGranted()) {
                        requestBackgroundLocationPermission()
                    }
                    return
                }
            }
            BACKGROUND_LOCATION_PERMISSION_REQUEST -> {
                if (areHighAccuracyPermissionsGranted()) {
                    startServiceForReal()
                    return
                }
            }
        }

        AlertDialog.Builder(this)
            .setTitle("Permission required")
            .setMessage(
                "The app needs location and foreground-service location permission " +
                        "for continuous GPS tracking. Open app settings and grant the required permissions."
            )
            .setPositiveButton("Open Settings") { _, _ ->
                val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                val uri: Uri = Uri.fromParts("package", packageName, null)
                intent.data = uri
                startActivity(intent)
            }
            .setNegativeButton("Cancel") { _, _ -> displayError("Location permission is required for GPS tracking") }
            .show()
    }

    private fun displayError(message: String) {
        errorText.text = message
        errorText.visibility = View.VISIBLE
    }

    private fun setLoading(isLoading: Boolean) {
        loadingSpinner.visibility = if (isLoading) View.VISIBLE else View.GONE
        loginButton.isEnabled = !isLoading
    }
}
