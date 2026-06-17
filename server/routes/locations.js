import express from 'express';
import rateLimit from 'express-rate-limit';
import { query } from '../db/index.js';
import { authorize, requireAdmin } from '../middleware/auth.js';

const router = express.Router();

const uploadLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: 60,
  message: { error: 'Too many requests' },
});

function haversine(lat1, lon1, lat2, lon2) {
  const R = 6371;
  const dLat = (lat2 - lat1) * Math.PI / 180;
  const dLon = (lon2 - lon1) * Math.PI / 180;
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180) * Math.sin(dLon / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

async function createUploadAudit({ userId, pointsCount, validPointsCount, status, errorMessage, ipAddress, requestBody }) {
  const auditQuery = `INSERT INTO location_upload_audit (user_id, points_count, valid_points_count, status, error_message, ip_address, request_body)
                      VALUES ($1, $2, $3, $4, $5, $6, $7)`;
  const bodyJson = requestBody ? JSON.stringify(requestBody) : null;
  await query(auditQuery, [userId, pointsCount, validPointsCount, status, errorMessage || null, ipAddress || null, bodyJson]);
  console.info('Location upload audit saved', {
    userId,
    pointsCount,
    validPointsCount,
    status,
    errorMessage,
    ipAddress,
  });
}

router.post('/', uploadLimiter, authorize, async (req, res) => {
  const points = Array.isArray(req.body) ? req.body : [req.body];
  const pointsReceived = points.length;
  const userId = req.user?.id;
  const ipAddress = req.ip || req.headers['x-forwarded-for'] || null;

  try {
    console.log('Upload locations request', { userId, pointsReceived });
    if (!points.length) {
      await createUploadAudit({
        userId,
        pointsCount: 0,
        validPointsCount: 0,
        status: 'rejected',
        errorMessage: 'At least one location point is required',
        ipAddress,
        requestBody: req.body,
      });
      return res.status(400).json({ error: 'At least one location point is required' });
    }

    const values = [];
    const placeholders = [];
    let validPointsCount = 0;
    const validTimestamps = [];

    points.forEach((point, index) => {
      const { latitude, longitude, recorded_at, battery_level } = point;
      if (
        typeof latitude !== 'number' ||
        typeof longitude !== 'number' ||
        !recorded_at
      ) {
        console.warn('Invalid location point skipped', { index, point });
        return;
      }
      // Convert timestamp from milliseconds to ISO string for database insert
      let recordedAtIso;
      try {
        recordedAtIso = new Date(recorded_at).toISOString();
      } catch (e) {
        console.warn('Invalid timestamp skipped', { index, recorded_at });
        return;
      }
      validTimestamps.push(recordedAtIso);
      const batteryVal = (typeof battery_level === 'number') ? battery_level : null;
      const idx = validPointsCount * 5;
      placeholders.push(`($${idx + 1}, $${idx + 2}, $${idx + 3}, $${idx + 4}, NOW(), $${idx + 5})`);
      values.push(userId, latitude, longitude, recordedAtIso, batteryVal);
      validPointsCount += 1;
    });

    if (!placeholders.length) {
      console.warn('Upload rejected: no valid location points', { userId, body: req.body });
      await createUploadAudit({
        userId,
        pointsCount: pointsReceived,
        validPointsCount: 0,
        status: 'rejected',
        errorMessage: 'Valid location points required',
        ipAddress,
        requestBody: req.body,
      });
      return res.status(400).json({ error: 'Valid location points required' });
    }

    const queryText = `INSERT INTO locations (user_id, latitude, longitude, recorded_at, received_at, battery_level) VALUES ${placeholders.join(', ')} RETURNING id`;
    await query(queryText, values);

    // Attendance upsert: earliest timestamp as check_in (on INSERT), latest as check_out (always update)
    try {
      const earliest = validTimestamps[0];
      const latest = validTimestamps[validTimestamps.length - 1];
      await query(
        `INSERT INTO attendance (user_id, date, check_in, check_out, updated_at)
         VALUES ($1, CURRENT_DATE, $2, $3, NOW())
         ON CONFLICT (user_id, date) DO UPDATE
         SET check_out = EXCLUDED.check_out, updated_at = NOW()`,
        [userId, earliest, latest]
      );
    } catch (attendanceErr) {
      console.error('Failed to upsert attendance record', attendanceErr);
    }

    // Geofence checks
    try {
      const geofencesRes = await query('SELECT id, latitude, longitude, radius_meters FROM geofences');
      const geofences = geofencesRes.rows;
      if (geofences.length > 0) {
        const io = req.app.get('io');
        for (const point of points) {
          const { latitude, longitude } = point;
          if (typeof latitude !== 'number' || typeof longitude !== 'number') continue;
          for (const gf of geofences) {
            const distMeters = haversine(latitude, longitude, gf.latitude, gf.longitude) * 1000;
            const isInside = distMeters <= gf.radius_meters;
            const stateRes = await query(
              'SELECT inside FROM user_geofence_state WHERE user_id = $1 AND geofence_id = $2',
              [userId, gf.id]
            );
            const prevInside = stateRes.rows[0]?.inside ?? false;
            await query(
              `INSERT INTO user_geofence_state (user_id, geofence_id, inside)
               VALUES ($1, $2, $3)
               ON CONFLICT (user_id, geofence_id) DO UPDATE SET inside = EXCLUDED.inside`,
              [userId, gf.id, isInside]
            );
            if (io && isInside !== prevInside) {
              const event = isInside ? 'entered' : 'exited';
              io.emit('geofence:alert', { user_id: userId, geofence_id: gf.id, event });
            }
          }
        }
      }
    } catch (geofenceErr) {
      console.error('Geofence check failed', geofenceErr);
    }

    await createUploadAudit({
      userId,
      pointsCount: pointsReceived,
      validPointsCount,
      status: 'accepted',
      ipAddress,
      requestBody: req.body,
    });
    console.log('Location points stored', { userId, count: validPointsCount });

    // Broadcast the latest location for this user to connected clients via Socket.IO (if available)
    try {
      const io = req.app.get('io');
      if (io) {
        const latestRes = await query(
          `SELECT u.id AS user_id, u.name, u.email, l.latitude, l.longitude, l.recorded_at, l.received_at,
                  (l.recorded_at >= NOW() - INTERVAL '10 minutes') AS is_live, l.battery_level
           FROM users u, locations l
           WHERE u.id = $1
           AND l.user_id = u.id
           ORDER BY l.recorded_at DESC
           LIMIT 1`,
          [userId]
        );
        if (latestRes && latestRes.rows && latestRes.rows[0]) {
          const payload = latestRes.rows[0];
          try {
            io.emit('location:uploaded', payload);
            console.info('Emitted location:uploaded event', { userId });
          } catch (emitErr) {
            console.error('Failed to emit socket event', emitErr);
          }
        }
      }
    } catch (emitQueryErr) {
      console.error('Failed to query latest location for socket emit', emitQueryErr);
    }

    return res.status(201).json({ message: 'Location points accepted' });
  } catch (err) {
    console.error('Upload locations error', err);
    try {
      await createUploadAudit({
        userId,
        pointsCount: pointsReceived,
        validPointsCount: 0,
        status: 'error',
        errorMessage: err.message,
        ipAddress,
        requestBody: req.body,
      });
    } catch (auditErr) {
      console.error('Failed to write upload audit record', auditErr);
    }
    return res.status(500).json({ error: 'Unable to store location points' });
  }
});

router.get('/latest', authorize, requireAdmin, async (req, res) => {
  const includeStale = req.query.include_stale === 'true';
  try {
    const timeFilter = includeStale ? '' : "AND recorded_at >= NOW() - INTERVAL '10 minutes'";
    const queryText = `
      SELECT u.id AS user_id, u.name AS name, u.email AS email,
             l.latitude, l.longitude, l.recorded_at, l.received_at,
             (l.recorded_at >= NOW() - INTERVAL '10 minutes') AS is_live,
             l.battery_level
      FROM users u
      INNER JOIN locations l ON l.user_id = u.id
      INNER JOIN (
        SELECT user_id, MAX(recorded_at) AS max_recorded_at
        FROM locations
        WHERE true ${timeFilter}
        GROUP BY user_id
      ) latest ON latest.user_id = l.user_id AND latest.max_recorded_at = l.recorded_at
      WHERE u.role != $1
      ORDER BY u.name
    `;
    const result = await query(queryText, ['admin']);
    console.info('Fetch latest locations', { includeStale, count: result.rows.length });
    return res.json({ locations: result.rows });
  } catch (err) {
    console.error('Fetch latest locations error', err);
    return res.status(500).json({ error: 'Unable to fetch latest locations' });
  }
});

router.get('/history/:userId', authorize, requireAdmin, async (req, res) => {
  const userId = parseInt(req.params.userId, 10);
  if (isNaN(userId)) {
    return res.status(400).json({ error: 'Invalid user ID' });
  }
  const date = req.query.date || new Date().toISOString().split('T')[0]; // Default to today
  const dayStart = new Date(date + 'T00:00:00.000Z');
  const dayEnd = new Date(dayStart.getTime() + 86400000);

  try {
    const queryText = `SELECT id,
                              user_id,
                              latitude,
                              longitude,
                              recorded_at,
                              received_at
                       FROM locations
                       WHERE user_id = $1
                       AND recorded_at >= $2
                       AND recorded_at < $3
                       ORDER BY recorded_at ASC`;

    const result = await query(queryText, [userId, dayStart.toISOString(), dayEnd.toISOString()]);
    console.info('Fetch location history', { userId, date, count: result.rows.length });
    return res.json({ history: result.rows });
  } catch (err) {
    console.error('Fetch location history error', err);
    return res.status(500).json({ error: 'Unable to fetch location history' });
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

router.get('/history/:userId/export', authorize, requireAdmin, async (req, res) => {
  const userId = parseInt(req.params.userId, 10);
  if (isNaN(userId)) {
    return res.status(400).json({ error: 'Invalid user ID' });
  }
  const date = req.query.date || new Date().toISOString().split('T')[0];
  const dayStart = new Date(date + 'T00:00:00.000Z');
  const dayEnd = new Date(dayStart.getTime() + 86400000);

  try {
    // Note: accuracy is not persisted on the locations table, so that column is
    // included for the requested format but left empty.
    const queryText = `SELECT recorded_at, latitude, longitude
                       FROM locations
                       WHERE user_id = $1
                       AND recorded_at >= $2
                       AND recorded_at < $3
                       ORDER BY recorded_at ASC`;
    const result = await query(queryText, [userId, dayStart.toISOString(), dayEnd.toISOString()]);

    const lines = ['Timestamp,Latitude,Longitude,Accuracy'];
    for (const row of result.rows) {
      lines.push([
        csvEscape(row.recorded_at),
        csvEscape(row.latitude),
        csvEscape(row.longitude),
        '',
      ].join(','));
    }
    const csv = lines.join('\n');

    res.setHeader('Content-Type', 'text/csv');
    res.setHeader('Content-Disposition', `attachment; filename="location-history-${userId}-${date}.csv"`);
    return res.send(csv);
  } catch (err) {
    console.error('Export location history error', err);
    return res.status(500).json({ error: 'Unable to export location history' });
  }
});

router.get('/stats/distance', authorize, requireAdmin, async (req, res) => {
  const { user_id, date } = req.query;
  if (!user_id || !date) {
    return res.status(400).json({ error: 'user_id and date are required' });
  }
  try {
    const dayStart = new Date(date + 'T00:00:00.000Z');
    const dayEnd = new Date(dayStart.getTime() + 86400000);
    const result = await query(
      `SELECT latitude, longitude FROM locations
       WHERE user_id = $1 AND recorded_at >= $2 AND recorded_at < $3
       ORDER BY recorded_at ASC`,
      [user_id, dayStart.toISOString(), dayEnd.toISOString()]
    );
    const pts = result.rows;
    let distanceKm = 0;
    for (let i = 1; i < pts.length; i++) {
      distanceKm += haversine(
        parseFloat(pts[i - 1].latitude), parseFloat(pts[i - 1].longitude),
        parseFloat(pts[i].latitude), parseFloat(pts[i].longitude)
      );
    }
    return res.json({ user_id: parseInt(user_id, 10), date, distance_km: Math.round(distanceKm * 100) / 100 });
  } catch (err) {
    console.error('Distance stats error', err);
    return res.status(500).json({ error: 'Unable to compute distance' });
  }
});

router.get('/upload-audit', authorize, requireAdmin, async (req, res) => {
  try {
    const result = await query(
      `SELECT la.id,
              la.user_id,
              u.name AS user_name,
              u.email AS user_email,
              la.points_count,
              la.valid_points_count,
              la.status,
              la.error_message,
              la.ip_address,
              la.request_body,
              la.attempted_at
       FROM location_upload_audit la
       JOIN users u ON u.id = la.user_id
       ORDER BY la.attempted_at DESC
       LIMIT 100`);

    return res.json({ audits: result.rows });
  } catch (err) {
    console.error('Fetch upload audit error', err);
    return res.status(500).json({ error: 'Unable to fetch upload audit records' });
  }
});

export default router;
