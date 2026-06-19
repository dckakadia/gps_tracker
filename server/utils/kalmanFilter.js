/**
 * GPS Kalman Filter — constant-velocity model applied independently to lat and lng.
 *
 * State vector per axis: [position, velocity]
 * Measurement: position only (H = [1, 0])
 *
 * The filter tracks how accurate each axis is (covariance P) and blends the
 * predicted position with the GPS measurement using a gain proportional to the
 * GPS accuracy. This removes random noise while preserving real movement.
 *
 * One KalmanFilter instance per tracked user — create with new KalmanFilter().
 */
export class KalmanFilter {
  /**
   * @param {number} processNoise  - Q: how much position can drift per second²
   *                                  0.0001° ≈ ~11 m; tune higher for faster movement
   * @param {number} measureNoise  - R base: measurement noise variance in degrees²
   *                                  Overridden per-point by GPS accuracy when available
   */
  constructor({ processNoise = 0.0001, measureNoise = 0.01 } = {}) {
    this.Q = processNoise;
    this.R = measureNoise;
    this.reset();
  }

  reset() {
    // Lat axis: [position, velocity]
    this._xLat  = null;       // state: position (degrees)
    this._vLat  = 0;          // state: velocity (deg/s)
    this._pLat  = [[1,0],[0,1]]; // covariance matrix

    // Lng axis (independent)
    this._xLng  = null;
    this._vLng  = 0;
    this._pLng  = [[1,0],[0,1]];

    this._lastTs = null;       // epoch ms of last update
  }

  /**
   * Feed a new GPS measurement.
   *
   * @param {number} lat          - measured latitude
   * @param {number} lng          - measured longitude
   * @param {number} timestampMs  - epoch milliseconds of this measurement
   * @param {number} accuracyM    - GPS accuracy in meters (optional)
   * @returns {{ lat: number, lng: number, filtered: boolean }}
   *   filtered=true means the output differs meaningfully from the raw input
   */
  update(lat, lng, timestampMs, accuracyM = null) {
    // First measurement: initialise state, return raw (nothing to blend yet).
    if (this._xLat === null) {
      this._xLat  = lat;
      this._xLng  = lng;
      this._lastTs = timestampMs;
      return { lat, lng, filtered: false };
    }

    const dt = Math.max((timestampMs - this._lastTs) / 1000, 0.001); // seconds
    this._lastTs = timestampMs;

    // Measurement noise from GPS accuracy — convert metres to degrees.
    // 1° latitude ≈ 111_111 m; same factor used for longitude as an approximation.
    const accuracyDeg = accuracyM != null ? accuracyM / 111_111 : null;
    const R = accuracyDeg != null ? accuracyDeg * accuracyDeg : this.R;

    const filtLat = this._filter1D('Lat', lat, dt, R);
    const filtLng = this._filter1D('Lng', lng, dt, R);

    // Consider the point "filtered" (smoothed) if the correction is > 0.5 m.
    const diffLat = Math.abs(filtLat - lat) * 111_111;
    const diffLng = Math.abs(filtLng - lng) * 111_111;
    const filtered = diffLat > 0.5 || diffLng > 0.5;

    return { lat: filtLat, lng: filtLng, filtered };
  }

  /** Internal: 1-D constant-velocity Kalman step. Returns filtered position. */
  _filter1D(axis, measurement, dt, R) {
    const x = this[`_x${axis}`];
    const v = this[`_v${axis}`];
    const P = this[`_p${axis}`];
    const Q = this.Q;

    // ── Predict ────────────────────────────────────────────────────────────────
    // State transition: F = [[1, dt], [0, 1]]
    const xPred = x + v * dt;
    const vPred = v;                             // constant velocity model

    // P_pred = F P Fᵀ + Q_matrix
    // Q_matrix uses standard CV discretisation
    const q00 = Q * dt * dt * dt / 3;
    const q01 = Q * dt * dt / 2;
    const q11 = Q * dt;

    const p00 = P[0][0] + dt * (P[1][0] + P[0][1]) + dt * dt * P[1][1] + q00;
    const p01 = P[0][1] + dt * P[1][1] + q01;
    const p10 = P[1][0] + dt * P[1][1] + q01;
    const p11 = P[1][1] + q11;

    // ── Update ─────────────────────────────────────────────────────────────────
    // H = [1, 0]  → only measuring position
    // S = H P Hᵀ + R = p00 + R
    const S = p00 + R;
    const K0 = p00 / S;   // Kalman gain for position
    const K1 = p10 / S;   // Kalman gain for velocity

    const innovation = measurement - xPred;
    const xNew = xPred + K0 * innovation;
    const vNew = vPred + K1 * innovation;

    // P_new = (I - K H) P_pred
    const pNew00 = (1 - K0) * p00;
    const pNew01 = (1 - K0) * p01;
    const pNew10 = -K1 * p00 + p10;
    const pNew11 = -K1 * p01 + p11;

    this[`_x${axis}`] = xNew;
    this[`_v${axis}`] = vNew;
    this[`_p${axis}`] = [[pNew00, pNew01], [pNew10, pNew11]];

    return xNew;
  }
}

/**
 * Registry of per-user KalmanFilter instances.
 * Stored in module scope so the same filter persists across requests for one
 * user, giving the Kalman state time to converge. Resets on server restart,
 * which is acceptable — convergence takes only a few points.
 */
const _filters = new Map();

/** @returns {KalmanFilter} */
export function getFilterForUser(userId) {
  if (!_filters.has(userId)) {
    _filters.set(userId, new KalmanFilter());
  }
  return _filters.get(userId);
}

/** Clear a user's filter state (e.g. after a long gap in tracking). */
export function resetFilterForUser(userId) {
  _filters.delete(userId);
}
