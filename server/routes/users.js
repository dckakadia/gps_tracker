import express from 'express';
import { query } from '../db/index.js';
import { authorize, requireAdmin } from '../middleware/auth.js';
import { sendNotification } from '../services/fcm.js';

const router = express.Router();

// POST /api/users/fcm-token — save FCM token for the authenticated user (any role)
router.post('/fcm-token', authorize, async (req, res) => {
  const { fcm_token } = req.body;
  if (!fcm_token) {
    return res.status(400).json({ error: 'fcm_token is required' });
  }
  try {
    await query('UPDATE users SET fcm_token = $1 WHERE id = $2', [fcm_token, req.user.id]);
    return res.json({ message: 'FCM token saved' });
  } catch (err) {
    console.error('Save FCM token error', err);
    return res.status(500).json({ error: 'Unable to save FCM token' });
  }
});

// GET /api/users/me/attendance — today's check-in/check-out for the authenticated user
router.get('/me/attendance', authorize, async (req, res) => {
  const userId = req.user.id;
  const today = new Date().toISOString().split('T')[0];
  try {
    const result = await query(
      'SELECT check_in, check_out FROM attendance WHERE user_id = $1 AND date = $2',
      [userId, today]
    );
    if (result.rows.length === 0) {
      return res.json({ check_in: null, check_out: null });
    }
    return res.json(result.rows[0]);
  } catch (err) {
    console.error('Fetch own attendance error', err);
    return res.status(500).json({ error: 'Unable to fetch attendance' });
  }
});

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

// POST /api/users/notify — send push notification to a user
router.post('/notify', async (req, res) => {
  const { user_id, message } = req.body;
  if (!user_id || !message) {
    return res.status(400).json({ error: 'user_id and message are required' });
  }
  try {
    const result = await query('SELECT fcm_token FROM users WHERE id = $1', [user_id]);
    if (result.rowCount === 0) {
      return res.status(404).json({ error: 'User not found' });
    }
    const fcmToken = result.rows[0].fcm_token;
    if (!fcmToken) {
      return res.status(422).json({ error: 'User has no FCM token registered' });
    }
    await sendNotification(fcmToken, message);
    return res.json({ message: 'Notification sent' });
  } catch (err) {
    console.error('Send notification error', err);
    return res.status(500).json({ error: 'Unable to send notification' });
  }
});

export default router;
