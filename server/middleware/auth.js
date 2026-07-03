import jwt from 'jsonwebtoken';
import dotenv from 'dotenv';
import { query } from '../db/index.js';

dotenv.config();

const JWT_SECRET = process.env.JWT_SECRET;

// Access tokens are effectively non-expiring (JWT_EXPIRES_IN=100y), so
// refresh_token_version is the only revocation lever — an admin bumping it
// must cut off already-issued access tokens too, not just future refreshes.
// This means every request costs one indexed lookup on users.id.
async function verifyAndCheckRevocation(token) {
  const payload = jwt.verify(token, JWT_SECRET);
  const result = await query('SELECT refresh_token_version FROM users WHERE id = $1', [payload.id]);
  const user = result.rows[0];
  if (!user || (user.refresh_token_version ?? 0) !== (payload.rtv ?? 0)) {
    throw new Error('Token revoked');
  }
  return payload;
}

export async function authorize(req, res, next) {
  const authHeader = req.headers.authorization;
  let token;
  if (authHeader && authHeader.startsWith('Bearer ')) {
    token = authHeader.split(' ')[1];
  }

  if (!token) {
    return res.status(401).json({ error: 'Missing or invalid auth token' });
  }

  try {
    req.user = await verifyAndCheckRevocation(token);
    next();
  } catch (err) {
    return res.status(401).json({ error: 'Unauthorized: invalid token' });
  }
}

// Used only on export endpoints where the browser must pass the token as a
// query param (CSV downloads via <a href> cannot set Authorization headers).
// Do NOT use on mutation endpoints — tokens in URLs appear in server logs.
export async function authorizeForExport(req, res, next) {
  const authHeader = req.headers.authorization;
  let token;
  if (authHeader && authHeader.startsWith('Bearer ')) {
    token = authHeader.split(' ')[1];
  } else if (req.query && req.query.token) {
    token = req.query.token;
  }

  if (!token) {
    return res.status(401).json({ error: 'Missing or invalid auth token' });
  }

  try {
    req.user = await verifyAndCheckRevocation(token);
    next();
  } catch (err) {
    return res.status(401).json({ error: 'Unauthorized: invalid token' });
  }
}

export function requireAdmin(req, res, next) {
  if (!req.user || req.user.role !== 'admin') {
    return res.status(403).json({ error: 'Admin privileges required' });
  }
  next();
}
