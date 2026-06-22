import pool from './index.js';

// Migration: add computed_speed (server-derived m/s) and speed_source ('gps'|'derived'|'none')
// to both locations and locations_archive tables.
// speed_source defaults to 'gps' for existing rows so the archive job never sees a null.
export async function initializeDerivedSpeed() {
  await pool.query(`
    ALTER TABLE locations
      ADD COLUMN IF NOT EXISTS computed_speed DOUBLE PRECISION,
      ADD COLUMN IF NOT EXISTS speed_source   VARCHAR(10) NOT NULL DEFAULT 'gps'
  `);
  await pool.query(`
    ALTER TABLE locations_archive
      ADD COLUMN IF NOT EXISTS computed_speed DOUBLE PRECISION,
      ADD COLUMN IF NOT EXISTS speed_source   VARCHAR(10) NOT NULL DEFAULT 'gps'
  `);
}
