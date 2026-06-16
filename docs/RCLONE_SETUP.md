# RCLONE GOOGLE DRIVE BACKUP SETUP GUIDE

This guide sets up automated backups to Google Drive using rclone for the GPS Tracker application.

## Prerequisites

- **OS**: Ubuntu Server (production) or Windows (local PC)
- **Google Account**: Personal Gmail account for Google Drive storage
- **rclone**: Command-line tool for cloud sync
- **Node.js**: Already installed on your server

---

## PART 1: CREATE GOOGLE DRIVE BACKUP FOLDER

1. Log in to Google Drive: `https://drive.google.com`
2. Create a folder named `GPSTrackerBackups` (or your preferred name)
3. Open the folder and copy the **Folder ID** from the URL:
   ```
   URL: https://drive.google.com/drive/folders/1A2B3C4D5E6F7G8H9I0J...
   Folder ID: 1A2B3C4D5E6F7G8H9I0J... (everything after "/folders/")
   ```
   **Keep this ID safe — you'll need it later.**

---

## PART 2: CREATE GOOGLE API CREDENTIALS

### Step 1: Enable Google Drive API

1. Open Google Cloud Console: `https://console.cloud.google.com/`
2. Log in with your Google Account
3. Select or create a **new project**
4. Search for **"Google Drive API"** and enable it

### Step 2: Configure OAuth Consent Screen

1. Go to **APIs & Services** > **OAuth consent screen**
2. Select **"External"** user type, click **Create**
3. Fill in:
   - **App Name**: `GPS Tracker Backup`
   - **User Support Email**: Your email
   - **Developer Contact**: Your email
   - Click **Save and Continue**
4. On Scopes page, click **Save and Continue**
5. Click **Back to Dashboard**
6. Find **Publishing status** and click **Publish App** (this prevents token expiry)

### Step 3: Create OAuth 2.0 Credentials

1. Go to **APIs & Services** > **Credentials**
2. Click **+ Create Credentials** > **OAuth client ID**
3. Set **Application type** to **"Desktop app"**
4. Name it `GPS Tracker Rclone` and click **Create**
5. A popup shows your credentials:
   - **Client ID**: `123456789-abcdef.apps.googleusercontent.com`
   - **Client Secret**: `GOCSPX-abc123xyz`

**Save both values — you'll need them next.**

---

## PART 3: INSTALL & CONFIGURE RCLONE

### On Your Local PC (Windows/Mac/Linux)

1. **Install rclone**:
   - Download from: `https://rclone.org/downloads/`
   - Extract and open terminal in that folder

2. **Run rclone config**:
   ```bash
   ./rclone.exe config
   ```

3. **Follow the prompts**:
   ```
   Type: n (New Remote)
   Name: gdrive
   Storage type: drive (Google Drive)
   Client ID: [Paste from Part 2 Step 3]
   Client Secret: [Paste from Part 2 Step 3]
   Scope: 1 (Full access)
   Service account file: [Leave blank, press Enter]
   Edit advanced config: n
   Use auto config: y
   ```

4. **Browser window opens** — log in with your Gmail and authorize

5. **Back at terminal**:
   ```
   Keep this "gdrive" remote? y
   Quit config: q
   ```

### Find Your Config File

Run this to see where rclone saved your config:
```bash
./rclone.exe config file
```

**On Windows**, it's typically at:
```
C:\Users\<YourUsername>\AppData\Roaming\rclone\rclone.conf
```

### View Your Config

Open `rclone.conf` in a text editor. It should look like:

```ini
[gdrive]
type = drive
scope = drive
client_id = 123456789-abcdef.apps.googleusercontent.com
client_secret = GOCSPX-abc123xyz
token = {"access_token":"ya29...","token_type":"Bearer","refresh_token":"1//...","expiry":"..."}
root_folder_id = 1A2B3C4D5E6F7G8H9I0J...
```

