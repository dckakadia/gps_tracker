import { query } from './index.js';

export async function initializeBatteryColumn() {
  await query(`ALTER TABLE locations ADD COLUMN IF NOT EXISTS battery_level INTEGER`);
  // Keep archive schema in sync — nightly CTE does SELECT * so columns must match
  await query(`ALTER TABLE locations_archive ADD COLUMN IF NOT EXISTS battery_level INTEGER`).catch(() => {});
  console.log('✓ battery_level column ready');
}
