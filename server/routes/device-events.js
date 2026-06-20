import express from 'express';
import rateLimit from 'express-rate-limit';
import pool, { query } from '../db/index.js';
import { authorize, requireAdmin } from '../middleware/auth.js';
import { logger } from '../logger.js';

const router = express.Router();

const eventLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: 30,
  message: { error: 'Too many requests' },
});

const ALLOWED_EVENT_TYPES = new Set([
  'gps_disabled', 'gps_enabled',
  'airplane_on', 'airplane_off',
  'shutdown',
]);

// POST /api/device-events
// Receives a batch of system audit events from the Android app.
router.post('/', eventLimiter, authorize, async (req, res) => {
  const events = Array.isArray(req.body) ? req.body : [req.body];
  const userId = req.user?.id;

  if (!events.length) {
    return res.status(400).json({ error: 'At least one event is required' });
  }

  try {
    const rows = [];
    for (const e of events) {
      const { event_type, occurred_at, detail } = e;
      if (!ALLOWED_EVENT_TYPES.has(event_type)) continue;
      if (!occurred_at || typeof occurred_at !== 'number') continue;
      rows.push({
        event_type,
        occurred_at: new Date(occurred_at).toISOString(),
        detail: typeof detail === 'string' ? detail.slice(0, 255) : null,
      });
    }

    if (rows.length === 0) {
      return res.status(201).json({ message: 'No valid events', count: 0 });
    }

    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      const placeholders = rows.map((_, i) => `($1, $${i * 3 + 2}, $${i * 3 + 3}, $${i * 3 + 4})`).join(', ');
      const values = [userId];
      for (const row of rows) values.push(row.event_type, row.detail, row.occurred_at);
      await client.query(
        `INSERT INTO device_events (user_id, event_type, detail, occurred_at) VALUES ${placeholders}`,
        values,
      );
      await client.query('COMMIT');
    } catch (txErr) {
      await client.query('ROLLBACK');
      throw txErr;
    } finally {
      client.release();
    }

    logger.info({ userId, count: rows.length }, 'Device events recorded');
    return res.status(201).json({ message: 'Events recorded', count: rows.length });
  } catch (err) {
    logger.error({ err }, 'Device events error');
    return res.status(500).json({ error: 'Unable to store device events' });
  }
});

// GET /api/device-events — admin view of all tamper events
router.get('/', authorize, requireAdmin, async (req, res) => {
  const { user_id, date } = req.query;
  try {
    let text = `
      SELECT de.id, de.event_type, de.detail, de.occurred_at, de.received_at,
             u.name AS user_name, u.email AS user_email
      FROM device_events de
      JOIN users u ON u.id = de.user_id
    `;
    const params = [];
    const conditions = [];

    if (user_id) {
      params.push(parseInt(user_id, 10));
      conditions.push(`de.user_id = $${params.length}`);
    }
    if (date) {
      const dayStart = new Date(date + 'T00:00:00.000Z').toISOString();
      const dayEnd   = new Date(new Date(date + 'T00:00:00.000Z').getTime() + 86400000).toISOString();
      params.push(dayStart, dayEnd);
      conditions.push(`de.occurred_at >= $${params.length - 1} AND de.occurred_at < $${params.length}`);
    }

    if (conditions.length) text += ' WHERE ' + conditions.join(' AND ');
    text += ' ORDER BY de.occurred_at DESC LIMIT 500';

    const result = await query(text, params);
    return res.json({ events: result.rows });
  } catch (err) {
    logger.error({ err }, 'Fetch device events error');
    return res.status(500).json({ error: 'Unable to fetch device events' });
  }
});

export default router;
