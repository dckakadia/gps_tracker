package com.example.gps_tracker

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.Query
import androidx.room.Update

@Dao
interface LocationDao {
    @Insert
    suspend fun insert(location: LocationEntity)

    @Query("SELECT * FROM offline_locations ORDER BY recordedAt ASC")
    suspend fun getAll(): List<LocationEntity>

    @Query("DELETE FROM offline_locations WHERE id IN (:ids)")
    suspend fun deleteByIds(ids: List<Int>)
}
