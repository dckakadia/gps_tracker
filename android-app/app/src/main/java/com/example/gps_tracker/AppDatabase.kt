package com.example.gps_tracker

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase

@Database(
    entities = [LocationEntity::class, SystemEventEntity::class],
    version = 3,
    exportSchema = false,
)
abstract class AppDatabase : RoomDatabase() {
    abstract fun locationDao(): LocationDao
    abstract fun systemEventDao(): SystemEventDao

    companion object {
        @Volatile private var INSTANCE: AppDatabase? = null

        // v1 → v2: add isSpoofed column + system_events table.
        private val MIGRATION_1_2 = object : Migration(1, 2) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE offline_locations ADD COLUMN isSpoofed INTEGER NOT NULL DEFAULT 0")
                db.execSQL("""
                    CREATE TABLE IF NOT EXISTS system_events (
                        id         INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                        eventType  TEXT NOT NULL,
                        detail     TEXT,
                        occurredAt INTEGER NOT NULL,
                        synced     INTEGER NOT NULL DEFAULT 0
                    )
                """.trimIndent())
            }
        }

        // v2 → v3: add GPS quality columns (accuracy, speed, bearing).
        private val MIGRATION_2_3 = object : Migration(2, 3) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE offline_locations ADD COLUMN accuracy REAL NOT NULL DEFAULT -1")
                db.execSQL("ALTER TABLE offline_locations ADD COLUMN speed    REAL NOT NULL DEFAULT -1")
                db.execSQL("ALTER TABLE offline_locations ADD COLUMN bearing  REAL NOT NULL DEFAULT -1")
            }
        }

        fun getInstance(context: Context): AppDatabase {
            return INSTANCE ?: synchronized(this) {
                val instance = Room.databaseBuilder(
                    context.applicationContext,
                    AppDatabase::class.java,
                    "gps_tracker_db",
                )
                    .addMigrations(MIGRATION_1_2, MIGRATION_2_3)
                    .build()
                INSTANCE = instance
                instance
            }
        }
    }
}
