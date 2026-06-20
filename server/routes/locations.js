import express from 'express';
import rateLimit from 'express-rate-limit';
import { query } from '../db/index.js';
import { authorize, requireAdmin } from '../middleware/auth.js';
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
    console.log('locations.js: PostGIS available — using ST_DWithin for geofence checks');
  } catch {
    console.log('locations.js: PostGIS not available — using in-process Haversine fallback');
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

    const values       = [];
    const placeholders = [];
    let validCount     = 0;
    const validTs      = [];

    for (const [index, point] of points.entries()) {
      const { latitude, longitude, recorded_at, battery_level, is_spoofed,
              accuracy, speed, heading } = point;

      if (typeof latitude !== 'number' || typeof longitude !== 'number' || !recorded_at) {
        console.warn('Skipping invalid point', { index, point });
        continue;
      }

      let recordedAtIso;
      try { recordedAtIso = new Date(recorded_at).toISOString(); }
      catch { console.warn('Invalid timestamp', { index, recorded_at }); continue; }

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
          console.info('GPS point hard-rejected', { userId, index, reason: vResult.reason });
          continue;
        }

        if (!vResult.valid && vResult.severity === 'soft') {
          // Low accuracy — save raw point flagged as filtered, skip Kalman
          console.info('GPS point soft-rejected (saved as filtered)', { userId, index, reason: vResult.reason });
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

      validTs.push(recordedAtIso);
      const idx = validCount * 11;
      placeholders.push(
        `($${idx+1},$${idx+2},$${idx+3},$${idx+4},NOW(),$${idx+5},$${idx+6},$${idx+7},$${idx+8},$${idx+9},$${idx+10},$${idx+11})`
      );
      values.push(
        userId, finalLat, finalLng, recordedAtIso,
        batteryV, spoofed,
        accuracyM, speedMs, headingD,
        isFiltered,
        latitude !== finalLat || longitude !== finalLng ? latitude : null, // original_lat if filtered
      );
      validCount++;
    }

    if (!placeholders.length) {
      await createUploadAudit({ userId, pointsCount, validPointsCount: 0,
        status: 'rejected', errorMessage: 'All points hard-rejected (GPS teleport)', ipAddress, requestBody: req.body });
      return res.status(201).json({ message: 'No valid points in batch', accepted: 0, rejected: pointsCount });
    }

    // Note: last two placeholders are is_filtered and a scratch column — we omit original coords
    // for brevity (the filtered coords are what we store as canonical position).
    // Re-shape: remove the "original_lat" placeholder item and use 10-column insert.
    const cleanValues       = [];
    const cleanPlaceholders = [];
    let ci = 0;
    for (let i = 0; i < validCount; i++) {
      const base = i * 11;
      cleanPlaceholders.push(
        `($${ci+1},$${ci+2},$${ci+3},$${ci+4},NOW(),$${ci+5},$${ci+6},$${ci+7},$${ci+8},$${ci+9},$${ci+10})`
      );
      // userId, lat, lng, recorded_at, battery, spoofed, accuracy, speed, heading, is_filtered
      cleanValues.push(
        values[base],   // user_id
        values[base+1], // lat (filtered)
        values[base+2], // lng (filtered)
        values[base+3], // recorded_at
        values[base+4], // battery_level
        values[base+5], // is_spoofed
        values[base+6], // accuracy
        values[base+7], // speed
        values[base+8], // heading
        values[base+9], // is_filtered
      );
      ci += 10;
    }

    await query(
      `INSERT INTO locations
         (user_id, latitude, longitude, recorded_at, received_at, battery_level, is_spoofed,
          accuracy, speed, heading, is_filtered)
       VALUES ${cleanPlaceholders.join(', ')}`,
      cleanValues,
    );

    // ── Attendance (non-spoofed only) ─────────────────────────────────────────
    const realTs = points
      .filter(p => !p.is_spoofed && p.recorded_at)
      .map(p => { try { return new Date(p.recorded_at).toISOString(); } catch { return null; } })
      .filter(Boolean);

    if (realTs.length) {
      try {
        await query(
          `INSERT INTO attendance (user_id, date, check_in, check_out, updated_at)
           VALUES ($1, CURRENT_DATE, $2, $3, NOW())
           ON CONFLICT (user_id, date) DO UPDATE
             SET check_out = EXCLUDED.check_out, updated_at = NOW()`,
          [userId, realTs[0], realTs[realTs.length - 1]],
        );
      } catch (err) { console.error('Attendance upsert failed', err); }
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
          for (const point of realPoints) {
            const { latitude, longitude } = point;
            const insideGeofences = postgisAvailable
              ? await getGeofencesContaining(latitude, longitude)
              : allGeofences.filter(gf =>
                  haversine(latitude, longitude, gf.latitude, gf.longitude) * 1000 <= gf.radius_meters,
                );

            const insideIds = new Set(insideGeofences.map(g => g.id));

            for (const gf of allGeofences) {
              const isInside = insideIds.has(gf.id);
              const stateRes = await query(
                `SELECT inside, exit_pending_since, exit_pending_lat, exit_pending_lng
                 FROM user_geofence_state WHERE user_id = $1 AND geofence_id = $2`,
                [userId, gf.id],
              );
              const row         = stateRes.rows[0];
              const prevInside  = row?.inside ?? false;
              const pendingSince = row?.exit_pending_since ?? null;

              if (isInside && !prevInside && !pendingSince) {
                await query(
                  `INSERT INTO user_geofence_state (user_id, geofence_id, inside, exit_pending_since, exit_pending_lat, exit_pending_lng)
                   VALUES ($1,$2,TRUE,NULL,NULL,NULL)
                   ON CONFLICT (user_id, geofence_id) DO UPDATE
                     SET inside=TRUE, exit_pending_since=NULL, exit_pending_lat=NULL, exit_pending_lng=NULL`,
                  [userId, gf.id],
                );
                await query('INSERT INTO geofence_events (user_id, geofence_id, event_type) VALUES ($1,$2,$3)',
                  [userId, gf.id, 'enter']);
                if (io) io.emit('geofence:alert', { user_id: userId, geofence_id: gf.id, event: 'enter' });

              } else if (!isInside && prevInside && !pendingSince) {
                await query(
                  `INSERT INTO user_geofence_state (user_id, geofence_id, inside, exit_pending_since, exit_pending_lat, exit_pending_lng)
                   VALUES ($1,$2,TRUE,NOW(),$3,$4)
                   ON CONFLICT (user_id, geofence_id) DO UPDATE
                     SET exit_pending_since=NOW(), exit_pending_lat=$3, exit_pending_lng=$4`,
                  [userId, gf.id, latitude, longitude],
                );

              } else if (!isInside && prevInside && pendingSince) {
                const elapsedMs   = Date.now() - new Date(pendingSince).getTime();
                const distCenter  = haversine(latitude, longitude, gf.latitude, gf.longitude) * 1000;
                const extra       = distCenter - gf.radius_meters;
                if (elapsedMs >= EXIT_DEBOUNCE_MS || extra >= EXIT_DEBOUNCE_EXTRA_M) {
                  await query(
                    `INSERT INTO user_geofence_state (user_id, geofence_id, inside, exit_pending_since, exit_pending_lat, exit_pending_lng)
                     VALUES ($1,$2,FALSE,NULL,NULL,NULL)
                     ON CONFLICT (user_id, geofence_id) DO UPDATE
                       SET inside=FALSE, exit_pending_since=NULL, exit_pending_lat=NULL, exit_pending_lng=NULL`,
                    [userId, gf.id],
                  );
                  await query('INSERT INTO geofence_events (user_id, geofence_id, event_type) VALUES ($1,$2,$3)',
                    [userId, gf.id, 'exit']);
                  if (io) io.emit('geofence:alert', { user_id: userId, geofence_id: gf.id, event: 'exit' });
                }

              } else if (isInside && prevInside && pendingSince) {
                await query(
                  `UPDATE user_geofence_state
                   SET exit_pending_since=NULL, exit_pending_lat=NULL, exit_pending_lng=NULL
                   WHERE user_id=$1 AND geofence_id=$2`,
                  [userId, gf.id],
                );

              } else if (!isInside && !prevInside && !pendingSince) {
                await query(
                  `INSERT INTO user_geofence_state (user_id, geofence_id, inside)
                   VALUES ($1,$2,FALSE) ON CONFLICT DO NOTHING`,
                  [userId, gf.id],
                );
              }
            }
          }
        }
      } catch (geofenceErr) {
        console.error('Geofence check failed', geofenceErr);
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
        console.error('Background stop detection failed', stopErr);
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
                  l.accuracy, l.speed, l.heading,
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
      console.error('Socket emit failed', emitErr);
    }

    return res.status(201).json({ message: 'Location points accepted', accepted: validCount, rejected: pointsCount - validCount });
  } catch (err) {
    console.error('Upload locations error', err);
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
                l.battery_level, l.accuracy, l.speed, l.heading
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
    console.error('Fetch latest locations error', err);
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
              accuracy, speed, heading, is_filtered
       FROM locations
       WHERE user_id=$1 AND recorded_at>=$2 AND recorded_at<$3 AND is_spoofed=FALSE
       ORDER BY recorded_at ASC`,
      [userId, dayStart.toISOString(), dayEnd.toISOString()],
    );

    let history = result.rows;

    if (doSnap && history.length >= 2) {
      try {
        const raw = history.map(r => ({ lat: parseFloat(r.latitude), lng: parseFloat(r.longitude) }));
        const snapped = await snapToRoads(raw);
        history = history.map((row, i) => ({
          ...row,
          latitude_snapped:  snapped[i]?.lat ?? row.latitude,
          longitude_snapped: snapped[i]?.lng ?? row.longitude,
        }));
      } catch (e) {
        console.warn('Route snap failed, returning raw:', e.message);
      }
    }

    return res.json({ history });
  } catch (err) {
    console.error('Fetch location history error', err);
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

router.get('/history/:userId/export', authorize, requireAdmin, async (req, res) => {
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
