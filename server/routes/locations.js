import express from 'express';
import { query } from '../db/index.js';
import { authorize, requireAdmin } from '../middleware/auth.js';

const router = express.Router();

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

router.post('/', authorize, async (req, res) => {
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

    points.forEach((point, index) => {
      const { latitude, longitude, recorded_at } = point;
      if (
        typeof latitude !== 'number' ||
        typeof longitude !== 'number' ||
        !recorded_at
      ) {
        console.warn('Invalid location point skipped', { index, point });
        return;
      }
      const idx = validPointsCount * 4;
      placeholders.push(`($${idx + 1}, $${idx + 2}, $${idx + 3}, to_timestamp($${idx + 4}::double precision / 1000), NOW())`);
      values.push(userId, latitude, longitude, recorded_at);
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

    const queryText = `INSERT INTO locations (user_id, latitude, longitude, recorded_at, received_at) VALUES ${placeholders.join(', ')} RETURNING id`; 
    await query(queryText, values);
    await createUploadAudit({
      userId,
      pointsCount: pointsReceived,
      validPointsCount,
      status: 'accepted',
      ipAddress,
      requestBody: req.body,
    });
    console.log('Location points stored', { userId, count: validPointsCount });

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
    const queryText = `SELECT u.id AS user_id,
              u.name,
              u.email,
              l.latitude,
              l.longitude,
              l.recorded_at,
              l.received_at,
              (l.recorded_at >= NOW() - INTERVAL '10 minutes') AS is_live
       FROM users u
       JOIN LATERAL (
         SELECT latitude, longitude, recorded_at, received_at
         FROM locations
         WHERE user_id = u.id
         ${includeStale ? '' : "AND recorded_at >= NOW() - INTERVAL '10 minutes'"}
         ORDER BY recorded_at DESC
         LIMIT 1
       ) l ON true
       WHERE u.role = 'salesperson'
       ORDER BY u.name`;

    const result = await query(queryText);
    console.info('Fetch latest locations', { includeStale, count: result.rows.length });
    return res.json({ locations: result.rows });
  } catch (err) {
    console.error('Fetch latest locations error', err);
    return res.status(500).json({ error: 'Unable to fetch latest locations' });
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
