# Employee Location Tracking System

This repository contains a self-hosted location tracking system with three components:

- `server/`: Node.js backend API with PostgreSQL/PostGIS.
- `android-app/`: Android Kotlin tracking client with offline caching and WorkManager sync.
- `admin-dashboard/`: Flutter web/mobile admin dashboard.

## Ubuntu Server Setup

1. Install Node.js and PostgreSQL with PostGIS:
   - `sudo apt update`
   - `sudo apt install -y nodejs npm postgresql postgresql-contrib postgis`

2. Create database and enable PostGIS:
   - `sudo -u postgres psql`
   - `CREATE DATABASE gps_tracker;`
   - `\c gps_tracker`
   - `CREATE EXTENSION postgis;`
   - `\q`

3. Configure environment:
   - Copy `server/.env.example` to `server/.env`
   - Fill in `DATABASE_URL`, `JWT_SECRET`, and other settings.

4. Install backend dependencies:
   - `cd server`
   - `npm install`

5. Run DB schema:
   - `psql "$DATABASE_URL" -f db/schema.sql`

6. Seed the first admin user manually:
   - `psql "$DATABASE_URL"`
   - `INSERT INTO users (name, email, password_hash, role) VALUES ('Admin','admin@example.com','<bcrypt-hash>','admin');`
   - Replace `<bcrypt-hash>` with a bcrypt hash generated in your environment. Example:
     `node -e "const bcrypt = require('bcrypt'); console.log(bcrypt.hashSync('YourPassword', 12));"`
   - Or create an initial admin record with a script.

7. Start backend:
   - `npm start`

## Run all services together
From the repo root, use one of the following:

- PowerShell:
  - `.\start-all.ps1`
- Command Prompt:
  - `.\start-all.bat`

This will open one terminal for the backend and another terminal for the Flutter admin dashboard.

## Android App Setup

1. Open `android-app` in Android Studio.
2. Ensure `minSdkVersion` is set to 26 or above.
3. Update `ApiClient.BASE_URL` in `LocationWorker.kt` and `SyncWorker.kt`.
4. Build and deploy to devices.

## Admin Dashboard Setup

1. Install Flutter SDK.
2. Open `admin-dashboard`.
3. Run `flutter pub get`.
4. Update `ApiService.baseUrl` to the backend API host.
5. Run web: `flutter run -d chrome` or Android: `flutter run`.

## Backup Configuration

The system includes automatic and manual backups to Google Drive using rclone.

### Quick Setup
1. Follow the **complete guide**: [RCLONE_SETUP.md](./RCLONE_SETUP.md)
2. Set in `server/.env`:
   ```
   ENABLE_AUTO_BACKUP=true
   RCLONE_CONFIG=/home/dckakadia/.config/rclone/rclone.conf
   ```
3. Backups run **automatically every day at 2:00 AM UTC**
4. Manual backups available in **Admin Dashboard > Backup tab**

### Key Features
- ✅ Real-time progress tracking (percentage, file count, speed, ETA)
- ✅ Backs up database, uploads, and metadata to Google Drive
- ✅ Fire-and-forget API (no 504 timeouts)
- ✅ Automatic cleanup of old local backups (>30 days)
- ✅ Cron job scheduling for daily auto-backup

## Core Behavior

- Android app uses Fused Location Provider with balanced power accuracy and significant movement thresholds.
- Offline mode caches points in Room and syncs automatically via WorkManager when connectivity returns.
- Backend stores users and location points in PostgreSQL; admin can manage users and fetch latest locations.
- Admin dashboard polls live locations and displays them on a map.
- Automatic daily backups to Google Drive at 2:00 AM UTC; manual backups on-demand from admin panel.
