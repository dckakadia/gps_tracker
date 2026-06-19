import express from 'express';
import { query } from '../db/index.js';
import { authorize, requireAdmin } from '../middleware/auth.js';
import { detectStops } from '../utils/stopDetector.js';

const router = express.Router();

// ── GET /api/stops?user_id=X&date=Y ──────────────────────────────────────────
// Returns pre-computed stops from the stops table.
// Also supports on-the-fly detection (?compute=true) if no stored stops exist.

router.get('/', authorize, requireAdmin, async (req, res) => {
  const userId = parseInt(req.query.user_id, 10);
  const date   = req.query.date || new Date().toISOString().split('T')[0];

  if (isNaN(userId)) return res.status(400).json({ error: 'user_id required' });

  const dayStart = new Date(date + 'T00:00:00.000Z');
  const dayEnd   = new Date(dayStart.getTime() + 86_400_000);

  try {
    // Return stored stops for the day.
    const stored = await query(
      `SELECT id, user_id, start_time, end_time, lat, lng, duration_seconds
       FROM stops
       WHERE user_id = $1 AND start_time >= $2 AND start_time < $3
       ORDER BY start_time ASC`,
      [userId, dayStart.toISOString(), dayEnd.toISOString()],
    );

    if (stored.rows.length > 0 || req.query.compute !== 'true') {
      return res.json({ stops: stored.rows, source: 'stored' });
    }

    // ── On-the-fly detection (compute=true and no stored stops) ───────────────
    const pts = await query(
      `SELECT latitude, longitude, recorded_at, speed
       FROM locations
       WHERE user_id = $1 AND recorded_at >= $2 AND recorded_at < $3
         AND is_spoofed = FALSE
       ORDER BY recorded_at ASC`,
      [userId, dayStart.toISOString(), dayEnd.toISOString()],
    );

    if (pts.rows.length < 2) {
      return res.json({ stops: [], source: 'computed' });
    }

    const detected = detectStops(pts.rows);

    // Persist detected stops so future calls are fast.
    for (const stop of detected) {
      await query(
        `INSERT INTO stops (user_id, start_time, end_time, lat, lng, duration_seconds)
         VALUES ($1,$2,$3,$4,$5,$6)
         ON CONFLICT DO NOTHING`,
        [userId, stop.start_time, stop.end_time, stop.lat, stop.lng, stop.duration_seconds],
      );
    }

    return res.json({ stops: detected, source: 'computed' });
  } catch (err) {
    console.error('Fetch stops error', err);
    return res.status(500).json({ error: 'Unable to fetch stops' });
  }
});

// ── POST /api/stops/detect — trigger detection for a user+day manually ────────

router.post('/detect', authorize, requireAdmin, async (req, res) => {
  const { user_id, date } = req.body;
  if (!user_id || !date) return res.status(400).json({ error: 'user_id and date required' });

  const userId   = parseInt(user_id, 10);
  const dayStart = new Date(date + 'T00:00:00.000Z');
  const dayEnd   = new Date(dayStart.getTime() + 86_400_000);

  try {
    const pts = await query(
      `SELECT latitude, longitude, recorded_at, speed
       FROM locations
       WHERE user_id = $1 AND recorded_at >= $2 AND recorded_at < $3
         AND is_spoofed = FALSE
       ORDER BY recorded_at ASC`,
      [userId, dayStart.toISOString(), dayEnd.toISOString()],
    );

    const detected = detectStops(pts.rows);

    // Delete old computed stops for this day to avoid duplicates, then re-insert.
    await query(
      `DELETE FROM stops WHERE user_id = $1 AND start_time >= $2 AND start_time < $3`,
      [userId, dayStart.toISOString(), dayEnd.toISOString()],
    );

    for (const stop of detected) {
      await query(
        `INSERT INTO stops (user_id, start_time, end_time, lat, lng, duration_seconds)
         VALUES ($1,$2,$3,$4,$5,$6)`,
        [userId, stop.start_time, stop.end_time, stop.lat, stop.lng, stop.duration_seconds],
      );
    }

    return res.json({ detected: detected.length, stops: detected });
  } catch (err) {
    console.error('Stop detection error', err);
    return res.status(500).json({ error: 'Stop detection failed' });
  }
});

export default router;
