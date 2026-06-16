import { query } from './index.js';

export async function initializeAttendance() {
  await query(`
    CREATE TABLE IF NOT EXISTS attendance (
      id SERIAL PRIMARY KEY,
      user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      date DATE NOT NULL,
      check_in TIMESTAMP WITH TIME ZONE,
      check_out TIMESTAMP WITH TIME ZONE,
      updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
      UNIQUE(user_id, date)
    )
  `);
  console.log('✓ attendance table ready');
}
