import { query } from './index.js';

/**
 * Adds anti-cheat columns and the device_events audit table.
 *
 * locations.is_spoofed       — set by the Android app when isFromMockProvider() is true;
 *                              backend skips attendance and geofence checks for these rows.
 *
 * user_geofence_state debounce columns — prevent GPS indoor jitter from spamming exit events:
 *   exit_pending_since       — timestamp when the device first left the geofence boundary
 *   exit_pending_lat/lng     — coordinates of the first exit detection point
 *
 * device_events              — receives GPS-disable, airplane-mode, and shutdown events from
 *                              the Android app for workforce compliance auditing.
 */
export async function initializeAntiCheat() {
  // locations: is_spoofed flag
  await query(`
    ALTER TABLE locations
    ADD COLUMN IF NOT EXISTS is_spoofed BOOLEAN NOT NULL DEFAULT FALSE
  `);

  // user_geofence_state: exit-debounce state
  await query(`
    ALTER TABLE user_geofence_state
    ADD COLUMN IF NOT EXISTS exit_pending_since TIMESTAMP WITH TIME ZONE
  `);
  await query(`
    ALTER TABLE user_geofence_state
    ADD COLUMN IF NOT EXISTS exit_pending_lat DOUBLE PRECISION
  `);
  await query(`
    ALTER TABLE user_geofence_state
    ADD COLUMN IF NOT EXISTS exit_pending_lng DOUBLE PRECISION
  `);

  // device_events: tamper audit trail
  await query(`
    CREATE TABLE IF NOT EXISTS device_events (
      id           SERIAL PRIMARY KEY,
      user_id      INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      event_type   TEXT NOT NULL,
      detail       TEXT,
      occurred_at  TIMESTAMP WITH TIME ZONE NOT NULL,
      received_at  TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
    )
  `);
  await query(`
    CREATE INDEX IF NOT EXISTS idx_device_events_user_occurred
    ON device_events (user_id, occurred_at DESC)
  `);

  console.log('✓ anti-cheat schema ready (is_spoofed, geofence debounce, device_events)');
}
