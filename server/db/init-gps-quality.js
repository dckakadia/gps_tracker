/**
 * GPS quality schema migration.
 *
 * Adds to the locations table:
 *   accuracy    FLOAT   — GPS horizontal accuracy in metres (from FusedLocationProvider)
 *   speed       FLOAT   — speed in m/s at time of fix
 *   heading     FLOAT   — bearing in degrees (0–360)
 *   is_filtered BOOLEAN — true if the Kalman filter meaningfully smoothed this point
 *   stop_id     INTEGER — FK to stops table when this point belongs to a detected stop
 *
 * Creates the stops table for stop-detection results.
 */
import { query } from './index.js';

export async function initializeGpsQuality() {
  // ── locations: quality columns ───────────────────────────────────────────────
  await query(`
    ALTER TABLE locations ADD COLUMN IF NOT EXISTS accuracy    FLOAT
  `);
  await query(`
    ALTER TABLE locations ADD COLUMN IF NOT EXISTS speed       FLOAT
  `);
  await query(`
    ALTER TABLE locations ADD COLUMN IF NOT EXISTS heading     FLOAT
  `);
  await query(`
    ALTER TABLE locations ADD COLUMN IF NOT EXISTS is_filtered BOOLEAN NOT NULL DEFAULT FALSE
  `);
  await query(`
    ALTER TABLE locations ADD COLUMN IF NOT EXISTS stop_id     INTEGER
  `);

  // ── stops table ──────────────────────────────────────────────────────────────
  await query(`
    CREATE TABLE IF NOT EXISTS stops (
      id               SERIAL PRIMARY KEY,
      user_id          INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      start_time       TIMESTAMP WITH TIME ZONE NOT NULL,
      end_time         TIMESTAMP WITH TIME ZONE NOT NULL,
      lat              DOUBLE PRECISION NOT NULL,
      lng              DOUBLE PRECISION NOT NULL,
      duration_seconds INTEGER NOT NULL,
      created_at       TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
    )
  `);

  await query(`
    CREATE INDEX IF NOT EXISTS idx_stops_user_start
    ON stops (user_id, start_time DESC)
  `);

  // FK from locations.stop_id → stops.id (add only if constraint absent)
  await query(`
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM information_schema.table_constraints
        WHERE constraint_name = 'fk_locations_stop_id'
      ) THEN
        ALTER TABLE locations
          ADD CONSTRAINT fk_locations_stop_id
          FOREIGN KEY (stop_id) REFERENCES stops(id) ON DELETE SET NULL;
      END IF;
    END;
    $$
  `);

  console.log('✓ GPS quality columns + stops table ready');
}
