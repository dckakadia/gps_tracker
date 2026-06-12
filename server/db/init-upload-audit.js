import { query } from './index.js';

export async function initializeUploadAudit() {
  try {
    await query(
      `CREATE TABLE IF NOT EXISTS location_upload_audit (
        id SERIAL PRIMARY KEY,
        user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        points_count INTEGER NOT NULL,
        valid_points_count INTEGER NOT NULL,
        status TEXT NOT NULL,
        error_message TEXT,
        ip_address TEXT,
        request_body JSONB,
        attempted_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
      )`
    );
    await query(`CREATE INDEX IF NOT EXISTS idx_upload_audit_user_id ON location_upload_audit (user_id)`);
    await query(`CREATE INDEX IF NOT EXISTS idx_upload_audit_attempted_at ON location_upload_audit (attempted_at)`);
    console.log('✓ Location upload audit table is available');
  } catch (err) {
    console.error('Failed to initialize location upload audit table:', err.message);
    throw err;
  }
}
