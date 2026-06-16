# Android Emulator Setup Guide for Windows

## What is an Emulator?

An Android emulator is a virtual Android device that runs on your PC. It lets you:
- ✅ Test apps without a physical phone
- ✅ Simulate GPS/location easily
- ✅ View detailed logs for debugging
- ✅ Test multiple Android versions

---

## Step 1: Check if Android Studio is Installed

Open PowerShell and run:

```powershell
# Check if Android Studio exists
Test-Path "C:\Program Files\Android\Android Studio\bin\studio64.exe"
```

If it returns `True`, continue to Step 2.

If it returns `False`:
- Install Android Studio from: https://developer.android.com/studio
- Run the installer and complete setup
- Then come back here

---

## Step 2: Open Android Studio

1. Press `Win + R` on your keyboard
2. Type: `C:\Program Files\Android\Android Studio\bin\studio64.exe`
3. Press Enter (or use Start Menu to find "Android Studio")

Wait for Android Studio to fully load (30-60 seconds).

---

## Step 3: Create a Virtual Device

Once Android Studio is open:

1. **Find the AVD Manager:**
   - Click menu: **Tools > Device Manager** (or **Tools > AVD Manager** in older versions)

2. **Create new emulator:**
   - Click **"Create Virtual Device"** button
   - You'll see a dialog showing available device types

3. **Select Device Type:**
   - Choose **"Pixel 6"** (good balance of size and performance)
   - Click **"Next"**

4. **Select System Image (Android Version):**
   - You should see a list of Android versions
   - **Click "Release Name" column** to see Android 14 (or latest)
   - If Android 14 doesn't appear:
     - Click the download icon next to it
     - Wait for download to complete (1-2 GB)
   - Select **Android 14 (API 34)** or higher
   - Click **"Next"**

5. **Verify Configuration:**
   - Device Name: `Pixel_6_API_34` (or default name)
   - RAM: 2048 MB (or higher if your PC has it)
   - Click **"Finish"**

You'll return to Device Manager and see your new emulator listed.

---

## Step 4: Start the Emulator

In Android Studio's Device Manager:

1. Find your newly created device (e.g., "Pixel_6_API_34")
2. Click the **"Play" button** (▶️) on the right side
3. Wait for the emulator to boot (2-3 minutes first time)

You should see:
- Android boot screen with Google logo
- Eventually the home screen with Android wallpaper
- Status bar at the top showing time and icons

**Leave the emulator running in the background.**

---

## Step 5: Install the GPS Tracker APK

Open PowerShell in the android-app directory:

```powershell
cd c:\Users\Oceanspas\Desktop\gps_tracker\android-app

# Install APK on the running emulator
adb install -r app\build\outputs\apk\debug\app-debug.apk
```

**Expected output:**
```
adb: device 'emulator-5554' offline; cannot sideload 'app-debug.apk'
...waiting for device...
```

Wait 30-60 seconds for emulator to fully boot. Then it will show:
```
Success
```

---

## Step 6: Launch the App

After successful installation, launch from emulator:

1. **Find the app on emulator home screen:**
   - Look for "GPS Tracker" icon (blue location marker)
   - Tap it to open

OR use command line:

```powershell
adb shell am start -n com.example.gps_tracker/.MainActivity
```

---

## Step 7: Enable Mock Location (GPS Simulation)

The emulator can't access real GPS, so we'll simulate it:

1. **On the emulator screen:**
   - Go to **Settings** > **System** > **About phone**
   - Tap **"Build Number"** 7 times (like real phone)
   - You'll see "Developer options unlocked"

2. **Enable Developer Options:**
   - Go back to **Settings**
   - Go to **System** > **Developer options** (now visible)
   - Turn ON: **"USB Debugging"**
   - Scroll down and find: **"Select mock location app"**
   - Select: **"GPS Tracker"** (our app)

3. **Grant Location Permission:**
   - Close Settings
   - Open GPS Tracker app again
   - Allow location permission when prompted

---

## Step 8: Test the App

1. **Tap "Start Tracking"** button in GPS Tracker app
   - You should see notification: "Employee Location Tracking - Location service is running"

2. **Wait 30 seconds** for location updates
   - App will request location from system

3. **View live logs:**
   ```powershell
   # In a new PowerShell window
   adb logcat | findstr "TrackingService"
   ```
   
   Should show:
   ```
   TrackingService: Processing location: lat=40.7128, lng=-74.0060
   TrackingService: Location uploaded successfully
   ```

4. **Tap "TEST: Upload Now"** button (orange button)
   - Logs should show upload status
   - If successful: "Test upload succeeded"
   - If failed: "Test upload failed" (check error reason)

---

## Step 9: Verify on Backend

Check if uploads reached the backend:

```powershell
# SSH to server
ssh dckakadia@116.74.77.22

# Get admin token (use your admin password)
curl -X POST http://localhost:4000/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@gps.com","password":"YOUR_PASSWORD"}' 2>/dev/null | jq .token

# Check upload audit log
curl http://localhost:4000/api/locations/upload-audit \
  -H "Authorization: Bearer ADMIN_TOKEN" 2>/dev/null | jq
```

Should return audit entries showing the test uploads!

---

## Troubleshooting

### "Emulator won't start"
- **Solution**: Increase allocated RAM in Android Studio
  - Tools > Device Manager > Right-click device > Edit
  - Increase RAM to 4096 MB
  - Try again

### "adb says device offline"
- Wait 1-2 minutes for emulator to fully boot
- If still offline: `adb kill-server` then `adb devices`
- Restart emulator

### "No location updates in logs"
- Check if location permission granted
- Check if mock location app is set
- On emulator, open Settings > Location > Make sure it's ON
- Restart app

### "Upload failed" in logs
- Check network connectivity: Emulator should auto-connect to PC network
- Verify backend is running: `curl http://localhost:4000/health`
- Check if login successful before testing upload
- View full error: `adb logcat | findstr "ApiClient\|Exception"`

### "Build new APK from code changes"
```powershell
cd c:\Users\Oceanspas\Desktop\gps_tracker\android-app

# Rebuild
& ".\gradle-8.4\gradle-8.4\bin\gradle.bat" "assembleDebug"

# Reinstall (old version will be replaced)
adb install -r app\build\outputs\apk\debug\app-debug.apk

# Restart app
adb shell am start -n com.example.gps_tracker/.MainActivity
```

---

## Useful Commands

```powershell
# List running devices/emulators
adb devices

# View real-time logs
adb logcat                                    # All logs
adb logcat | findstr "TrackingService"       # Filter to tracking service
adb logcat | findstr "ApiClient"             # Filter to API calls

# Install app
adb install -r app\build\outputs\apk\debug\app-debug.apk

# Launch app
adb shell am start -n com.example.gps_tracker/.MainActivity

# Uninstall app
adb uninstall com.example.gps_tracker

# View device properties
adb shell getprop

# Stop emulator
adb emu kill

# Take screenshot from emulator
adb shell screencap -p > emulator_screenshot.png
```

---

## Next Steps

1. **Create virtual device** (Step 3)
2. **Start emulator** (Step 4)
3. **Install APK** (Step 5)
4. **Enable mock location** (Step 7)
5. **Test app** (Step 8)
6. **Check backend logs** (Step 9)

Once you see location uploads in the audit log, the app is working! 🎉

---

## Timeline
- **Create device**: 2 minutes
- **Download system image**: 5-10 minutes (first time only)
- **Boot emulator**: 2-3 minutes
- **Install & test app**: 5 minutes
- **Total**: 15-25 minutes

---

**Status**: Ready to create emulator. Open Android Studio and start with Step 3!
