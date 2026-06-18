# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Is

A self-hosted employee location tracking system with three components:

- **`server/`** — Node.js (ESM) + Express REST API backed by PostgreSQL. Runs on Ubuntu via PM2 behind nginx. Also serves the Flutter web build.
- **`android-app/`** — Kotlin Android tracking client. Runs a foreground service (`TrackingService`) that collects GPS via Fused Location Provider and uploads batches to the server. Uses Room for offline caching, WorkManager for retry sync, and FCM for push notifications.
- **`admin-dashboard/`** — Flutter web/mobile admin dashboard. Deployed as a static web build served by nginx on the same server as the backend.

**Production server:** `http://116.74.77.22:8095` (hardcoded in `ApiClient.kt`). SSH user: `dckakadia`.

---

## Server

### Commands (run from `server/`)

```bash
npm install           # install dependencies
npm start             # production start (node app.js)
npm run start:dev     # dev with hot-reload (nodemon)
npm run setup-db      # run DB migrations (node db/run-migrations.js)
npm run seed          # seed test data

# PM2 (production)
pm2 start ecosystem.config.js
pm2 logs gps-tracker-server
pm2 restart gps-tracker-server
```

### Required environment variables (`server/.env`)

Copy `server/.env.example`. The three required vars that crash the process if missing:
- `DATABASE_URL` — PostgreSQL connection string
- `JWT_SECRET` — signs access tokens
- `PORT` — default 4000

Optional but important:
- `REFRESH_SECRET` — signs refresh tokens (falls back to JWT_SECRET)
- `FIREBASE_SERVICE_ACCOUNT` — JSON blob for FCM push notifications; if unset, notifications are silently skipped
- `ADMIN_EMAIL` / `ADMIN_PASSWORD` / `ADMIN_NAME` — seeded on first boot by `db/init-admin-user.js`
- `ENABLE_AUTO_BACKUP=true` + `RCLONE_CONFIG` — triggers daily 2 AM Google Drive backup

### Architecture

The server uses ES modules (`"type": "module"` in package.json). All imports must use `.js` extensions.

**Startup sequence** (`app.js`): On boot, `startServer()` runs a series of `initializeXxx()` idempotent migration functions in order — these add columns, tables, and indexes if missing. Schema source of truth is `db/schema.sql` but the real migration path goes through these init files. New schema changes should be done by adding a new `db/init-*.js` file and calling it in `startServer()`.

**Route map:**
- `POST /api/auth/login` — accepts email, username, name, or user ID as `identifier`
- `POST /api/auth/refresh` — stateless refresh token exchange
- `GET /api/admin/*` — admin-only user management and attendance
- `POST /api/locations` — batch location upload (any authenticated user); triggers attendance upsert, geofence check, and Socket.IO `location:uploaded` broadcast
- `GET /api/locations/latest` — latest location per non-admin user
- `GET /api/locations/history/:userId` — day-scoped history
- `GET /api/locations/history/:userId/export` — CSV export (supports `?token=` query param for browser downloads)
- `GET /api/users/status` — online/offline status (last seen within 30 min)
- `POST /api/users/notify` — sends FCM push to a user
- `POST /api/users/fcm-token` — registers FCM token (any authenticated user, not admin-only)
- `GET /api/app/version`, `POST /api/app/upload` — APK distribution
- `GET /api/app/download/:filename` — public APK download (no auth required)
- `GET|POST /api/geofences/*` — geofence CRUD and events
- `GET|POST /api/backup/*` — manual backup trigger

**Auth middleware** (`middleware/auth.js`): `authorize` checks `Authorization: Bearer <token>` header or `?token=` query param. `requireAdmin` gates admin endpoints. Socket.IO also validates JWT on connection, admin-only.

**Geofence logic**: On every location upload, all geofences are checked via in-process haversine. State is tracked in `user_geofence_state`. Entry/exit emits `geofence:alert` via Socket.IO.

**Archive job**: Runs at 2 AM daily — moves `locations` rows older than 90 days to `locations_archive`.

**Rate limiting**: Location upload endpoint is limited to 60 requests/min per IP.

### nginx (production server)

Config file: `/etc/nginx/sites-enabled/gps-tracker-admin.conf`

