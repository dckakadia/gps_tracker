import { query } from './index.js';

export async function initializeUsername() {
  try {
    // Try to set username for existing admin user (dckakadia)
    const adminUser = await query("SELECT id FROM users WHERE email = 'dckakadia@gmail.com'");
    if (adminUser.rowCount > 0) {
      const userId = adminUser.rows[0].id;
      await query('UPDATE users SET username = $1 WHERE id = $2', ['dckakadia', userId]);
      console.log('✓ Admin user username set to "dckakadia"');
    }
  } catch (err) {
    // If column doesn't exist or other errors, log but don't fail startup
    if (err.message.includes('column "username" of relation "users" does not exist')) {
      console.log('⚠ Username column does not exist. Run schema migration: ALTER TABLE users ADD COLUMN username TEXT UNIQUE;');
    } else {
      console.log('ℹ Username initialization info:', err.message);
    }
  }
}
