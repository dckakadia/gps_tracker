import { query } from './index.js';

export async function initializeFcm() {
  await query(`ALTER TABLE users ADD COLUMN IF NOT EXISTS fcm_token TEXT`);
  console.log('✓ fcm_token column ready');
}
