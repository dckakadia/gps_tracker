# GPS Tracker Production Deployment Playbook

## 1. ADMIN USER SEED AUTOMATION

### Updated seed script
The backend seed script now defaults to the following production admin user:
- Email: `admin@tracker.local`
- Username: `admin`
- Password: `Admin@1234`

This script is located at:
- `server/seed.js`

It also supports overrides via environment variables in `server/.env`:
- `ADMIN_EMAIL`
- `ADMIN_NAME`
- `ADMIN_PASSWORD`

### Recommended seed execution
Run this from the backend folder on the Ubuntu server:

```bash
cd /home/dckakadia/gps_tracker/server
sudo -u postgres NODE_ENV=production ADMIN_EMAIL=admin@tracker.local ADMIN_NAME=admin ADMIN_PASSWORD='Admin@1234' node seed.js
```

If the `.env` file already contains the desired values, you may simply run:

```bash
cd /home/dckakadia/gps_tracker/server
node seed.js
```

> The script will detect an existing admin account and exit cleanly if it already exists.

---

## 2. LINUX SYSTEMD SERVICE FILE FOR CRASH PROTECTION

### Service file path
Create or update the service unit at:
- `/etc/systemd/system/gps-backend.service`

### Service unit content
```ini
[Unit]
Description=GPS Tracker Node.js Backend
After=network.target postgresql.service
Requires=postgresql.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/home/dckakadia/gps_tracker/server
EnvironmentFile=/home/dckakadia/gps_tracker/server/.env
Environment=NODE_ENV=production
ExecStart=/usr/bin/node /home/dckakadia/gps_tracker/server/app.js
Restart=on-failure
RestartSec=5s
StartLimitIntervalSec=60s
StartLimitBurst=5
KillSignal=SIGINT
TimeoutStopSec=20s
User=dckakadia
Group=dckakadia
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=yes
StandardOutput=journal
StandardError=journal
LogIdentifier=gps-backend

[Install]
WantedBy=multi-user.target
```

### Enable and start the service
```bash
sudo systemctl daemon-reload
sudo systemctl enable gps-backend.service
sudo systemctl start gps-backend.service
```

### Check service status
```bash
sudo systemctl status gps-backend.service
```

If you need logs immediately:
```bash
sudo journalctl -u gps-backend.service --no-pager -n 50
```

---

## 3. PRODUCTION COMPILATION VALIDATION AND CHECKS

### Flutter web build validation
From the Flutter admin dashboard folder:

```bash
cd /path/to/gps_tracker/admin-dashboard
flutter pub get
flutter config --enable-web
flutter build web --release
```

If Flutter is installed correctly, this should complete without errors.

### Android APK build validation
From the Android app folder:

```bash
cd /path/to/gps_tracker/android-app
./gradlew assembleRelease
```

On Windows, use:

```powershell
cd C:\Users\Oceanspas\Desktop\gps_tracker\android-app
gradlew.bat assembleRelease
```

### Artifact locations
- Flutter web build output:
  - `admin-dashboard/build/web`
- Android release APK:
  - `android-app/app/build/outputs/apk/release/app-release.apk`

If the APK is not present, check for similarly named files under:
- `android-app/app/build/outputs/apk/release/`

---

## 4. SERVER MONITORING & INFRASTRUCTURE LOG SHELL COMMANDS

### a) Tail Nginx access and error logs
```bash
sudo tail -F /var/log/nginx/access.log /var/log/nginx/error.log
```

### b) Tail the Node.js API logs
```bash
sudo journalctl -u gps-backend.service -f
```

### c) Verify PostgreSQL location inserts in real time
Run this from the Ubuntu server:

```bash
sudo -u postgres psql -d gps_tracker -c "SELECT COUNT(*) AS total_locations, MAX(recorded_at) AS latest_recorded_at FROM locations;"
```

For a recent activity snapshot:

```bash
sudo -u postgres psql -d gps_tracker -c "SELECT id, device_id, latitude, longitude, recorded_at FROM locations ORDER BY recorded_at DESC LIMIT 20;"
```

---

## QUICK START LAUNCH SEQUENCE

1. Deploy backend code to `/home/dckakadia/gps_tracker/server`
2. Ensure `server/.env` is configured with the live production DB URL, JWT secret, and admin credentials
3. Install Node dependencies:
   ```bash
   cd /home/dckakadia/gps_tracker/server
   npm install --production
   ```
4. Create the database schema and grant privileges:
   ```bash
   sudo -u postgres psql -d gps_tracker -f /home/dckakadia/gps_tracker/server/db/schema.sql
   sudo -u postgres psql -d gps_tracker -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO gps_tracker_user; GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO gps_tracker_user;"
   ```
5. Seed the admin user:
   ```bash
   cd /home/dckakadia/gps_tracker/server
   node seed.js
   ```
6. Configure and start systemd:
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable gps-backend.service
   sudo systemctl start gps-backend.service
   sudo systemctl status gps-backend.service
   ```
7. Deploy the Flutter web build to Nginx or static hosting and verify via browser
8. Use the monitoring commands above while traffic begins flowing

---

## NOTES
- `server/seed.js` now includes secure production defaults.
- `server/gps-backend.service` is built for automatic restart, journald logging, and boot-time startup.
- The web and Android clients are already configured to hit `http://116.74.77.22:8095/api`.