Key settings already applied:
- `client_max_body_size 100m` — required for APK uploads via admin dashboard
- `proxy_read_timeout 300s` / `proxy_send_timeout 300s` — prevents 504s on large uploads
- Port 4000 is firewalled; all traffic must go through nginx on port 8095

To update nginx config remotely:
```bash
# Copy new config, test, reload
scp admin-dashboard/gps-tracker-8095.conf dckakadia@116.74.77.22:/tmp/
ssh dckakadia@116.74.77.22 "echo PASSWORD | sudo -S cp /tmp/gps-tracker-8095.conf /etc/nginx/sites-enabled/gps-tracker-admin.conf && sudo -S nginx -t && sudo -S systemctl reload nginx"
```

---

## Android App

### Build & Install

```bash
# Build release APK (from android-app/)
./gradlew assembleRelease

# Install on connected USB device — use adb directly, NOT Android Studio Run button
# Android Studio's installer hangs on Samsung Android 12+ (ADB streaming bug)
adb install -r app/build/outputs/apk/release/app-release.apk

# Build + install in one step
./gradlew assembleRelease && adb install -r app/build/outputs/apk/release/app-release.apk
```

Release APKs are signed with the debug keystore at `/Users/devinkakadia/.android/debug.keystore`.

### OTA Update Workflow (no USB needed for updates)

Every device checks `/api/app/version` on launch and auto-prompts users to update if `versionCode` on server > installed version.

**To release a new version:**
1. Bump `versionCode` and `versionName` in [android-app/app/build.gradle](android-app/app/build.gradle)
2. Build: `./gradlew assembleRelease`
3. Upload via admin dashboard → App Management tab, **or** via curl:

```bash
TOKEN=$(curl -s -X POST http://116.74.77.22:8095/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"identifier":"ADMIN_EMAIL","password":"ADMIN_PASSWORD"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

curl -X POST http://116.74.77.22:8095/api/app/upload \
  -H "Authorization: Bearer $TOKEN" \
  -F "version=X.Y.Z" \
  -F "versionCode=NNN" \
  -F "releaseNotes=What changed" \
  -F "apk=@app/build/outputs/apk/release/app-release.apk;type=application/vnd.android.package-archive"
```

**Current published version:** `1.0.8` (versionCode 108) — button turns blue when tracking active; immediate upload on Start Tracking so user appears online instantly.

**First install on a new device (no USB):** Share the direct download link via WhatsApp/email:
```
http://116.74.77.22:8095/api/app/download/gpstracker_ver_1_0_7.apk
```
User opens in browser, enables "Install from unknown sources" once, installs. All future updates are automatic via in-app OTA.

### Architecture

**Tracking flow:**
1. `LoginActivity` authenticates with the server, stores JWT + refresh token in `AuthManager` (SharedPreferences).
2. `MainActivity` starts `TrackingService` as a foreground service and checks for OTA updates via `UpdateChecker`.
3. `TrackingService` requests location updates via `FusedLocationProviderClient` using `LocationRequest.Builder` (modern API, not deprecated `LocationRequest.create()`).
4. On successful network: `ApiClient.uploadLocations()` uploads the batch with 3-attempt exponential backoff.
5. On network failure or auth error: points are persisted to Room DB via `LocationDao`, and `SyncWorker` is enqueued via WorkManager to retry when connectivity returns.
6. `ApiClient.ensureFreshToken()` proactively refreshes the JWT 5 minutes before expiry. On 401 or refresh failure, clears credentials and shows a notification.

**Adaptive motion state machine (as of v1.0.9):**

`TrackingService` runs a two-state machine: `MOVING` and `STATIONARY`.

| | MOVING | STATIONARY |
|---|---|---|
| GPS | `PRIORITY_HIGH_ACCURACY`, 30 s (60 s low-battery) | **Off** — `removeLocationUpdates()` called |
| Min displacement | 10 m (30 m low-battery) | n/a |
| Wake mechanism | n/a | `TYPE_SIGNIFICANT_MOTION` one-shot trigger |
| Network | Batch upload every 8 min (or immediate on maneuver) | Heartbeat ping every 4 hours |

