import express from 'express';
import { query } from '../db/index.js';
import { authorize, requireAdmin } from '../middleware/auth.js';

const router = express.Router();

router.post('/', authorize, async (req, res) => {
  try {
    const points = Array.isArray(req.body) ? req.body : [req.body];
    if (!points.length) {
      return res.status(400).json({ error: 'At least one location point is required' });
    }

    const values = [];
    const placeholders = [];

    points.forEach((point, index) => {
      const { latitude, longitude, recorded_at } = point;
      if (
        typeof latitude !== 'number' ||
        typeof longitude !== 'number' ||
        !recorded_at
      ) {
        return;
      }
      const idx = index * 4;
      placeholders.push(`($${idx + 1}, $${idx + 2}, $${idx + 3}, to_timestamp($${idx + 4}::double precision / 1000), NOW())`);
      values.push(req.user.id, latitude, longitude, recorded_at);
    });

    if (!placeholders.length) {
      return res.status(400).json({ error: 'Valid location points required' });
    }

    const queryText = `INSERT INTO locations (user_id, latitude, longitude, recorded_at, received_at) VALUES ${placeholders.join(', ')} RETURNING id`; 
    await query(queryText, values);

    return res.status(201).json({ message: 'Location points accepted' });
  } catch (err) {
    console.error('Upload locations error', err);
    return res.status(500).json({ error: 'Unable to store location points' });
  }
});

router.get('/latest', authorize, requireAdmin, async (req, res) => {
  try {
    const result = await query(
      `SELECT u.id AS user_id, u.name, u.email, l.latitude, l.longitude, l.recorded_at, l.received_at
       FROM users u
       JOIN LATERAL (
         SELECT latitude, longitude, recorded_at, received_at
         FROM locations
         WHERE user_id = u.id
         ORDER BY recorded_at DESC
         LIMIT 1
       ) l ON true
       WHERE u.role = 'salesperson'
       ORDER BY u.name`);

    return res.json({ locations: result.rows });
  } catch (err) {
    console.error('Fetch latest locations error', err);
    return res.status(500).json({ error: 'Unable to fetch latest locations' });
  }
});

export default router;
