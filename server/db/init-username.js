import { query } from './index.js';

export async function initializeUsername() {
  try {
    // First, ensure the username column exists
    await query('ALTER TABLE users ADD COLUMN IF NOT EXISTS username TEXT UNIQUE');
    console.log('✓ Username column verified (created if missing)');

    // Try to set username for existing admin user (dckakadia)
    const adminUser = await query("SELECT id FROM users WHERE email = 'dckakadia@gmail.com'");
    if (adminUser.rowCount > 0) {
      const userId = adminUser.rows[0].id;
      await query('UPDATE users SET username = $1 WHERE id = $2', ['dckakadia', userId]);
      console.log('✓ Admin user username set to "dckakadia"');
    }
  } catch (err) {
    console.error('✗ Error during username initialization:', err.message);
    throw err;
  }
}
