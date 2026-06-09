# PRODUCTION DEPLOYMENT CHECKLIST - BACKUP SETUP

This document outlines the complete steps to deploy the GPS Tracker backup system on a production Ubuntu server.

---

## PRE-DEPLOYMENT CHECKLIST

- [ ] Google Cloud Project created with Google Drive API enabled
- [ ] OAuth credentials generated (Client ID & Client Secret)
- [ ] Google Drive backup folder created (`GPSTrackerBackups` or similar)
- [ ] Backup folder ID copied and saved
- [ ] `rclone` config file generated on local PC
- [ ] SSH access to production server confirmed

---

## DEPLOYMENT STEPS

### 1. SSH into Production Server

```bash
ssh user@your-server-ip
```

### 2. Copy rclone Configuration

Copy your local `rclone.conf` to the server:

```bash
mkdir -p ~/.config/rclone
nano ~/.config/rclone/rclone.conf
```

Paste your `rclone` config from your local PC (see `RCLONE_SETUP.md` Part 3).

### 3. Test rclone Connection

```bash
rclone --config ~/.config/rclone/rclone.conf lsd gdrive:
```

Expected output: A list of existing folders or empty (if new).

### 4. Install Backend Dependencies

```bash
cd ~/gps_tracker/server
npm install
```

This installs `socket.io`, `node-cron`, and backup utilities.

### 5. Update Environment File

```bash
nano ~/gps_tracker/server/.env
```

Ensure these lines exist:

```env
ENABLE_AUTO_BACKUP=true
RCLONE_CONFIG=/home/dckakadia/.config/rclone/rclone.conf
```

If your username differs from `dckakadia`, adjust the path accordingly.

### 6. Restart Backend

```bash
pm2 restart gps-backend
# or
npm start
```

### 7. Set Up Cron Job for Auto-Backup (Optional)

If using `node-cron` within the app (no external cron needed):
- Auto-backup runs at **2:00 AM UTC daily** (see `app.js`)
- No additional cron setup required

**Alternative: Use system cron for guaranteed execution:**

```bash
crontab -e
```

Add this line (adjust path if needed):

```cron
0 2 * * * /usr/bin/node -e "require('/home/dckakadia/gps_tracker/server/services/backup.js').performBackup().then(() => process.exit(0)).catch(err => { console.error(err); process.exit(1); })" >> /tmp/backup.log 2>&1
```

Save and exit (`Ctrl+O`, `Enter`, `Ctrl+X`).

### 8. Verify Cron Job

```bash
crontab -l
```

You should see your backup line listed.

---

## POST-DEPLOYMENT VERIFICATION

### Manual Test Backup

1. Open Admin Dashboard
2. Navigate to **Backup** tab
3. Click **"Start Backup Now"**
4. Verify real-time progress updates
5. Check for success message

### Check Backup Files

**Locally on server**:
```bash
ls -lh ~/gps_tracker/server/backups/
```

**On Google Drive**:
- Open your `GPSTrackerBackups` folder
- You should see: `backups/db/`, `backups/uploads/`, `backups/json/`

### View Backup Log

```bash
tail -50 /tmp/backup.log
```

Or if using PM2:
```bash
pm2 logs gps-backend | grep backup
```

---

## TROUBLESHOOTING

### rclone Command Not Found

```bash
sudo apt-get update
sudo apt-get install -y rclone
```

### Token Expired Error

1. Regenerate config on local PC:
   ```bash
   rclone config
   ```
2. Copy new config to server
3. Test connection: `rclone --config ~/.config/rclone/rclone.conf lsd gdrive:`

### Backup Timed Out (504)

This is **expected and normal**. The API responds instantly; rclone runs in the background. Check logs to verify completion.

### Cron Job Not Running

Check system logs:
```bash
sudo journalctl -u cron -n 50
```

Or test cron directly:
```bash
0 * * * * /usr/bin/node -e "console.log(new Date().toISOString())" >> /tmp/cron-test.log 2>&1
# Wait 1 minute, then:
cat /tmp/cron-test.log
```

---

## MONITORING & MAINTENANCE

### Daily Backup Verification

Add to your monitoring routine:
```bash
# Check today's backups
find ~/gps_tracker/server/backups -mtime -1 -type f
```

### Monitor Disk Space

```bash
# Check backup directory size
du -sh ~/gps_tracker/server/backups/

# Check Google Drive quota
rclone --config ~/.config/rclone/rclone.conf about gdrive:
```

### Cleanup Old Backups

Automatic cleanup happens after each backup (keeps last 30 days).
To manually remove backups older than 30 days:

```bash
find ~/gps_tracker/server/backups -mtime +30 -type f -delete
```

---

## RESTORE PROCEDURES

### Restore from Google Drive

1. List available backups:
   ```bash
   rclone --config ~/.config/rclone/rclone.conf ls gdrive:backups/
   ```

2. Download a specific backup:
   ```bash
   rclone --config ~/.config/rclone/rclone.conf copy gdrive:backups/db/dev.db ~/restore/
   ```

3. Restore the database (be careful!):
   ```bash
   # Backup current database first
   cp ~/gps_tracker/server/db/dev.db ~/gps_tracker/server/db/dev.db.bak
   
   # Copy restored file
   cp ~/restore/dev.db ~/gps_tracker/server/db/dev.db
   ```

4. Restart backend:
   ```bash
   pm2 restart gps-backend
   ```

---

## SCALING & OPTIMIZATION

### For Large Backups (> 100 GB)

Adjust rclone flags in `server/services/backup.js`:

```javascript
const rcloneArgs = [
  '--config', RCLONE_CONFIG,
  '--stats', '5s',              // Longer interval for stability
  '--stats-one-line',
  '--multi-thread-streams', '4', // Parallel uploads
  '--transfers', '4'            // Number of files in parallel
];
```

### Change Auto-Backup Time

Edit `server/app.js`:

```javascript
// Change from "0 2 * * *" (2 AM UTC) to your preferred time
cron.schedule('0 3 * * *', async () => {  // 3 AM UTC
  // ...
});
```

See [cron schedule format](https://github.com/node-cron/node-cron#cron-syntax).

---

## QUICK REFERENCE

| Task | Command |
|------|---------|
| Test rclone | `rclone --config ~/.config/rclone/rclone.conf lsd gdrive:` |
| View cron jobs | `crontab -l` |
| Edit cron | `crontab -e` |
| Check PM2 logs | `pm2 logs gps-backend` |
| Manual cleanup | `find ~/gps_tracker/server/backups -mtime +30 -delete` |
| List Google Drive backups | `rclone --config ~/.config/rclone/rclone.conf ls gdrive:backups/` |

---

## SUPPORT

For issues:
1. Check logs: `pm2 logs` or `/tmp/backup.log`
2. Review `RCLONE_SETUP.md` for authentication issues
3. Verify rclone can reach Google Drive: `rclone --config ~/.config/rclone/rclone.conf about gdrive:`
