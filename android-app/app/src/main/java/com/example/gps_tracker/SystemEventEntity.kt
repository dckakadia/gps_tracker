package com.example.gps_tracker

import androidx.room.Entity
import androidx.room.PrimaryKey

/**
 * Persists tamper-indicative system events (GPS disabled, airplane mode, shutdown) for
 * audit upload. Events are synced to the server alongside location batches.
 */
@Entity(tableName = "system_events")
data class SystemEventEntity(
    @PrimaryKey(autoGenerate = true) val id: Int = 0,
    val eventType: String,   // "gps_disabled" | "gps_enabled" | "airplane_on" | "airplane_off" | "shutdown"
    val detail: String? = null,
    val occurredAt: Long,    // epoch ms (System.currentTimeMillis — event time, not GPS fix time)
    val synced: Boolean = false,
)
