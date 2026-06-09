import bcrypt from 'bcrypt';
import dotenv from 'dotenv';
import pool from './db/index.js';

dotenv.config();

async function seedAdminUser() {
  try {
    const adminEmail = process.env.ADMIN_EMAIL || 'dckakadia@gmail.com';
    const adminName = process.env.ADMIN_NAME || 'dckakadia';
    const adminPassword = process.env.ADMIN_PASSWORD || 'Devin@404404';
    const hashedPassword = await bcrypt.hash(adminPassword, 12);

    const existing = await pool.query(
      'SELECT id FROM users WHERE email = $1',
      [adminEmail],
    );

    if (existing.rowCount > 0) {
      console.log(`Admin user already exists: ${adminEmail}`);
      process.exit(0);
    }

    await pool.query(
      `INSERT INTO users (name, email, password_hash, role, created_at, updated_at)
       VALUES ($1, $2, $3, 'admin', NOW(), NOW())`,
      [adminName, adminEmail, hashedPassword],
    );

    console.log('Admin user created successfully: ' + adminEmail);
    console.log('Admin password: ' + adminPassword);
    console.log('If you want to override the account, set ADMIN_EMAIL, ADMIN_NAME, and ADMIN_PASSWORD in .env.');
    process.exit(0);
  } catch (error) {
    console.error('Failed to seed admin user:', error);
    process.exit(1);
  }
}

seedAdminUser();