The **`root_folder_id`** is your Google Drive backup folder ID from Part 1.

---

## PART 4: CONFIGURE ON PRODUCTION SERVER

### SSH into your server and create rclone config:

```bash
mkdir -p ~/.config/rclone
nano ~/.config/rclone/rclone.conf
```

### Paste your config from Part 3:

```ini
[gdrive]
type = drive
scope = drive
client_id = [Your Client ID]
client_secret = [Your Client Secret]
token = [Your token JSON]
root_folder_id = [Your Backup Folder ID]
```

Save and exit (`Ctrl+O`, `Enter`, `Ctrl+X`)

### Test the connection:

```bash
rclone --config ~/.config/rclone/rclone.conf lsd gdrive:
```

You should see output listing any existing backups folder (or empty).

---

## PART 5: SET UP AUTOMATIC DAILY BACKUPS

### Edit your server `.env` file:

```bash
nano ~/gps_tracker/server/.env
```

Add or update:
```env
ENABLE_AUTO_BACKUP=true
RCLONE_CONFIG=/home/dckakadia/.config/rclone/rclone.conf
```

### Install required dependencies:

```bash
cd ~/gps_tracker/server
npm install
```

This installs `socket.io`, `node-cron`, and other required packages.

### Restart the backend:

```bash
npm start
```

**Automatic backups will now run daily at 2:00 AM UTC.**

---

## PART 6: MANUAL BACKUPS VIA ADMIN PANEL

1. Open the **Admin Dashboard**
2. Navigate to the **Backup** tab
3. Click **"Start Backup Now"**
4. Watch real-time progress:
   - File count & size
   - Upload speed
   - Estimated time remaining
5. When complete (100%), confirmation shows

---

## PART 7: VERIFICATION & TROUBLESHOOTING

### Check if backups are being created:

**Locally on server**:
```bash
ls -lh ~/gps_tracker/server/backups/
```

**On Google Drive**:
1. Open your `GPSTrackerBackups` folder in Google Drive
2. You should see folders: `backups/db`, `backups/uploads`, `backups/json`
3. Inside each, you'll see timestamped backup files

### View recent backups:

```bash
rclone --config ~/.config/rclone/rclone.conf ls gdrive:backups/
```

### Check auto-backup logs:

```bash
tail -f /home/dckakadia/backup.log
```

### Verify cron is running:

```bash
crontab -l
```

You should see a line like:
```
0 2 * * * /usr/bin/node -e "require('/home/dckakadia/gps_tracker/server/services/backup.js').performBackup().then(() => process.exit(0)).catch(() => process.exit(1))" >> /home/dckakadia/backup.log 2>&1
```

---

## COMMON ERRORS & FIXES

| Error | Solution |
|-------|----------|
| `403: Service Accounts do not have storage quota` | Use OAuth2 (done above), NOT Service Account |
| `invalid_grant` | Token expired; re-run `rclone config` on local PC |
| `directory name or volume label syntax is incorrect` | Check path quotes in Windows batch scripts |
| `Backup timed out (504)` | Normal — backend responds in <100ms; backup runs in background |
| `rclone: command not found` | Install rclone: `sudo apt-get install -y rclone` |

---

## NEXT STEPS

- **Monitor backups**: Check logs weekly with `tail -f /home/dckakadia/backup.log`
- **Restore**: Copy files from Google Drive back to `/home/dckakadia/gps_tracker/server/` as needed
- **Scale**: If backups grow > 100 GB, adjust rclone flags in `server/services/backup.js`

---

## QUICK REFERENCE

| Component | Path |
|-----------|------|
| Backup Service | `server/services/backup.js` |
| Backup Routes | `server/routes/backup.js` |
| Config | `~/.config/rclone/rclone.conf` |
| Local Backups | `server/backups/` |
| Auto-Backup Log | `/home/dckakadia/backup.log` |
| Cron Job | `crontab -e` |
