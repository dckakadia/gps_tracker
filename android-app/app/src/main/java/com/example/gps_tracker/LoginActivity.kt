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

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_login)

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
            startTrackingService()
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
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val backgroundGranted = ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.ACCESS_BACKGROUND_LOCATION
            ) == PackageManager.PERMISSION_GRANTED

            val fineGranted = ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.ACCESS_FINE_LOCATION
            ) == PackageManager.PERMISSION_GRANTED

            if (fineGranted && backgroundGranted) {
                startServiceForReal()
                return
            }

            // Show rationale if needed
            if (ActivityCompat.shouldShowRequestPermissionRationale(this, Manifest.permission.ACCESS_BACKGROUND_LOCATION) ||
                ActivityCompat.shouldShowRequestPermissionRationale(this, Manifest.permission.ACCESS_FINE_LOCATION)) {
                AlertDialog.Builder(this)
                    .setTitle("Location permission required")
                    .setMessage("Background location access is required for continuous GPS tracking so your location can be shown on the live map.")
                    .setPositiveButton("Allow") { _, _ ->
                        ActivityCompat.requestPermissions(
                            this,
                            arrayOf(
                                Manifest.permission.ACCESS_FINE_LOCATION,
                                Manifest.permission.ACCESS_COARSE_LOCATION,
                                Manifest.permission.ACCESS_BACKGROUND_LOCATION
                            ),
                            LOCATION_PERMISSION_REQUEST
                        )
                    }
                    .setNegativeButton("Cancel", null)
                    .show()
                return
            }

            // If not granted and no rationale, request permissions first time.
            ActivityCompat.requestPermissions(
                this,
                arrayOf(
                    Manifest.permission.ACCESS_FINE_LOCATION,
                    Manifest.permission.ACCESS_COARSE_LOCATION,
                    Manifest.permission.ACCESS_BACKGROUND_LOCATION
                ),
                LOCATION_PERMISSION_REQUEST
            )
        } else {
            // older devices only need fine/coarse
            val fineGranted = ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.ACCESS_FINE_LOCATION
            ) == PackageManager.PERMISSION_GRANTED

            if (fineGranted) {
                startServiceForReal()
                return
            }

            if (ActivityCompat.shouldShowRequestPermissionRationale(this, Manifest.permission.ACCESS_FINE_LOCATION)) {
                AlertDialog.Builder(this)
                    .setTitle("Location permission required")
                    .setMessage("Location access is required for GPS tracking so your location can be shown on the live map.")
                    .setPositiveButton("Allow") { _, _ ->
                        ActivityCompat.requestPermissions(
                            this,
                            arrayOf(
                                Manifest.permission.ACCESS_FINE_LOCATION,
                                Manifest.permission.ACCESS_COARSE_LOCATION
                            ),
                            LOCATION_PERMISSION_REQUEST
                        )
                    }
                    .setNegativeButton("Cancel", null)
                    .show()
                return
            }

            ActivityCompat.requestPermissions(
                this,
                arrayOf(
                    Manifest.permission.ACCESS_FINE_LOCATION,
                    Manifest.permission.ACCESS_COARSE_LOCATION
                ),
                LOCATION_PERMISSION_REQUEST
            )
        }
    }

    private fun startServiceForReal() {
        val intent = Intent(this, TrackingService::class.java)
        ContextCompat.startForegroundService(this, intent)
        errorText.visibility = View.GONE
        loginButton.isEnabled = false
        loginButton.text = "Tracking Enabled"
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == LOCATION_PERMISSION_REQUEST) {
            val granted = grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }
            if (granted) {
                startServiceForReal()
                return
            }

            // If the user denied and we should not show rationale anymore, suggest settings
            val permanentlyDenied = Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
                    !ActivityCompat.shouldShowRequestPermissionRationale(this, Manifest.permission.ACCESS_FINE_LOCATION)

            if (permanentlyDenied) {
                AlertDialog.Builder(this)
                    .setTitle("Permission required")
                    .setMessage("Background location permission was denied. To enable continuous tracking, open app settings and grant Location -> Background permission.")
                    .setPositiveButton("Open Settings") { _, _ ->
                        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                        val uri: Uri = Uri.fromParts("package", packageName, null)
                        intent.data = uri
                        startActivity(intent)
                    }
                    .setNegativeButton("Cancel") { _, _ -> displayError("Location permission is required for GPS tracking") }
                    .show()
            } else {
                displayError("Location permission is required for GPS tracking")
            }
        }
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
