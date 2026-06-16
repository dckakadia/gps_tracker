# Deployment & Troubleshooting Runbook

## 1. Ubuntu Server Live Reboot & Crash Protection

### Option A: Systemd service
Create `/etc/systemd/system/gps-backend.service` with the following content:

```ini
[Unit]
Description=GPS Tracker Node.js Backend
After=network.target postgresql.service
Requires=postgresql.service

[Service]
Type=simple
WorkingDirectory=/home/ubuntu/gps_tracker/server
EnvironmentFile=/home/ubuntu/gps_tracker/server/.env
ExecStart=/usr/bin/node /home/ubuntu/gps_tracker/server/app.js
Restart=always
RestartSec=5
KillSignal=SIGINT
TimeoutStopSec=20
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=gps-backend
User=ubuntu

[Install]
WantedBy=multi-user.target
```

Adjust `WorkingDirectory`, `EnvironmentFile`, and `User` to match your deployment path and Linux user.

### Enable and start the service

```bash
sudo systemctl daemon-reload
sudo systemctl enable gps-backend.service
sudo systemctl start gps-backend.service
sudo systemctl status gps-backend.service
```

### Option B: PM2 ecosystem file
If you prefer PM2, use `server/pm2.config.js` and install PM2 globally:

```bash
cd /home/ubuntu/gps_tracker/server
npm install pm2 -g
pm2 start pm2.config.js --env production
pm2 save
pm2 startup systemd
```

Then follow PM2's printed instructions to enable startup on reboot.

---

## 2. System Test & Validation Protocol

### A. Pre-flight checklist
1. Confirm PostgreSQL is running:
   - `sudo systemctl status postgresql`
2. Confirm backend is running:
   - `curl http://localhost:4000/health`
3. Confirm database schema loaded:
   - `psql "$DATABASE_URL" -c "\dt"`
4. Confirm admin seed exists:
   - `psql "$DATABASE_URL" -c "SELECT email, role FROM users;"`

### B. Login test
1. Create admin via `seed.js` or use configured admin credentials.
2. Test auth endpoint with cURL:

```bash
curl -X POST http://localhost:4000/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@example.com","password":"ChangeMe123!"}'
```

Expected response includes a `token` field.

### C. POST /api/locations manual tests
Use the valid JWT token from login in the `Authorization` header.

#### Single location ping

```bash
curl -X POST http://localhost:4000/api/locations \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_JWT_TOKEN" \
  -d '{"latitude": 37.4220, "longitude": -122.0841, "recorded_at": 1700000000000}'
```

#### Bulk array payload

```bash
curl -X POST http://localhost:4000/api/locations \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_JWT_TOKEN" \
  -d '[
    {"latitude": 37.4220, "longitude": -122.0841, "recorded_at": 1700000000000},
    {"latitude": 37.4230, "longitude": -122.0850, "recorded_at": 1700000060000},
    {"latitude": 37.4240, "longitude": -122.0860, "recorded_at": 1700000120000}
  ]'
```

### D. Database validation
1. Confirm rows inserted:

```bash
psql "$DATABASE_URL" -c "SELECT id, user_id, latitude, longitude, recorded_at, received_at FROM locations ORDER BY id DESC LIMIT 5;"
```

2. Validate latest location query:

```bash
psql "$DATABASE_URL" -c "SELECT u.name, l.latitude, l.longitude, l.recorded_at, l.received_at FROM users u JOIN LATERAL (SELECT latitude, longitude, recorded_at, received_at FROM locations WHERE user_id = u.id ORDER BY recorded_at DESC LIMIT 1) l ON true WHERE u.role = 'salesperson';"
```

### E. Live end-to-end validation
1. Start the Android app and log in with salesperson credentials.
2. Confirm `LoginActivity` receives a JWT and starts `TrackingService`.
3. Confirm the service writes either to the backend or local SQLite when network is offline.
4. Restore connectivity and verify cached points sync successfully.
5. Open Admin Dashboard and confirm live map polls the latest coordinates.

---

## 3. Re-sync Edge Case Handlers

### What happens if the phone clock is inaccurate?

- The current schema stores both:
  - `recorded_at` = device timestamp
  - `received_at` = server ingestion timestamp
- This means inaccurate device clocks do not overwrite existing rows or corrupt the database.

### How the current system behaves
- All incoming location rows are persisted with the provided `recorded_at` value.
- `received_at` always records when the server received the payload.
- The `latest` endpoint uses the greatest `recorded_at` per user, so an old backdated ping will not become the latest if a newer timestamp already exists.
- If the device sends a future-dated or incorrect timestamp, the row is still stored, but server-side auditing remains possible through `received_at`.

### Recommended safety improvement
For a tighter production system, add validation in `POST /api/locations` such as:
- reject `recorded_at` values more than `24` hours in the past
- reject timestamps more than `10` minutes in the future
- compare `recorded_at` with `received_at` for anomaly detection

This keeps the system robust against bad device clock skew while preserving all real data.
