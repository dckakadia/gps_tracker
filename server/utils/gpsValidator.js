/**
 * GPS point validation — rejects noise before the point enters the Kalman filter
 * or the database.
 *
 * validateGPSPoint(prev, curr) → { valid: boolean, reason: string|null }
 *
 * Rules:
 *  1. Accuracy > 50 m  → reject (indoor or multipath reflection noise)
 *  2. Implicit speed between consecutive points > 150 km/h → reject (GPS jump)
 *     Calculated from Haversine distance / elapsed time.
 */

const MAX_ACCURACY_M     = 150;   // metres — soft threshold; points above are saved but flagged
const MAX_SPEED_KMH      = 150;   // km/h — hard threshold; true GPS teleport → skip entirely
const MIN_ELAPSED_S      = 0.5;   // seconds — avoid division by very small dt

/**
 * Haversine distance in kilometres between two lat/lng pairs.
 */
function haversineKm(lat1, lon1, lat2, lon2) {
  const R = 6371;
  const dLat = (lat2 - lat1) * Math.PI / 180;
  const dLon = (lon2 - lon1) * Math.PI / 180;
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180) *
    Math.sin(dLon / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

/**
 * Validate a single GPS point.
 *
 * @param {object|null} prev  - previous accepted point { lat, lng, timestamp_ms }
 *                              Pass null for the very first point.
 * @param {object}      curr  - candidate point { lat, lng, timestamp_ms, accuracy_m? }
 *
 * @returns {{ valid: boolean, reason: string|null }}
 */
/**
 * severity: 'ok' | 'soft' | 'hard'
 *   ok   — point is good, apply Kalman
 *   soft — low accuracy; save with is_filtered=true, skip Kalman
 *   hard — GPS teleport (impossible speed); discard entirely
 */
export function validateGPSPoint(prev, curr) {
  const { lat, lng, timestamp_ms, accuracy_m } = curr;

  // ── Rule 2: implicit speed check (hard reject) ────────────────────────────
  if (prev != null) {
    const elapsedMs = timestamp_ms - prev.timestamp_ms;
    const elapsedS  = elapsedMs / 1000;

    if (elapsedS >= MIN_ELAPSED_S) {
      const distKm   = haversineKm(prev.lat, prev.lng, lat, lng);
      const speedKmh = (distKm / elapsedS) * 3600;

      if (speedKmh > MAX_SPEED_KMH) {
        return {
          valid: false,
          severity: 'hard',
          reason: `Implied speed ${speedKmh.toFixed(1)} km/h exceeds ${MAX_SPEED_KMH} km/h`,
        };
      }
    }
  }

  // ── Rule 1: accuracy check (soft reject — flag, don't drop) ───────────────
  if (accuracy_m != null && accuracy_m > MAX_ACCURACY_M) {
    return {
      valid: false,
      severity: 'soft',
      reason: `Accuracy ${accuracy_m.toFixed(0)} m exceeds ${MAX_ACCURACY_M} m threshold`,
    };
  }

  return { valid: true, severity: 'ok', reason: null };
}

/**
 * Validate an entire batch of points in chronological order.
 * Returns only the valid subset, logging rejections.
 *
 * @param {Array} points  - sorted ascending by timestamp_ms
 *                          each: { lat, lng, timestamp_ms, accuracy_m? }
 * @returns {{ valid: Array, rejected: Array<{point, reason}> }}
 */
export function validateBatch(points) {
  const valid    = [];
  const rejected = [];
  let prev = null;

  for (const pt of points) {
    const result = validateGPSPoint(prev, pt);
    if (result.valid) {
      valid.push(pt);
      prev = pt;
    } else {
      rejected.push({ point: pt, reason: result.reason });
    }
  }

  return { valid, rejected };
}
