# Changes Summary — UX Improvement Batch

This document summarizes an 8-task batch of UX and feature improvements across the
Android employee app, the Node/Express server, and the Flutter admin dashboard.

---

## Task 1 — Simplify employee app main screen (Android)

**Files touched**
- `android-app/app/src/main/java/com/example/gps_tracker/MainActivity.kt`
- `android-app/app/src/main/java/com/example/gps_tracker/DebugActivity.kt` (new)
- `android-app/app/src/main/res/layout/activity_main.xml`
- `android-app/app/src/main/res/layout/activity_debug.xml` (new)
- `android-app/app/src/main/AndroidManifest.xml` (registered `DebugActivity`)

**What changed**
- Removed `initializeMockData()` and the hardcoded NYC lat/long placeholder.
- Main screen now shows: a large `Tracking ON/OFF` status with the colored dot
  indicator, a check-in card, and a single overall-status line
  (`All good ✓` / `Tap to fix — [action]`).
- Raw lat/long, accuracy, the Successful/Total request counters, and the live log
  panel moved to a new hidden `DebugActivity`, reachable only via long-press on the
  version label (`tvAppVersion`).
- `startTrackingButton` and `logoutButton` behavior unchanged.

**Assumptions / deferred**
- No check-in endpoint exists, so the check-in card is stubbed (`Check-in: —`,
  `Elapsed: —`) with a TODO in `updateCheckIn()`.
- `DebugActivity` shows live GPS via its own `LocationManager` listener (the old main
  screen only ever displayed mock data); it shows "Waiting for GPS fix…" until a fix
  arrives.

---

## Task 2 — Battery optimization warning (Android)

**Files touched**
- `android-app/app/src/main/java/com/example/gps_tracker/MainActivity.kt`
- `android-app/app/src/main/res/layout/activity_main.xml` (battery banner)
- `android-app/app/src/main/AndroidManifest.xml`

