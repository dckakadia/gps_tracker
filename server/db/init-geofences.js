import { query } from './index.js';

export async function initializeGeofences() {
  await query(`
    CREATE TABLE IF NOT EXISTS geofences (
      id SERIAL PRIMARY KEY,
      name TEXT NOT NULL,
      latitude DOUBLE PRECISION NOT NULL,
      longitude DOUBLE PRECISION NOT NULL,
      radius_meters DOUBLE PRECISION NOT NULL,
      created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
    )
  `);
  await query(`
    CREATE TABLE IF NOT EXISTS user_geofence_state (
      user_id INTEGER REFERENCES users(id) ON DELETE CASCADE,
      geofence_id INTEGER REFERENCES geofences(id) ON DELETE CASCADE,
      inside BOOLEAN NOT NULL DEFAULT false,
      PRIMARY KEY (user_id, geofence_id)
    )
  `);
  console.log('✓ geofences tables ready');
}
