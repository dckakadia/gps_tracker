package com.example.gps_tracker

/**
 * Singleton object to track server communication statistics
 */
object ServerStats {
    var successfulRequests: Int = 0
        private set
    var totalRequests: Int = 0
        private set

    fun incrementSuccess() {
        successfulRequests++
        totalRequests++
    }

    fun incrementTotal() {
        totalRequests++
    }

    fun reset() {
        successfulRequests = 0
        totalRequests = 0
    }

    fun getSuccessRate(): Double {
        return if (totalRequests == 0) 0.0 else (successfulRequests.toDouble() / totalRequests) * 100
    }
}
