/**
 * OSRM road-snapping utility.
 *
 * Calls the OSRM Map Matching API to snap raw GPS traces to the nearest roads.
 * Works with both the free public demo server and a self-hosted OSRM instance.
 *
 * Self-hosted OSRM (recommended for production — no rate limits):
 *   docker run -t -v $(pwd):/data osrm/osrm-backend osrm-routed --algorithm mld /data/your-map.osrm
 *   Set OSRM_BASE_URL=http://your-server:5000 in .env
 *
 * Public demo: http://router.project-osrm.org  (rate-limited, ok for dev/low volume)
 */

import http  from 'http';
import https from 'https';

const OSRM_BASE = process.env.OSRM_BASE_URL || 'http://router.project-osrm.org';
const OSRM_TIMEOUT_MS = 8_000;
const CHUNK_SIZE = 100; // OSRM match API limit per request

function fetchJson(url) {
  return new Promise((resolve, reject) => {
    const lib = url.startsWith('https') ? https : http;
    const req = lib.get(url, { timeout: OSRM_TIMEOUT_MS }, (res) => {
      let body = '';
      res.on('data', (chunk) => { body += chunk; });
      res.on('end', () => {
        try { resolve(JSON.parse(body)); }
        catch (e) { reject(new Error(`OSRM JSON parse error: ${e.message}`)); }
      });
    });
    req.on('error', reject);
    req.on('timeout', () => { req.destroy(); reject(new Error('OSRM request timeout')); });
  });
}

/**
 * Snap a single chunk of ≤100 {lat, lng} points to roads.
 * Returns snapped {lat, lng} points, or the originals on failure.
 */
async function snapChunk(points) {
  if (points.length < 2) return points;

  const coords = points.map(p => `${p.lng},${p.lat}`).join(';');
  // radiuses=25 means "snap within 25 m of the road"; increase for rural areas
  const url = `${OSRM_BASE}/match/v1/driving/${coords}?overview=full&geometries=geojson&radiuses=${points.map(() => 25).join(';')}`;

  try {
    const result = await fetchJson(url);

    if (result?.code === 'Ok' && result?.matchings?.length > 0) {
      // Collect all matched geometry coordinates from all matchings.
      const snapped = [];
      for (const matching of result.matchings) {
        for (const [lng, lat] of matching.geometry.coordinates) {
          snapped.push({ lat, lng });
        }
      }
      return snapped.length > 0 ? snapped : points;
    }

    console.warn('OSRM match returned non-Ok code:', result?.code, result?.message);
    return points;
  } catch (err) {
    console.warn('OSRM snap failed for chunk, using raw points:', err.message);
    return points;
  }
}

/**
 * Snap an array of {lat, lng} objects to the nearest roads using OSRM.
 *
 * Automatically chunks the input for the OSRM 100-coordinate limit.
 * Falls back to the raw points on any error — never throws.
 *
 * @param {Array<{lat: number, lng: number}>} points
 * @returns {Promise<Array<{lat: number, lng: number}>>}
 */
export async function snapToRoads(points) {
  if (points.length < 2) return points;

  const snapped = [];
  for (let i = 0; i < points.length; i += CHUNK_SIZE) {
    const chunk = points.slice(i, i + CHUNK_SIZE);
    const result = await snapChunk(chunk);
    snapped.push(...result);
  }
  return snapped;
}
