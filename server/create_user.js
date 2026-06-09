import bcrypt from 'bcrypt';
import pool from './db/index.js';

async function createUser() {
  try {
    const email = 'pratik@gmail.com';
    const password = 'Devin@404404';
    const name = 'pratik';
    const role = 'salesperson';

    // Check if user already exists
    const existing = await pool.query(
      'SELECT id FROM users WHERE email = $1',
      [email]
    );

    if (existing.rowCount > 0) {
      console.log('✓ User already exists:', email);
      process.exit(0);
    }

    // Hash the password
    const password_hash = await bcrypt.hash(password, 12);

    // Insert the user
    const result = await pool.query(
      'INSERT INTO users (name, email, password_hash, role, created_at, updated_at) VALUES ($1, $2, $3, $4, NOW(), NOW()) RETURNING id, name, email, role',
      [name, email, password_hash, role]
    );

    console.log('✓ User created successfully:');
    console.log('  ID:', result.rows[0].id);
    console.log('  Name:', result.rows[0].name);
    console.log('  Email:', result.rows[0].email);
    console.log('  Role:', result.rows[0].role);
    console.log('\n✓ Login credentials:');
    console.log('  Email: ' + email);
    console.log('  Password: ' + password);
    
    process.exit(0);
  } catch (error) {
    console.error('Error creating user:', error.message);
    process.exit(1);
  }
}

createUser();