**What changed**
- `onResume()` checks `PowerManager.isIgnoringBatteryOptimizations(packageName)` and
  shows a dismissible orange banner ("Background tracking may be paused by your phone
  to save battery. Tap to fix.") when optimization is not disabled.
- Tapping the banner launches `Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`.
- Added `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` permission to the manifest.

**Assumptions / deferred**
- Dismissal is per-activity-instance (in-memory flag), not persisted across launches.

---

## Task 3 — Split login error states + password reset path (Android + Flutter)

**Files touched**
- `android-app/app/src/main/java/com/example/gps_tracker/LoginActivity.kt`
- `android-app/app/src/main/java/com/example/gps_tracker/ApiClient.kt`
- `android-app/app/src/main/res/layout/activity_login.xml`
- `admin-dashboard/lib/screens/admin_control_screen.dart`
- `admin-dashboard/lib/screens/users_screen.dart`

**What changed**
- `ApiClient.LoginResult` now carries `statusCode` and `networkError`. `attemptLogin()`
  distinguishes: network/timeout → "Can't reach server — check your connection";
  401 → "Incorrect email or password"; otherwise the server-provided error.
- Added "Forgot password? Contact your admin." hint below the password field.
- Edit-user password label standardized to
  "New password (leave blank to keep current)" in both dashboard screens.

**Assumptions / deferred**
- `LoginResult` gained two optional fields with defaults; existing callers unaffected.

---

## Task 4 — Consolidate duplicate user management (Flutter)

**Files touched**
- `admin-dashboard/lib/screens/admin_control_screen.dart`

**What changed**
- Removed the duplicated `_UsersTab` / `_UsersTabState` classes and embedded
  `UsersScreen(token: token)` directly into the Users tab.
- Dropped the now-unused `../models/user.dart` import.

---

## Task 5 — CSV export (server + Flutter)

**Files touched**
- `server/routes/admin.js` (`GET /attendance/export`)
- `server/routes/locations.js` (`GET /history/:userId/export`)
- `server/middleware/auth.js` (accept `?token=` query param fallback)
- `admin-dashboard/lib/screens/attendance_screen.dart`
- `admin-dashboard/lib/screens/history_screen.dart`

**What changed**
- Attendance export returns CSV (Name, Check In, Check Out, Hours).
- Location history export returns CSV (Timestamp, Latitude, Longitude, Accuracy).
- Both send `Content-Type: text/csv` and an `attachment` `Content-Disposition`.
- Dashboard adds "Export CSV" `OutlinedButton.icon(Icons.download)`; on web it opens
  `window.open('<baseUrl>/...?...&token=<token>')` (guarded by `kIsWeb`).

**Assumptions / deferred**
- Browser downloads cannot set an Authorization header, so `authorize` now accepts a
  `token` query parameter as a fallback. This applies to every route using
  `authorize`; the JWT is still fully verified.
- The `locations` table does not store accuracy, so the Accuracy column is emitted but
  left empty.

---

## Task 6 — Geofence edit endpoint + UI (server + Flutter)

**Files touched**
- `server/routes/geofences.js` (`PUT /:id`)
- `admin-dashboard/lib/screens/geofence_screen.dart`
- `admin-dashboard/lib/services/api_service.dart` (`updateGeofence`)

**What changed**
- Added a PUT endpoint to update name/latitude/longitude/radius.
- Added an edit `IconButton(Icons.edit_outlined)` to each geofence list tile; opens an
  AlertDialog pre-filled with the current name and radius; saves via
  `ApiService.updateGeofence` and refreshes the list.

**Assumptions / deferred**
- The actual `geofences` schema uses `radius_meters` (not `radius`) and has **no**
  `created_by` column, so the per-row ownership check from the task brief was replaced
  by the existing admin-only middleware (`authorize, requireAdmin`).
- The edit dialog keeps the existing center coordinates (the map UI is used to set
  location); only name and radius are editable from the dialog.

---

## Task 7 — Geofence/check-in event history (server + Flutter)

**Files touched**
- `server/db/migrate-geofence-events.js` (new)
- `server/app.js` (registered migration in startup)
- `server/routes/geofences.js` (`POST /events`, `GET /events`)
- `admin-dashboard/lib/screens/map_screen.dart` (persist on geofence:alert)
- `admin-dashboard/lib/services/api_service.dart` (`postGeofenceEvent`, `getGeofenceEvents`)
- `admin-dashboard/lib/screens/events_screen.dart` (new)
- `admin-dashboard/lib/screens/dashboard_screen.dart` (Events nav item)

**What changed**
- New `geofence_events` table (with indexes) created via migration on startup.
- `POST /geofences/events` persists an enter/exit event; `GET /geofences/events`
  lists events joined with user and geofence names, filterable by `date` and `userId`.
- The map screen now calls `ApiService.postGeofenceEvent` after showing a geofence
  enter/exit SnackBar (mapping the socket's `entered`/`exited` to `enter`/`exit`).
- New `EventsScreen` (styled like `AttendanceScreen`): date filter + table of
  user name, geofence name, enter/exit badge, and time.
- Added "Events" as a nav item (`Icons.event_note_outlined` / `Icons.event_note`).

**Assumptions / deferred**
- `migrate-geofence-events.js` imports `query` from `./index.js` (the project's actual
  db module) rather than the `../db.js` path shown in the brief.
- Events routes live in `geofences.js` (mounted at `/api/geofences`), so the client
  paths are `/geofences/events`. The `/events` routes are declared before `/:id` to
  avoid any param-route shadowing.
- Events are persisted from the dashboard client when a `geofence:alert` socket event
  is received. Server-side geofence detection already emits these alerts; persistence
  was intentionally added at the alert handler per the brief.
- The Admin screen index in `dashboard_screen.dart` moved from 4 to 5; the AppBar
  Admin shortcut now uses a named `_adminIndex` constant. `main.dart`'s
  `initialIndex: 2` (Attendance) is unaffected.

---

## Task 8 — Quick-reply templates in notification dialog (Flutter)

**Files touched**
- `admin-dashboard/lib/screens/map_screen.dart`

**What changed**
- The `_sendNotification` dialog now shows a `Wrap` of `ActionChip`s
  (`Running late?`, `Please check in`, `Heading to next stop?`) above the message
  TextField. Tapping a chip fills the message field.

---

## Verification

- `flutter analyze` was run from `admin-dashboard/` after each Flutter task. No new
  errors or warnings were introduced; remaining items are pre-existing info-level
  deprecation notices (`withOpacity`, `dart:html`) and pre-existing errors in
  `test/widget_test.dart` (missing `flutter_test` dependency), all untouched by this batch.
- Server files were validated with `node --check`.

## Notes / constraints honored

- No new third-party packages were added.
- Backup/rclone and APK update/versioning code were not modified.
- Flutter colors reuse `AppTheme` constants.
