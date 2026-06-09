import express from 'express';
import bcrypt from 'bcrypt';
import jwt from 'jsonwebtoken';
import dotenv from 'dotenv';
import { query } from '../db/index.js';

dotenv.config();
const router = express.Router();
const JWT_SECRET = process.env.JWT_SECRET;
const JWT_EXPIRES_IN = process.env.JWT_EXPIRES_IN || '8h';

router.post('/login', async (req, res) => {
  try {
    const { identifier, password } = req.body;
    const loginIdentifier = identifier?.toString().trim();
    if (!loginIdentifier || !password) {
      return res.status(400).json({ error: 'Email/User ID and password are required' });
    }

    const result = await query(
      'SELECT id, name, email, password_hash, role FROM users WHERE email = $1 OR name = $1 OR LOWER(name) = LOWER($1) OR id::text = $1',
      [loginIdentifier]
    );
    const user = result.rows[0];
    if (!user) {
      return res.status(401).json({ error: 'Invalid credentials' });
    }

    const validPassword = await bcrypt.compare(password, user.password_hash);
    if (!validPassword) {
      return res.status(401).json({ error: 'Invalid credentials' });
    }

    const token = jwt.sign({ id: user.id, name: user.name, email: user.email, role: user.role }, JWT_SECRET, {
      expiresIn: JWT_EXPIRES_IN,
    });

    return res.json({ token, user: { id: user.id, name: user.name, email: user.email, role: user.role } });
  } catch (err) {
    console.error('Login error:', err.message, err.stack);
    return res.status(500).json({ error: 'Server error during login', details: err.message });
  }
});

export default router;
