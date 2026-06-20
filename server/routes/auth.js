import express from 'express';
import bcrypt from 'bcrypt';
import jwt from 'jsonwebtoken';
import dotenv from 'dotenv';
import { query } from '../db/index.js';
import { logger } from '../logger.js';

dotenv.config();
const router = express.Router();
const JWT_SECRET = process.env.JWT_SECRET;
const REFRESH_SECRET = process.env.REFRESH_SECRET || JWT_SECRET;
const JWT_EXPIRES_IN = process.env.JWT_EXPIRES_IN || '8h';
const REFRESH_EXPIRES_IN = process.env.REFRESH_EXPIRES_IN || '7d';

router.post('/login', async (req, res) => {
  try {
    const { identifier, password } = req.body;
    const loginIdentifier = identifier?.toString().trim();
    if (!loginIdentifier || !password) {
      return res.status(400).json({ error: 'Email/User ID and password are required' });
    }

    const result = await query(
      'SELECT id, name, email, password_hash, role, refresh_token_version FROM users WHERE email = $1 OR name = $1 OR LOWER(name) = LOWER($1) OR id::text = $1',
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

    // Embed refresh_token_version so the token can be revoked by incrementing
    // the column in users (e.g. when an admin deletes or disables the account).
    const refreshToken = jwt.sign(
      { id: user.id, rtv: user.refresh_token_version ?? 0 },
      REFRESH_SECRET,
      { expiresIn: REFRESH_EXPIRES_IN }
    );

    return res.json({ token, refreshToken, user: { id: user.id, name: user.name, email: user.email, role: user.role } });
  } catch (err) {
    logger.error({ err }, 'Login error');
    return res.status(500).json({ error: 'Server error during login' });
  }
});

// Refresh access token using a refresh token
router.post('/refresh', async (req, res) => {
  try {
    const { refreshToken } = req.body;
    if (!refreshToken) return res.status(400).json({ error: 'refreshToken is required' });

    let payload;
    try {
      payload = jwt.verify(refreshToken, REFRESH_SECRET);
    } catch (err) {
      return res.status(401).json({ error: 'Invalid refresh token' });
    }

    // Verify the token version matches — admin can revoke all sessions by
    // incrementing refresh_token_version in the users table.
    const result = await query(
      'SELECT id, name, email, role, refresh_token_version FROM users WHERE id = $1',
      [payload.id]
    );
    const user = result.rows[0];
    if (!user) return res.status(401).json({ error: 'Invalid refresh token (user not found)' });

    if ((user.refresh_token_version ?? 0) !== (payload.rtv ?? 0)) {
      return res.status(401).json({ error: 'Refresh token has been revoked' });
    }

    const newToken = jwt.sign({ id: user.id, name: user.name, email: user.email, role: user.role }, JWT_SECRET, {
      expiresIn: JWT_EXPIRES_IN,
    });

    return res.json({ token: newToken });
  } catch (err) {
    logger.error({ err }, 'Refresh token error');
    return res.status(500).json({ error: 'Server error during token refresh' });
  }
});

export default router;
