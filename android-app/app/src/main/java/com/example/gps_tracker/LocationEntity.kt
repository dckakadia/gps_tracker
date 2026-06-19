package com.example.gps_tracker

import androidx.room.Entity
import androidx.room.PrimaryKey

@Entity(tableName = "offline_locations")
data class LocationEntity(
    @PrimaryKey(autoGenerate = true) val id: Int = 0,
    val latitude: Double,
    val longitude: Double,
    val recordedAt: Long,
    val synced: Boolean = false,
    val batteryLevel: Int = -1,
    val isSpoofed: Boolean = false,
    // GPS quality fields (added v1.2.0 / DB v3)
    val accuracy: Float = -1f,   // metres; -1 = not available
    val speed: Float = -1f,      // m/s;    -1 = not available
    val bearing: Float = -1f,    // degrees; -1 = not available
)
