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
    val batteryLevel: Int = -1
)
