package com.example.gps_tracker

import android.content.Intent
import android.os.Bundle
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.ProgressBar
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
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
        val intent = Intent(this, TrackingService::class.java)
        ContextCompat.startForegroundService(this, intent)
        errorText.visibility = View.GONE
        loginButton.isEnabled = false
        loginButton.text = "Tracking Enabled"
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