**Transition rules:**
- MOVING → STATIONARY: `speed < 0.5 m/s` continuously for 3 minutes
- STATIONARY → MOVING: `TYPE_SIGNIFICANT_MOTION` accelerometer trigger fires (hardware coprocessor, zero CPU cost), or `ACTION_FORCE_UPLOAD` intent

**Immediate upload triggers (while MOVING):**
- Heading change > 15° between consecutive fixes → `forceNextUpload = true` → batch flushes immediately
- Speed delta > 3 m/s (~10 km/h) between consecutive fixes → same

**Key constants** (all in `companion object`):
```
MOVING_INTERVAL_MS       = 30_000      // 30 s
STATIONARY_TIMEOUT_MS    = 180_000     // 3 min
STATIONARY_SPEED_MS      = 0.5f        // m/s
HEADING_THRESHOLD_DEG    = 15f         // degrees
SPEED_DELTA_THRESHOLD_MS = 3f          // m/s
HEARTBEAT_INTERVAL_MS    = 14_400_000  // 4 hours
```

A `BroadcastReceiver` listens to `Intent.ACTION_BATTERY_CHANGED` (sticky). When battery crosses the 20% threshold while in MOVING state, `restartLocationUpdates()` re-subscribes at the low-battery interval (60 s). Battery profile has no effect in STATIONARY state. All async work runs on `serviceScope = CoroutineScope(Dispatchers.IO + SupervisorJob())` — cancelled in `onDestroy()`.

**7 structural invariants — never break these:**
1. `TYPE_SIGNIFICANT_MOTION` is the only wake mechanism from STATIONARY. No polling fallbacks.
2. `enterStationaryState()` must always call `fusedLocationClient.removeLocationUpdates()`.
3. `enterMovingState()` must always call `sensorManager.cancelTriggerSensor()` before arming GPS.
4. GPS priority must stay `PRIORITY_HIGH_ACCURACY` in MOVING state — BALANCED_POWER silently breaks bearing/speed data.
5. `forceNextUpload` is `@Volatile`; the reset must happen inside `synchronized(pendingPoints)`.
6. `locationHandlerThread` must be quit with `quitSafely()` before a replacement is created.
7. `onDestroy` cleanup order is fixed: cancel scope → remove Handler callbacks → unregister batteryReceiver → cancel trigger sensor → remove location updates → quit handler thread.

**Devices without `TYPE_SIGNIFICANT_MOTION`:** stay in STATIONARY with no automatic wake. Heartbeat still fires every 4 hours. Manual `ACTION_FORCE_UPLOAD` transitions back to MOVING. Do not add polling fallbacks.

**Companion object — UI-readable state fields:**
```kotlin
TrackingService.currentState           // State.MOVING | State.STATIONARY (@Volatile)
TrackingService.nextHeartbeatAt        // epoch ms of next heartbeat; 0 = not scheduled
TrackingService.isMotionSensorAvailable // set once in onCreate
```
`State` is a public nested enum on `TrackingService` — no IPC needed since UI and service share the same process.

**Implemented fixes (all complete):**
- `forceNextUpload` writes moved inside `synchronized(pendingPoints)` — invariant 5 fully met. Detection logic in `onLocationReceived` uses a local `isManeuver` accumulator; the single write fires as `if (isManeuver) synchronized(pendingPoints) { forceNextUpload = true }`.
- `headingDiff()` changed from `private` to `internal` — accessible from JUnit tests in the same module.
- `MainActivity.updateServiceStatus()` — three states: `"Tracking OFF"` / `"Tracking: Moving"` / `"Tracking: Standby"`.
- `MainActivity.updateStartButton()` — three colours: green START / blue ACTIVE / amber `"STANDBY — GPS OFF"`.
- `MainActivity.updateOverallStatus()` — amber `"Standby — GPS off, accelerometer armed"` state added.
- `DebugActivity` — new "Tracking State" card (`tvTrackingState`, `tvMotionSensor`, `tvNextHeartbeat`) updated every 2 s with live state, sensor arm status, and `HH:MM:SS` countdown to next heartbeat.
- `activity_debug.xml` — tracking state card inserted between GPS Info and Server Status cards.

