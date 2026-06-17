import { query } from './index.js';

export async function migrateGeofenceEvents() {
  await query(`
    CREATE TABLE IF NOT EXISTS geofence_events (
      id SERIAL PRIMARY KEY,
      user_id INTEGER REFERENCES users(id) ON DELETE CASCADE,
      geofence_id INTEGER REFERENCES geofences(id) ON DELETE CASCADE,
      event_type VARCHAR(10) CHECK (event_type IN ('enter','exit')),
      occurred_at TIMESTAMPTZ DEFAULT NOW()
    )
  `);
  await query(`CREATE INDEX IF NOT EXISTS idx_gfe_user ON geofence_events(user_id)`);
  await query(`CREATE INDEX IF NOT EXISTS idx_gfe_occurred ON geofence_events(occurred_at DESC)`);
  console.log('✓ geofence_events table ready');
}
