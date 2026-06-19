/**
 * Stop detection from a GPS trace.
 *
 * A "stop" is a sequence of consecutive points where the device was moving
 * slower than STOP_SPEED_KMH for at least MIN_STOP_DURATION_S seconds.
 * The stop's lat/lng is the geographic centroid of all points in the cluster.
 *
 * detectStops(points) → Array<Stop>
 *
 * Stop shape: { lat, lng, start_time, end_time, duration_seconds }
 */

const STOP_SPEED_KMH      = 5;       // below this → treat point as "stopped"
const MIN_STOP_DURATION_S = 2 * 60;  // must be stopped for at least 2 minutes

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
 * @param {Array} points  - sorted ascending by recorded_at (ISO string or Date-parseable)
 *   Each point: { latitude|lat, longitude|lng, recorded_at, speed? }
 *   speed in m/s when present (FusedLocationProvider default); omit or null to infer from distance.
 *
 * @returns {Array<{ lat, lng, start_time, end_time, duration_seconds }>}
 */
export function detectStops(points) {
  if (points.length < 2) return [];

  const STOP_SPEED_MS = STOP_SPEED_KMH / 3.6;

  // Normalise point shape
  const pts = points.map(p => ({
    lat:   parseFloat(p.latitude ?? p.lat),
    lng:   parseFloat(p.longitude ?? p.lng),
    ts:    new Date(p.recorded_at).getTime(),  // epoch ms
    speed: p.speed != null ? parseFloat(p.speed) : null,
  })).filter(p => !isNaN(p.lat) && !isNaN(p.lng) && !isNaN(p.ts));

  if (pts.length < 2) return [];

  // Compute per-point speed from GPS if not provided by the app.
  for (let i = 0; i < pts.length; i++) {
    if (pts[i].speed != null) continue;
    if (i === 0) { pts[i].speed = 0; continue; }
    const prev = pts[i - 1];
    const curr = pts[i];
    const dtS  = (curr.ts - prev.ts) / 1000;
    if (dtS < 0.5) { pts[i].speed = pts[i - 1].speed ?? 0; continue; }
    const distKm = haversineKm(prev.lat, prev.lng, curr.lat, curr.lng);
    pts[i].speed = (distKm * 1000) / dtS;  // m/s
  }

  const stops = [];
  let clusterStart = null;  // index where current slow cluster started
  let clusterEnd   = null;

  const finaliseCluster = (startIdx, endIdx) => {
    const clusterPts = pts.slice(startIdx, endIdx + 1);
    const durationS  = (clusterPts[clusterPts.length - 1].ts - clusterPts[0].ts) / 1000;
    if (durationS < MIN_STOP_DURATION_S) return;

    const avgLat = clusterPts.reduce((s, p) => s + p.lat, 0) / clusterPts.length;
    const avgLng = clusterPts.reduce((s, p) => s + p.lng, 0) / clusterPts.length;

    stops.push({
      lat:              avgLat,
      lng:              avgLng,
      start_time:       new Date(clusterPts[0].ts).toISOString(),
      end_time:         new Date(clusterPts[clusterPts.length - 1].ts).toISOString(),
      duration_seconds: Math.round(durationS),
    });
  };

  for (let i = 0; i < pts.length; i++) {
    const isStopped = pts[i].speed <= STOP_SPEED_MS;

    if (isStopped) {
      if (clusterStart === null) clusterStart = i;
      clusterEnd = i;
    } else {
      if (clusterStart !== null) {
        finaliseCluster(clusterStart, clusterEnd);
        clusterStart = null;
        clusterEnd   = null;
      }
    }
  }

  // Finalise any open cluster at end of trace
  if (clusterStart !== null) {
    finaliseCluster(clusterStart, clusterEnd);
  }

  return stops;
}
