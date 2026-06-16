import express from 'express';
import { query } from '../db/index.js';
import { authorize, requireAdmin } from '../middleware/auth.js';

const router = express.Router();

router.use(authorize, requireAdmin);

// GET /api/users/status
router.get('/status', async (req, res) => {
  try {
    const q = `SELECT u.id AS user_id, u.name, MAX(l.received_at) AS last_seen,
                     (MAX(l.received_at) >= NOW() - INTERVAL '30 minutes') AS is_online
               FROM users u
               LEFT JOIN locations l ON l.user_id = u.id
               WHERE u.role != 'admin'
               GROUP BY u.id, u.name
               ORDER BY u.name`;
    const result = await query(q);
    return res.json({ users: result.rows });
  } catch (err) {
    console.error('Fetch users status error', err);
    return res.status(500).json({ error: 'Unable to fetch users status' });
  }
});

export default router;
