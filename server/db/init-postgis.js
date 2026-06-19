import { query } from './index.js';

/**
 * Adds a PostGIS geography column to the geofences table and creates a spatial index.
 * The geog column is kept in sync with latitude/longitude via a trigger so existing
 * INSERT/UPDATE code on the REST API needs no changes.
 *
 * Falls back silently if PostGIS is not installed — the app continues using the
 * in-process Haversine fallback in locations.js.
 */
export async function initializePostGIS() {
  try {
    // Test whether PostGIS is available.
    await query("SELECT PostGIS_Version()");
  } catch {
    console.log('PostGIS not available — skipping spatial index setup (Haversine fallback active)');
    return;
  }

  try {
    // Add geography column if absent.
    await query(`
      ALTER TABLE geofences
      ADD COLUMN IF NOT EXISTS geog GEOGRAPHY(POINT, 4326)
    `);

    // Back-fill existing rows.
    await query(`
      UPDATE geofences
      SET geog = ST_SetSRID(ST_MakePoint(longitude, latitude), 4326)::geography
      WHERE geog IS NULL
    `);

    // Spatial GiST index — makes ST_DWithin O(log N) instead of O(N).
    await query(`
      CREATE INDEX IF NOT EXISTS idx_geofences_geog
      ON geofences USING GIST (geog)
    `);

    // Trigger to keep geog in sync whenever lat/lng are updated via the API.
    await query(`
      CREATE OR REPLACE FUNCTION sync_geofence_geog() RETURNS trigger AS $$
      BEGIN
        NEW.geog := ST_SetSRID(ST_MakePoint(NEW.longitude, NEW.latitude), 4326)::geography;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql
    `);
    await query(`
      DROP TRIGGER IF EXISTS trg_sync_geofence_geog ON geofences
    `);
    await query(`
      CREATE TRIGGER trg_sync_geofence_geog
      BEFORE INSERT OR UPDATE OF latitude, longitude ON geofences
      FOR EACH ROW EXECUTE FUNCTION sync_geofence_geog()
    `);

    console.log('✓ PostGIS spatial index ready on geofences.geog');
  } catch (err) {
    console.error('PostGIS init error (non-fatal, Haversine fallback active):', err.message);
  }
}
