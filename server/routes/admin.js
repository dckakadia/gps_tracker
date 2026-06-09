import express from 'express';
import bcrypt from 'bcrypt';
import { query } from '../db/index.js';
import { authorize, requireAdmin } from '../middleware/auth.js';

const router = express.Router();

router.use(authorize, requireAdmin);

router.get('/users', async (req, res) => {
  try {
    const result = await query('SELECT id, name, email, role, created_at, updated_at FROM users WHERE role = $1 ORDER BY name', ['salesperson']);
    return res.json({ users: result.rows });
  } catch (err) {
    console.error('Fetch users error', err);
    return res.status(500).json({ error: 'Unable to load users' });
  }
});

router.post('/users', async (req, res) => {
  try {
    const { name, email, password } = req.body;
    if (!name || !email || !password) {
      return res.status(400).json({ error: 'Name, email, and password are required' });
    }

    const existing = await query('SELECT id FROM users WHERE email = $1', [email]);
    if (existing.rowCount > 0) {
      return res.status(409).json({ error: 'Email already registered' });
    }

    const passwordHash = await bcrypt.hash(password, 12);
    const result = await query(
      'INSERT INTO users (name, email, password_hash, role, created_at, updated_at) VALUES ($1, $2, $3, $4, NOW(), NOW()) RETURNING id, name, email, role, created_at, updated_at',
      [name, email, passwordHash, 'salesperson'],
    );

    return res.status(201).json({ user: result.rows[0] });
  } catch (err) {
    console.error('Create salesperson error', err);
    return res.status(500).json({ error: 'Unable to create user' });
  }
});

router.put('/users/:id', async (req, res) => {
  try {
    const { id } = req.params;
    const { name, email, password, role } = req.body;
    const updates = [];
    const params = [];

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

export default router;
