import express from 'express';
import rateLimit from 'express-rate-limit';
import { query } from '../db/index.js';
import { logger } from '../logger.js';
import { authorize, authorizeForExport, requireAdmin } from '../middleware/auth.js';
import { getFilterForUser, resetFilterForUser } from '../utils/kalmanFilter.js';
import { validateGPSPoint } from '../utils/gpsValidator.js';
import { snapToRoads } from '../utils/roadSnapper.js';
import { detectStops } from '../utils/stopDetector.js';

const router = express.Router();

const uploadLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: 60,
  message: { error: 'Too many requests' },
});

// ── Geofence exit-debounce ────────────────────────────────────────────────────
const EXIT_DEBOUNCE_MS      = 3 * 60 * 1000;
const EXIT_DEBOUNCE_EXTRA_M = 30;

// ── PostGIS ───────────────────────────────────────────────────────────────────
let postgisAvailable = false;
(async () => {
  try {
    await query("SELECT PostGIS_Version()");
    postgisAvailable = true;
    logger.info('PostGIS available — using ST_DWithin for geofence checks');
  } catch {
    logger.info('PostGIS not available — using in-process Haversine fallback');
  }
})();

// ── Haversine (km) ────────────────────────────────────────────────────────────
function haversine(lat1, lon1, lat2, lon2) {
  const R = 6371;
  const dLat = (lat2 - lat1) * Math.PI / 180;
  const dLon = (lon2 - lon1) * Math.PI / 180;
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180) *
    Math.sin(dLon / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

// ── Geofence helpers ──────────────────────────────────────────────────────────

async function getGeofencesContaining(lat, lng) {
  if (postgisAvailable) {
    const res = await query(
      `SELECT id, name, latitude, longitude, radius_meters
       FROM geofences
       WHERE geog IS NOT NULL
         AND ST_DWithin(
               geog,
               ST_SetSRID(ST_MakePoint($2, $1), 4326)::geography,
               radius_meters
             )`,
      [lat, lng],
    );
    return res.rows;
  }
  const all = await query('SELECT id, name, latitude, longitude, radius_meters FROM geofences');
  return all.rows.filter(gf =>
    haversine(lat, lng, gf.latitude, gf.longitude) * 1000 <= gf.radius_meters,
  );
}

async function getAllGeofences() {
  const res = await query('SELECT id, name, latitude, longitude, radius_meters FROM geofences');
  return res.rows;
}

// ── Upload audit ──────────────────────────────────────────────────────────────

async function createUploadAudit({ userId, pointsCount, validPointsCount, status, errorMessage, ipAddress, requestBody }) {
  try {
    await query(
      `INSERT INTO location_upload_audit
         (user_id, points_count, valid_points_count, status, error_message, ip_address, request_body)
       VALUES ($1,$2,$3,$4,$5,$6,$7)`,
      [userId, pointsCount, validPointsCount, status, errorMessage || null,
       ipAddress || null, requestBody ? JSON.stringify(requestBody) : null],
    );
  } catch (e) {
    console.error('Failed to write upload audit', e.message);
  }
}

// ── POST /api/locations ───────────────────────────────────────────────────────

router.post('/', uploadLimiter, authorize, async (req, res) => {
  const points      = Array.isArray(req.body) ? req.body : [req.body];
  const pointsCount = points.length;
  const userId      = req.user?.id;
  const ipAddress   = req.ip || req.headers['x-forwarded-for'] || null;

  if (!points.length) {
    await createUploadAudit({ userId, pointsCount: 0, validPointsCount: 0,
      status: 'rejected', errorMessage: 'Empty payload', ipAddress });
    return res.status(400).json({ error: 'At least one location point is required' });
  }

  try {
    // ── Kalman filter + validation (only for real, non-spoofed points) ─────────
    const kf = getFilterForUser(userId);
    let prevAccepted = null;  // last valid point for speed check

    // Track a timestamp gap: if the user was offline for >10 min, reset the filter.
    const firstTs = points[0].recorded_at ? new Date(points[0].recorded_at).getTime() : null;
    if (firstTs && kf._lastTs && (firstTs - kf._lastTs) > 10 * 60 * 1000) {
      resetFilterForUser(userId);
    }

    // ── Seed prevPoint for server-side derived speed ──────────────────────────
    // Fetch the last stored (non-spoofed) location for this user so we can derive
    // speed for the very first point in a batch even if there's no in-batch predecessor.
    let prevPointForSpeed = null;
    try {
      const prevRes = await query(
        `SELECT latitude, longitude, recorded_at
         FROM locations
         WHERE user_id = $1 AND is_spoofed = FALSE
         ORDER BY recorded_at DESC LIMIT 1`,
        [userId],
      );
      if (prevRes.rows[0]) prevPointForSpeed = prevRes.rows[0];
    } catch { /* non-fatal — proceed without a seed */ }

    const values       = [];
    const placeholders = [];
    let validCount     = 0;
    const validTs      = [];

    for (const [index, point] of points.entries()) {
      const { latitude, longitude, recorded_at, battery_level, is_spoofed,
              accuracy, speed, heading } = point;

      if (typeof latitude !== 'number' || typeof longitude !== 'number' || !recorded_at) {
        logger.warn({ index }, 'Skipping invalid point');
        continue;
      }

      let recordedAtIso;
      try { recordedAtIso = new Date(recorded_at).toISOString(); }
      catch { logger.warn({ index, recorded_at }, 'Invalid timestamp'); continue; }

      const tsMs      = new Date(recordedAtIso).getTime();
      const spoofed   = is_spoofed === true;
      const accuracyM = typeof accuracy === 'number' ? accuracy : null;
      const speedMs   = typeof speed    === 'number' ? speed    : null;
      const headingD  = typeof heading  === 'number' ? heading  : null;
      const batteryV  = typeof battery_level === 'number' ? battery_level : null;

      let finalLat  = latitude;
      let finalLng  = longitude;
      let isFiltered = false;

      if (!spoofed) {
        // ── GPS validation ────────────────────────────────────────────────────
        const vResult = validateGPSPoint(prevAccepted, {
          lat: latitude, lng: longitude, timestamp_ms: tsMs, accuracy_m: accuracyM,
        });

        if (!vResult.valid && vResult.severity === 'hard') {
          // True GPS teleport — discard silently
          logger.info({ userId, index, reason: vResult.reason }, 'GPS point hard-rejected');
          continue;
        }

        if (!vResult.valid && vResult.severity === 'soft') {
          // Low accuracy — save raw point flagged as filtered, skip Kalman
          logger.info({ userId, index, reason: vResult.reason }, 'GPS point soft-rejected (saved as filtered)');
          isFiltered = true;
        } else {
          // Good point — run Kalman smoothing
          prevAccepted = { lat: latitude, lng: longitude, timestamp_ms: tsMs };
          const kfResult = kf.update(latitude, longitude, tsMs, accuracyM);
          finalLat   = kfResult.lat;
          finalLng   = kfResult.lng;
          isFiltered = kfResult.filtered;
        }
      }

      // ── Server-side derived speed ────────────────────────────────────────────
      // If GPS speed is zero/null (common under poor signal), derive speed from the
      // distance to the previous point divided by the elapsed time.
      // Only derive when time delta is 5–120 s and result ≤ 80 m/s (288 km/h).
      // Derived speed is never used when GPS accuracy is ≤ 50 m — GPS is trusted there.
      const derivedSpeedFlag = point.derived_speed === true;
      const gpsSpeed = typeof speedMs === 'number' ? speedMs : null;
      let computedSpeed = null;
      let speedSource   = 'none';

      if (gpsSpeed !== null && gpsSpeed > 0 && accuracyM !== null && accuracyM <= 50) {
        // Reliable GPS speed.
        speedSource = 'gps';
      } else if (derivedSpeedFlag && gpsSpeed !== null && gpsSpeed > 0) {
        // Client already derived and sent the speed — trust it.
        speedSource   = 'derived';
        computedSpeed = gpsSpeed;
      } else if (prevPointForSpeed) {
        // Compute from previous stored/batch point using Haversine (≡ PostGIS ST_Distance on geography).
        const currMs = new Date(recordedAtIso).getTime();
        const prevMs = new Date(prevPointForSpeed.recorded_at).getTime();
        const deltaSec = (currMs - prevMs) / 1000;
        if (deltaSec >= 5 && deltaSec <= 120) {
          const distM = haversine(
            parseFloat(prevPointForSpeed.latitude), parseFloat(prevPointForSpeed.longitude),
            latitude, longitude,
          ) * 1000;
          const derived = distM / deltaSec;
          if (derived <= 80) {
            computedSpeed = Math.round(derived * 100) / 100;
            speedSource   = 'derived';
          }
        }
      }

      // Advance the sliding window (use raw incoming coords for next-point derivation).
      prevPointForSpeed = { latitude, longitude, recorded_at: recordedAtIso };

      validTs.push(recordedAtIso);
      const idx = validCount * 13;
      placeholders.push(
        `($${idx+1},$${idx+2},$${idx+3},$${idx+4},NOW(),$${idx+5},$${idx+6},$${idx+7},$${idx+8},$${idx+9},$${idx+10},$${idx+11},$${idx+12},$${idx+13})`
      );
      values.push(
        userId, finalLat, finalLng, recordedAtIso,
        batteryV, spoofed,
        accuracyM, speedMs, headingD,
        isFiltered,
        latitude !== finalLat || longitude !== finalLng ? latitude : null, // original_lat (discarded)
        computedSpeed,
        speedSource,
      );
      validCount++;
    }

    if (!placeholders.length) {
      await createUploadAudit({ userId, pointsCount, validPointsCount: 0,
        status: 'rejected', errorMessage: 'All points hard-rejected (GPS teleport)', ipAddress, requestBody: req.body });
      return res.status(201).json({ message: 'No valid points in batch', accepted: 0, rejected: pointsCount });
    }

    // Re-shape: drop original_lat (slot 10) and keep the 12 real columns.
    const cleanValues       = [];
    const cleanPlaceholders = [];
    let ci = 0;
    for (let i = 0; i < validCount; i++) {
      const base = i * 13;
      cleanPlaceholders.push(
        `($${ci+1},$${ci+2},$${ci+3},$${ci+4},NOW(),$${ci+5},$${ci+6},$${ci+7},$${ci+8},$${ci+9},$${ci+10},$${ci+11},$${ci+12})`
      );
      // userId, lat, lng, recorded_at, battery, spoofed, accuracy, speed, heading, is_filtered, computed_speed, speed_source
      cleanValues.push(
        values[base],    // user_id
        values[base+1],  // lat (filtered)
        values[base+2],  // lng (filtered)
        values[base+3],  // recorded_at
        values[base+4],  // battery_level
        values[base+5],  // is_spoofed
        values[base+6],  // accuracy
        values[base+7],  // speed  (raw GPS; 0 when GPS chip unreliable)
        values[base+8],  // heading
        values[base+9],  // is_filtered
        values[base+11], // computed_speed (skip base+10 = original_lat)
        values[base+12], // speed_source
      );
      ci += 12;
    }

    await query(
      `INSERT INTO locations
         (user_id, latitude, longitude, recorded_at, received_at, battery_level, is_spoofed,
          accuracy, speed, heading, is_filtered, computed_speed, speed_source)
       VALUES ${cleanPlaceholders.join(', ')}`,
      cleanValues,
    );

    // ── Attendance (non-spoofed, validated points only) ───────────────────────
    // validTs is populated inside the validation loop above — only timestamps
    // that passed hard-reject and spoofing checks reach this array.
    const realTs = validTs;

    if (realTs.length) {
      try {
        await query(
          `INSERT INTO attendance (user_id, date, check_in, check_out, updated_at)
           VALUES ($1, CURRENT_DATE, $2, $3, NOW())
           ON CONFLICT (user_id, date) DO UPDATE
             SET check_out = EXCLUDED.check_out, updated_at = NOW()`,
          [userId, realTs[0], realTs[realTs.length - 1]],
        );
      } catch (err) { logger.error({ err }, 'Attendance upsert failed'); }
    }

    // ── Geofence checks (non-spoofed only) ───────────────────────────────────
    const realPoints = points.filter(
      p => !p.is_spoofed &&
           typeof p.latitude === 'number' &&
           typeof p.longitude === 'number',
    );

    if (realPoints.length > 0) {
      try {
        const io = req.app.get('io');
        const allGeofences = await getAllGeofences();

        if (allGeofences.length > 0) {
          // Load all geofence state for this user in one query (ARCH-2)
          const stateRes = await query(
            `SELECT geofence_id, inside, exit_pending_since, exit_pending_lat, exit_pending_lng
             FROM user_geofence_state WHERE user_id = $1`,
            [userId],
          );
          const stateMap = new Map(stateRes.rows.map(r => [r.geofence_id, r]));

          // Deduplicate PostGIS calls by coordinate (BUG-3)
          const coordKey = p => `${p.latitude.toFixed(5)},${p.longitude.toFixed(5)}`;
          const insideCache = new Map();

          // Accumulate state mutations and events; flush in one transaction at end
          const stateUpserts = [];  // { geofence_id, inside, exit_pending_since, exit_pending_lat, exit_pending_lng }
          const eventInserts = [];  // { geofence_id, event_type }
          const socketEmits  = [];  // { geofence_id, event }

          for (const point of realPoints) {
            const { latitude, longitude } = point;
            const key = coordKey(point);

            if (!insideCache.has(key)) {
              const inside = postgisAvailable
                ? await getGeofencesContaining(latitude, longitude)
                : allGeofences.filter(gf =>
                    haversine(latitude, longitude, gf.latitude, gf.longitude) * 1000 <= gf.radius_meters,
                  );
              insideCache.set(key, new Set(inside.map(g => g.id)));
            }
            const insideIds = insideCache.get(key);

            for (const gf of allGeofences) {
              const isInside    = insideIds.has(gf.id);
              const row         = stateMap.get(gf.id);
              const prevInside  = row?.inside ?? false;
              const pendingSince = row?.exit_pending_since ?? null;

              if (isInside && !prevInside && !pendingSince) {
                stateMap.set(gf.id, { geofence_id: gf.id, inside: true, exit_pending_since: null, exit_pending_lat: null, exit_pending_lng: null });
                stateUpserts.push({ geofence_id: gf.id, inside: true, exit_pending_since: null, exit_pending_lat: null, exit_pending_lng: null });
                eventInserts.push({ geofence_id: gf.id, event_type: 'enter' });
                socketEmits.push({ geofence_id: gf.id, event: 'enter' });

              } else if (!isInside && prevInside && !pendingSince) {
                const now = new Date().toISOString();
                stateMap.set(gf.id, { geofence_id: gf.id, inside: true, exit_pending_since: now, exit_pending_lat: latitude, exit_pending_lng: longitude });
                stateUpserts.push({ geofence_id: gf.id, inside: true, exit_pending_since: now, exit_pending_lat: latitude, exit_pending_lng: longitude });

              } else if (!isInside && prevInside && pendingSince) {
                const elapsedMs  = Date.now() - new Date(pendingSince).getTime();
                const distCenter = haversine(latitude, longitude, gf.latitude, gf.longitude) * 1000;
                const extra      = distCenter - gf.radius_meters;
                if (elapsedMs >= EXIT_DEBOUNCE_MS || extra >= EXIT_DEBOUNCE_EXTRA_M) {
                  stateMap.set(gf.id, { geofence_id: gf.id, inside: false, exit_pending_since: null, exit_pending_lat: null, exit_pending_lng: null });
                  stateUpserts.push({ geofence_id: gf.id, inside: false, exit_pending_since: null, exit_pending_lat: null, exit_pending_lng: null });
                  eventInserts.push({ geofence_id: gf.id, event_type: 'exit' });
                  socketEmits.push({ geofence_id: gf.id, event: 'exit' });
                }

              } else if (isInside && prevInside && pendingSince) {
                stateMap.set(gf.id, { ...row, exit_pending_since: null, exit_pending_lat: null, exit_pending_lng: null });
                stateUpserts.push({ geofence_id: gf.id, inside: true, exit_pending_since: null, exit_pending_lat: null, exit_pending_lng: null });

              } else if (!isInside && !prevInside && !pendingSince && !row) {
                stateMap.set(gf.id, { geofence_id: gf.id, inside: false, exit_pending_since: null, exit_pending_lat: null, exit_pending_lng: null });
                stateUpserts.push({ geofence_id: gf.id, inside: false, exit_pending_since: null, exit_pending_lat: null, exit_pending_lng: null });
              }
            }
          }

          // Flush all state changes and events in a single transaction
          if (stateUpserts.length > 0 || eventInserts.length > 0) {
            const client = await (await import('../db/index.js')).default.connect();
            try {
              await client.query('BEGIN');
              for (const u of stateUpserts) {
                await client.query(
                  `INSERT INTO user_geofence_state (user_id, geofence_id, inside, exit_pending_since, exit_pending_lat, exit_pending_lng)
                   VALUES ($1,$2,$3,$4,$5,$6)
                   ON CONFLICT (user_id, geofence_id) DO UPDATE
                     SET inside=$3, exit_pending_since=$4, exit_pending_lat=$5, exit_pending_lng=$6`,
                  [userId, u.geofence_id, u.inside, u.exit_pending_since, u.exit_pending_lat, u.exit_pending_lng],
                );
              }
              for (const e of eventInserts) {
                await client.query(
                  'INSERT INTO geofence_events (user_id, geofence_id, event_type) VALUES ($1,$2,$3)',
                  [userId, e.geofence_id, e.event_type],
                );
              }
              await client.query('COMMIT');
            } catch (txErr) {
              await client.query('ROLLBACK');
              throw txErr;
            } finally {
              client.release();
            }

            for (const s of socketEmits) {
              if (io) io.emit('geofence:alert', { user_id: userId, geofence_id: s.geofence_id, event: s.event });
            }
          }
        }
      } catch (geofenceErr) {
        logger.error({ err: geofenceErr }, 'Geofence check failed');
      }
    }

    // ── Async stop detection (fire-and-forget so it doesn't delay response) ────
    setImmediate(async () => {
      try {
        const today = new Date().toISOString().split('T')[0];
        const ptsRes = await query(
          `SELECT latitude, longitude, recorded_at, speed
           FROM locations
           WHERE user_id = $1 AND DATE(recorded_at) = $2 AND is_spoofed = FALSE
           ORDER BY recorded_at ASC`,
          [userId, today],
        );
        const stops = detectStops(ptsRes.rows);
        if (stops.length > 0) {
          const dayStart = new Date(today + 'T00:00:00.000Z').toISOString();
          const dayEnd   = new Date(new Date(today + 'T00:00:00.000Z').getTime() + 86_400_000).toISOString();
          // Replace today's stops atomically
          await query(
            'DELETE FROM stops WHERE user_id=$1 AND start_time>=$2 AND start_time<$3',
            [userId, dayStart, dayEnd],
          );
          for (const s of stops) {
            await query(
              'INSERT INTO stops (user_id,start_time,end_time,lat,lng,duration_seconds) VALUES ($1,$2,$3,$4,$5,$6)',
              [userId, s.start_time, s.end_time, s.lat, s.lng, s.duration_seconds],
            );
          }
        }
      } catch (stopErr) {
        logger.error({ err: stopErr }, 'Background stop detection failed');
      }
    });

    await createUploadAudit({
      userId, pointsCount, validPointsCount: validCount, status: 'accepted', ipAddress, requestBody: req.body,
    });

    // ── Emit latest real location ─────────────────────────────────────────────
    try {
      const io = req.app.get('io');
      if (io) {
        const latest = await query(
          `SELECT u.id AS user_id, u.name, u.email, l.latitude, l.longitude,
                  l.recorded_at, l.received_at, l.is_spoofed, l.battery_level,
                  l.accuracy, l.speed, l.computed_speed, l.speed_source, l.heading,
                  (l.recorded_at >= NOW() - INTERVAL '10 minutes') AS is_live
           FROM users u
           JOIN locations l ON l.user_id = u.id
           WHERE u.id=$1 AND l.is_spoofed=FALSE
           ORDER BY l.recorded_at DESC LIMIT 1`,
          [userId],
        );
        if (latest.rows[0]) io.emit('location:uploaded', latest.rows[0]);
      }
    } catch (emitErr) {
      logger.error({ err: emitErr }, 'Socket emit failed');
    }

    return res.status(201).json({ message: 'Location points accepted', accepted: validCount, rejected: pointsCount - validCount });
  } catch (err) {
    logger.error({ err, userId }, 'Upload locations error');
    await createUploadAudit({
      userId, pointsCount, validPointsCount: 0,
      status: 'error', errorMessage: err.message, ipAddress, requestBody: req.body,
    });
    return res.status(500).json({ error: 'Unable to store location points' });
  }
});

// ── GET /api/locations/latest ─────────────────────────────────────────────────

router.get('/latest', authorize, requireAdmin, async (req, res) => {
  const includeStale = req.query.include_stale === 'true';
  try {
    const timeFilter = includeStale ? '' : "AND l.recorded_at >= NOW() - INTERVAL '10 minutes'";
    const result = await query(
      `SELECT * FROM (
         SELECT DISTINCT ON (u.id)
                u.id AS user_id, u.name, u.email,
                l.latitude, l.longitude, l.recorded_at, l.received_at, l.is_spoofed,
                (l.recorded_at >= NOW() - INTERVAL '10 minutes') AS is_live,
                l.battery_level, l.accuracy, l.speed, l.computed_speed, l.speed_source, l.heading
         FROM users u
         INNER JOIN locations l ON l.user_id = u.id
         WHERE u.role != $1 AND l.is_spoofed = FALSE
           ${timeFilter}
         ORDER BY u.id, l.recorded_at DESC, l.id DESC
       ) sub ORDER BY name`,
      ['admin'],
    );
    return res.json({ locations: result.rows });
  } catch (err) {
    logger.error({ err }, 'Fetch latest locations error');
    return res.status(500).json({ error: 'Unable to fetch latest locations' });
  }
});

// ── GET /api/locations/history/:userId ───────────────────────────────────────
// ?snap=true  — OSRM road-snapped coordinates added as latitude_snapped/longitude_snapped

router.get('/history/:userId', authorize, requireAdmin, async (req, res) => {
  const userId = parseInt(req.params.userId, 10);
  if (isNaN(userId)) return res.status(400).json({ error: 'Invalid user ID' });

  const date     = req.query.date || new Date().toISOString().split('T')[0];
  const doSnap   = req.query.snap === 'true';
  const dayStart = new Date(date + 'T00:00:00.000Z');
  const dayEnd   = new Date(dayStart.getTime() + 86_400_000);

  try {
    const result = await query(
      `SELECT id, user_id, latitude, longitude, recorded_at, received_at,
              accuracy, speed, computed_speed, speed_source, heading, is_filtered
       FROM locations
       WHERE user_id=$1 AND recorded_at>=$2 AND recorded_at<$3 AND is_spoofed=FALSE
       ORDER BY recorded_at ASC`,
      [userId, dayStart.toISOString(), dayEnd.toISOString()],
    );

    let history = result.rows;

    let snapWarning;
    if (doSnap && history.length >= 2) {
      try {
        const raw = history.map(r => ({ lat: parseFloat(r.latitude), lng: parseFloat(r.longitude) }));
        const snapped = await snapToRoads(raw);
        if (snapped.length !== raw.length) {
          console.warn(`OSRM returned ${snapped.length} points for ${raw.length} input — skipping snap`);
          snapWarning = 'Road snap point count mismatch; returning raw coordinates';
        } else {
          history = history.map((row, i) => ({
            ...row,
            latitude_snapped:  snapped[i].lat,
            longitude_snapped: snapped[i].lng,
          }));
        }
      } catch (e) {
        logger.warn({ err: e }, 'Route snap failed, returning raw');
        snapWarning = 'Road snap failed; returning raw coordinates';
      }
    }

    return res.json({ history, ...(snapWarning ? { snap_warning: snapWarning } : {}) });
  } catch (err) {
    logger.error({ err }, 'Fetch location history error');
    return res.status(500).json({ error: 'Unable to fetch location history' });
  }
});

// ── POST /api/locations/snap-route ───────────────────────────────────────────
// Accept user_id + date, return road-snapped version of that day's route.

router.post('/snap-route', authorize, requireAdmin, async (req, res) => {
  const { user_id, date } = req.body;
  if (!user_id || !date) return res.status(400).json({ error: 'user_id and date required' });

  const userId   = parseInt(user_id, 10);
  const dayStart = new Date(date + 'T00:00:00.000Z');
  const dayEnd   = new Date(dayStart.getTime() + 86_400_000);

  try {
    const result = await query(
      `SELECT latitude, longitude, recorded_at, speed, heading
       FROM locations
       WHERE user_id=$1 AND recorded_at>=$2 AND recorded_at<$3 AND is_spoofed=FALSE
       ORDER BY recorded_at ASC`,
      [userId, dayStart.toISOString(), dayEnd.toISOString()],
    );

    if (result.rows.length < 2) {
      return res.json({ snapped: [], raw_count: result.rows.length });
    }

    const raw    = result.rows.map(r => ({ lat: parseFloat(r.latitude), lng: parseFloat(r.longitude) }));
    const snapped = await snapToRoads(raw);

    const response = result.rows.map((row, i) => ({
      ...row,
      latitude_snapped:  snapped[i]?.lat ?? parseFloat(row.latitude),
      longitude_snapped: snapped[i]?.lng ?? parseFloat(row.longitude),
    }));

    return res.json({ snapped: response, raw_count: result.rows.length });
  } catch (err) {
    console.error('Snap route error', err);
    return res.status(500).json({ error: 'Road snapping failed' });
  }
});

// ── GET /api/routes/summary ───────────────────────────────────────────────────
// PostGIS ST_MakeLine + ST_Length for server-side distance; stops, speed stats.

router.get('/summary', authorize, requireAdmin, async (req, res) => {
  const userId = parseInt(req.query.user_id, 10);
  const date   = req.query.date || new Date().toISOString().split('T')[0];
  if (isNaN(userId)) return res.status(400).json({ error: 'user_id required' });

  const dayStart = new Date(date + 'T00:00:00.000Z');
  const dayEnd   = new Date(dayStart.getTime() + 86_400_000);

  try {
    // Main stats query — use PostGIS if available for accurate geodetic distance.
    let distKm, pointCount, avgSpeedKmh, maxSpeedKmh, durationMinutes;

    if (postgisAvailable) {
      const geoRes = await query(
        `SELECT
           ST_Length(ST_MakeLine(geom ORDER BY recorded_at)::geography) / 1000 AS dist_km,
           COUNT(*) AS point_count,
           AVG(speed) * 3.6 AS avg_speed_kmh,
           MAX(speed) * 3.6 AS max_speed_kmh,
           EXTRACT(EPOCH FROM (MAX(recorded_at) - MIN(recorded_at))) / 60 AS duration_min
         FROM (
           SELECT recorded_at, speed,
                  ST_SetSRID(ST_MakePoint(longitude, latitude), 4326) AS geom
           FROM locations
           WHERE user_id=$1 AND recorded_at>=$2 AND recorded_at<$3 AND is_spoofed=FALSE
         ) pts`,
        [userId, dayStart.toISOString(), dayEnd.toISOString()],
      );
      const r = geoRes.rows[0];
      distKm         = parseFloat(r.dist_km)        || 0;
      pointCount     = parseInt(r.point_count, 10)   || 0;
      avgSpeedKmh    = parseFloat(r.avg_speed_kmh)   || 0;
      maxSpeedKmh    = parseFloat(r.max_speed_kmh)   || 0;
      durationMinutes = parseFloat(r.duration_min)   || 0;
    } else {
      // Haversine fallback
      const ptsRes = await query(
        `SELECT latitude, longitude, recorded_at, speed
         FROM locations
         WHERE user_id=$1 AND recorded_at>=$2 AND recorded_at<$3 AND is_spoofed=FALSE
         ORDER BY recorded_at ASC`,
        [userId, dayStart.toISOString(), dayEnd.toISOString()],
      );
      const rows = ptsRes.rows;
      pointCount = rows.length;
      let totalKm = 0;
      for (let i = 1; i < rows.length; i++) {
        totalKm += haversine(
          parseFloat(rows[i-1].latitude), parseFloat(rows[i-1].longitude),
          parseFloat(rows[i].latitude),   parseFloat(rows[i].longitude),
        );
      }
      distKm = totalKm;
      const speeds = rows.map(r => parseFloat(r.speed) || 0);
      avgSpeedKmh  = speeds.length ? (speeds.reduce((a,b)=>a+b,0) / speeds.length) * 3.6 : 0;
      maxSpeedKmh  = speeds.length ? Math.max(...speeds) * 3.6 : 0;
      if (rows.length >= 2) {
        durationMinutes = (new Date(rows[rows.length-1].recorded_at) - new Date(rows[0].recorded_at)) / 60_000;
      } else {
        durationMinutes = 0;
      }
    }

    // Stop count for the day
    const stopRes = await query(
      `SELECT COUNT(*) AS cnt FROM stops
       WHERE user_id=$1 AND start_time>=$2 AND start_time<$3`,
      [userId, dayStart.toISOString(), dayEnd.toISOString()],
    );
    const stopCount = parseInt(stopRes.rows[0].cnt, 10) || 0;

    return res.json({
      user_id:          userId,
      date,
      total_distance_km: Math.round(distKm * 100) / 100,
      duration_minutes:  Math.round(durationMinutes),
      avg_speed_kmh:     Math.round(avgSpeedKmh * 10) / 10,
      max_speed_kmh:     Math.round(maxSpeedKmh * 10) / 10,
      stop_count:        stopCount,
      point_count:       pointCount,
    });
  } catch (err) {
    console.error('Route summary error', err);
    return res.status(500).json({ error: 'Unable to compute route summary' });
  }
});

// ── GET /api/locations/history/:userId/export ─────────────────────────────────

function csvEscape(value) {
  if (value === null || value === undefined) return '';
  const str = String(value);
  return /[",\n]/.test(str) ? '"' + str.replace(/"/g, '""') + '"' : str;
}

router.get('/history/:userId/export', authorizeForExport, requireAdmin, async (req, res) => {
  const userId = parseInt(req.params.userId, 10);
  if (isNaN(userId)) return res.status(400).json({ error: 'Invalid user ID' });

  const date     = req.query.date || new Date().toISOString().split('T')[0];
  const dayStart = new Date(date + 'T00:00:00.000Z');
  const dayEnd   = new Date(dayStart.getTime() + 86_400_000);

  try {
    const result = await query(
      `SELECT recorded_at, latitude, longitude, accuracy, speed, heading
       FROM locations
       WHERE user_id=$1 AND recorded_at>=$2 AND recorded_at<$3 AND is_spoofed=FALSE
       ORDER BY recorded_at ASC`,
      [userId, dayStart.toISOString(), dayEnd.toISOString()],
    );

    const lines = ['Timestamp,Latitude,Longitude,Accuracy (m),Speed (m/s),Heading (deg)'];
    for (const row of result.rows) {
      lines.push([
        csvEscape(row.recorded_at), csvEscape(row.latitude), csvEscape(row.longitude),
        csvEscape(row.accuracy), csvEscape(row.speed), csvEscape(row.heading),
      ].join(','));
    }

    res.setHeader('Content-Type', 'text/csv');
    res.setHeader('Content-Disposition', `attachment; filename="location-history-${userId}-${date}.csv"`);
    return res.send(lines.join('\n'));
  } catch (err) {
    console.error('Export history error', err);
    return res.status(500).json({ error: 'Unable to export history' });
  }
});

// ── GET /api/locations/stats/distance ────────────────────────────────────────

router.get('/stats/distance', authorize, requireAdmin, async (req, res) => {
  const { user_id, date } = req.query;
  if (!user_id || !date) return res.status(400).json({ error: 'user_id and date required' });

  try {
    const dayStart = new Date(date + 'T00:00:00.000Z');
    const dayEnd   = new Date(dayStart.getTime() + 86_400_000);
    const result   = await query(
      `SELECT latitude, longitude FROM locations
       WHERE user_id=$1 AND recorded_at>=$2 AND recorded_at<$3 AND is_spoofed=FALSE
       ORDER BY recorded_at ASC`,
      [user_id, dayStart.toISOString(), dayEnd.toISOString()],
    );
    const pts = result.rows;
    let distKm = 0;
    for (let i = 1; i < pts.length; i++) {
      distKm += haversine(
        parseFloat(pts[i-1].latitude), parseFloat(pts[i-1].longitude),
        parseFloat(pts[i].latitude),   parseFloat(pts[i].longitude),
      );
    }
    return res.json({ user_id: parseInt(user_id,10), date, distance_km: Math.round(distKm*100)/100 });
  } catch (err) {
    console.error('Distance stats error', err);
    return res.status(500).json({ error: 'Unable to compute distance' });
  }
});

// ── GET /api/locations/upload-audit ──────────────────────────────────────────

router.get('/upload-audit', authorize, requireAdmin, async (req, res) => {
  try {
    const result = await query(
      `SELECT la.id, la.user_id, u.name AS user_name, u.email,
              la.points_count, la.valid_points_count, la.status,
              la.error_message, la.ip_address, la.attempted_at
       FROM location_upload_audit la
       JOIN users u ON u.id = la.user_id
       ORDER BY la.attempted_at DESC LIMIT 100`,
    );
    return res.json({ audits: result.rows });
  } catch (err) {
    console.error('Fetch upload audit error', err);
    return res.status(500).json({ error: 'Unable to fetch upload audit records' });
  }
});

export default router;