**Remaining work (Task 3 — not yet implemented):**
- Create `TrackingServiceTest.kt` in `app/src/test/` with Level 1 JUnit tests for `headingDiff()` (5 cases: straight road, wraparound turn, 180°, boundary at 15°, boundary at 16°) and stationary timeout logic. No Android context needed — pure JVM.
- Level 2 (Robolectric) and Level 3 (on-device) tests outlined in memory file `tracking-service-state-machine.md`.

**`ServiceWatchdogWorker`** (15-min periodic) is state-safe — checks process liveness, not GPS activity, so it will not falsely restart a correctly sleeping service.

**Samsung Android 12+ notes:**
- Battery optimization aggressively kills background services. Users must set GPS Tracker to **Unrestricted** in Settings → Battery → Background usage limits.
- The app shows a battery banner on the main screen that opens this settings page directly.
- `adb install` via Android Studio hangs on Samsung Android 12 — always use `adb install -r` from command line.

**Key files:**
- `ApiClient.kt` — all HTTP calls; `BASE_URL` is hardcoded here — update when changing server address
- `TrackingService.kt` — foreground service, location batching, upload logic, battery-adaptive profiles
- `SyncWorker.kt` — WorkManager worker for offline sync retry
- `AuthManager.kt` — token storage/retrieval in SharedPreferences
- `AppDatabase.kt` / `LocationDao.kt` / `LocationEntity.kt` — Room offline cache
- `FcmTokenManager.kt` — registers FCM token with server after login
- `UpdateChecker.kt` — polls `/api/app/version`, downloads and installs APK via `DownloadManager` + `FileProvider`
- `DebugActivity.kt` — in-app debug screen (long-press version label); shows live logs (`LiveLogManager`) and persistent logs (`LogPersistor`)

**Permissions required:** `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION`, `ACCESS_BACKGROUND_LOCATION` (Android 10+), `FOREGROUND_SERVICE_LOCATION` (Android 14+), `REQUEST_INSTALL_PACKAGES` (OTA updates).

**FCM**: Firebase push notifications are wired — server sends via `firebase-admin`, Android receives via `FcmTokenManager`. Firebase config is in `android-app/app/google-services.json`.

---

## Admin Dashboard (Flutter)

### Commands (run from `admin-dashboard/`)

```bash
flutter pub get
flutter run -d chrome                                                     # local dev
flutter run -d chrome --dart-define=API_URL=http://localhost:4000/api    # point to local server
flutter build web --release                                               # production build
./build-and-deploy.sh --deploy user@116.74.77.22                         # build + scp to server
```

### Architecture

Single-page Flutter web app. Auth state is stored in static `AuthState.token`. All API calls go through `ApiService` — `baseUrl` defaults to `/api` (relative, for same-origin nginx proxying) and can be overridden at build time via `--dart-define=API_URL=...`.

**Screen structure** (all under `lib/screens/`):
- `DashboardScreen` — tabbed container with: Map, Users, History, Attendance, Geofences, Events, Backup, App Management, Admin Control
- `MapScreen` — live map using `flutter_map`; uses Socket.IO (`socket_io_client`) to receive `location:uploaded` events for real-time updates
- `HistoryScreen` — day-scoped location replay with CSV export
- `AttendanceScreen` — check-in/check-out times from the `attendance` table
- `GeofenceScreen` — CRUD for geofences, map-based placement
- `BackupScreen` — trigger/monitor Google Drive backups
- `AppManagementScreen` — APK upload and version management (requires nginx `client_max_body_size 100m`)

Login accepts email, username, name, or user ID (matching server auth behavior).

`MyHttpOverrides` in `main.dart` disables SSL certificate validation — intentional for self-hosted HTTP deployment.

---

## Deployment

The server runs on Ubuntu with nginx as a reverse proxy. The Flutter web build is served as static files by the same nginx instance. See `docs/DEPLOYMENT_RUNBOOK.md` for full server setup and `server/deploy_ubuntu.sh` for the automated deploy script.

**APK distribution flow:** Admin uploads APK → stored in `server/uploads/apks/` → `version.json` updated → all installed apps auto-prompt on next launch → user taps Update Now → `DownloadManager` downloads → `FileProvider` installs silently.
