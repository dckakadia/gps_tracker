import { query } from './index.js';

export async function initializeRefreshTokenVersion() {
  await query(`
    ALTER TABLE users
    ADD COLUMN IF NOT EXISTS refresh_token_version INTEGER NOT NULL DEFAULT 0
  `);
  console.log('✓ refresh_token_version column ready');
}
