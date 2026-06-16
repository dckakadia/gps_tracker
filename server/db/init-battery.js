import { query } from './index.js';

export async function initializeBatteryColumn() {
  await query(`ALTER TABLE locations ADD COLUMN IF NOT EXISTS battery_level INTEGER`);
  console.log('✓ battery_level column ready');
}
