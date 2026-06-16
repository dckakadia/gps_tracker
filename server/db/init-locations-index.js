import { query } from './index.js';

export async function initializeLocationsIndex() {
  try {
    await query(`CREATE INDEX IF NOT EXISTS idx_locations_user_recorded_at ON locations(user_id, recorded_at DESC);`);
    console.log('✓ Created index idx_locations_user_recorded_at (if not exists)');
  } catch (err) {
    // Index may already exist and db user may not own the table — harmless
    if (err.message && (err.message.includes('already exists') || err.message.includes('must be owner'))) {
      console.log('✓ Index idx_locations_user_recorded_at already exists');
    } else {
      console.error('Failed to create locations index:', err.message);
      throw err;
    }
  }
}
