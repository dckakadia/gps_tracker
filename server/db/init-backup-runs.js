import { query } from './index.js';

export async function initializeBackupRuns() {
  await query(`
    CREATE TABLE IF NOT EXISTS backup_runs (
      id           SERIAL PRIMARY KEY,
      started_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      finished_at  TIMESTAMPTZ,
      status       TEXT NOT NULL DEFAULT 'running',
      error_message TEXT
    )
  `);
  console.log('✓ backup_runs table ready');
}
