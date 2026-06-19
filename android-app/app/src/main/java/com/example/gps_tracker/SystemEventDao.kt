package com.example.gps_tracker

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.Query

@Dao
interface SystemEventDao {
    @Insert
    suspend fun insert(event: SystemEventEntity)

    @Query("SELECT * FROM system_events WHERE synced = 0 ORDER BY occurredAt ASC LIMIT 50")
    suspend fun getUnsynced(): List<SystemEventEntity>

    @Query("UPDATE system_events SET synced = 1 WHERE id IN (:ids)")
    suspend fun markSynced(ids: List<Int>)
}
