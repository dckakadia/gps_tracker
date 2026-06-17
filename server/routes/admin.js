import express from 'express';
import bcrypt from 'bcrypt';
import { query } from '../db/index.js';
import { authorize, requireAdmin } from '../middleware/auth.js';

const router = express.Router();

router.use(authorize, requireAdmin);

router.get('/users', async (req, res) => {
  try {
    const result = await query('SELECT id, name, email, role, created_at, updated_at FROM users WHERE role != $1 ORDER BY name', ['admin']);
    return res.json({ users: result.rows });
  } catch (err) {
    console.error('Fetch users error', err);
    return res.status(500).json({ error: 'Unable to load users' });
  }
});

router.post('/users', async (req, res) => {
  try {
    const { name, email, password, role } = req.body;
    if (!name || !email || !password) {
      return res.status(400).json({ error: 'Name, email, and password are required' });
    }

    const existing = await query('SELECT id FROM users WHERE email = $1', [email]);
    if (existing.rowCount > 0) {
      return res.status(409).json({ error: 'Email already registered' });
    }

    const userRole = role || 'salesperson';
    const passwordHash = await bcrypt.hash(password, 12);
    const result = await query(
      'INSERT INTO users (name, email, password_hash, role, created_at, updated_at) VALUES ($1, $2, $3, $4, NOW(), NOW()) RETURNING id, name, email, role, created_at, updated_at',
      [name, email, passwordHash, userRole],
    );

    return res.status(201).json({ user: result.rows[0] });
  } catch (err) {
    console.error('Create user error', err);
    return res.status(500).json({ error: 'Unable to create user' });
  }
});

router.put('/users/:id', async (req, res) => {
  try {
    const { id } = req.params;
    const { name, email, password, role } = req.body;
    const updates = [];
    const params = [];

    if (email) {
      const conflict = await query('SELECT id FROM users WHERE email = $1 AND id != $2', [email, id]);
      if (conflict.rowCount > 0) {
        return res.status(409).json({ error: 'Email already in use by another user' });
      }
    }

    if (name) {
      params.push(name);
      updates.push(`name = $${params.length}`);
    }
    if (email) {
      params.push(email);
      updates.push(`email = $${params.length}`);
    }
    if (password) {
      const passwordHash = await bcrypt.hash(password, 12);
      params.push(passwordHash);
      updates.push(`password_hash = $${params.length}`);
    }
    if (role) {
      params.push(role);
      updates.push(`role = $${params.length}`);
    }

    if (!updates.length) {
      return res.status(400).json({ error: 'No update values provided' });
    }

    params.push(id);
    const setClause = updates.join(', ');
    const result = await query(
      `UPDATE users SET ${setClause}, updated_at = NOW() WHERE id = $${params.length} RETURNING id, name, email, role, created_at, updated_at`,
      params,
    );

    if (result.rowCount === 0) {
      return res.status(404).json({ error: 'User not found' });
    }
    return res.json({ user: result.rows[0] });
  } catch (err) {
    console.error('Update salesperson error', err);
    return res.status(500).json({ error: 'Unable to update user' });
  }
});

router.delete('/users/:id', async (req, res) => {
  try {
    const { id } = req.params;
    if (String(req.user.id) === String(id)) {
      return res.status(400).json({ error: 'You cannot delete your own account' });
    }
    const result = await query('DELETE FROM users WHERE id = $1 RETURNING id', [id]);
    if (result.rowCount === 0) {
      return res.status(404).json({ error: 'User not found' });
    }
    return res.json({ message: 'Salesperson deleted' });
  } catch (err) {
    console.error('Delete salesperson error', err);
    return res.status(500).json({ error: 'Unable to delete user' });
  }
});

router.get('/attendance', async (req, res) => {
  const date = req.query.date || new Date().toISOString().split('T')[0];
  try {
    const result = await query(
      `SELECT u.id, u.name, a.check_in, a.check_out,
         EXTRACT(EPOCH FROM (a.check_out - a.check_in))/3600 AS hours
       FROM users u
       LEFT JOIN attendance a ON a.user_id = u.id AND a.date = $1::date
       WHERE u.role = 'salesperson'
       ORDER BY u.name`,
      [date]
    );
    return res.json({ attendance: result.rows, date });
  } catch (err) {
    console.error('Fetch attendance error', err);
    return res.status(500).json({ error: 'Unable to fetch attendance' });
  }
});

function csvEscape(value) {
  if (value === null || value === undefined) return '';
  const str = String(value);
  if (/[",\n]/.test(str)) {
    return '"' + str.replace(/"/g, '""') + '"';
  }
  return str;
}

router.get('/attendance/export', async (req, res) => {
  const date = req.query.date || new Date().toISOString().split('T')[0];
  try {
    const result = await query(
      `SELECT u.id, u.name, a.check_in, a.check_out,
         EXTRACT(EPOCH FROM (a.check_out - a.check_in))/3600 AS hours
       FROM users u
       LEFT JOIN attendance a ON a.user_id = u.id AND a.date = $1::date
       WHERE u.role = 'salesperson'
       ORDER BY u.name`,
      [date]
    );

    const header = ['Name', 'Check In', 'Check Out', 'Hours'];
    const lines = [header.join(',')];
    for (const row of result.rows) {
      lines.push([
        csvEscape(row.name),
        csvEscape(row.check_in),
        csvEscape(row.check_out),
        csvEscape(row.hours != null ? Number(row.hours).toFixed(2) : ''),
      ].join(','));
    }
    const csv = lines.join('\n');

    res.setHeader('Content-Type', 'text/csv');
    res.setHeader('Content-Disposition', `attachment; filename="attendance-${date}.csv"`);
    return res.send(csv);
  } catch (err) {
    console.error('Export attendance error', err);
    return res.status(500).json({ error: 'Unable to export attendance' });
  }
});

export default router;
