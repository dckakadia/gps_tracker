import { query } from './index.js';
import dotenv from 'dotenv';
import bcrypt from 'bcrypt';

dotenv.config({ path: new URL('../.env', import.meta.url).pathname });

export async function initializeAdminUser() {
  try {
    const adminEmail = process.env.ADMIN_EMAIL || 'dckakadia@gmail.com';
    const adminName = process.env.ADMIN_NAME || 'dckakadia';
    const adminPassword = process.env.ADMIN_PASSWORD || 'Devin@404404';
    const hashedPassword = await bcrypt.hash(adminPassword, 12);

    const existing = await query('SELECT id FROM users WHERE email = $1', [adminEmail]);
    if (existing.rowCount > 0) {
      console.log(`✓ Admin user already exists: ${adminEmail}`);
      return;
    }

    await query(
      `INSERT INTO users (name, email, username, password_hash, role, created_at, updated_at)
       VALUES ($1, $2, $3, $4, 'admin', NOW(), NOW())`,
      [adminName, adminEmail, adminName, hashedPassword],
    );

    console.log(`✓ Default admin user created: ${adminEmail}`);
    console.log(`  - Admin password: ${adminPassword}`);
    console.log('  - Override with ADMIN_EMAIL, ADMIN_NAME, ADMIN_PASSWORD in .env');
  } catch (err) {
    console.error('✗ Error creating admin user:', err.message);
    throw err;
  }
}
