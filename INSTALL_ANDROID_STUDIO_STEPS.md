# Android Studio Installation & APK Build Guide

## Step 1: Download Android Studio

1. Open your browser and go to: https://developer.android.com/studio
2. Click the **"Download Android Studio"** button
3. Accept the license terms
4. The download will start (~1 GB file)

---

## Step 2: Install Android Studio

1. **Run the installer** `AndroidStudio-2024.X.X-windows.exe`
2. Click **"Next"** through the Welcome screen
3. On **"Choose Components"**: Keep all defaults checked
   - ✓ Android Studio
   - ✓ Android Virtual Device
4. On **"Android SDK"**: Accept default location
   - Usually: `C:\Users\Oceanspas\AppData\Local\Android\Sdk`
5. Click **"Next"** and **"Install"**
6. Installation takes 5-15 minutes depending on internet speed
7. When done, check **"Start Android Studio"** and click **"Finish"**

---

## Step 3: Initial Android Studio Setup (First Time Only)

When Android Studio launches for the first time:

1. You may see a "Data Sharing" dialog - click **"Don't Send"**
2. On the Welcome screen, click **"Next"**
3. You'll see "Install Type" - select **"Standard"** (default)
4. Click **"Next"** through all screens
5. Click **"Finish"** - it will download SDK components (~2-3 GB)
   - This can take 10-20 minutes
   - **Don't close the window during download**

---

## Step 4: Configure Environment Variables

After Android Studio finishes setup:

1. **Open Environment Variables:**
   - Press `Win + X` on your keyboard
   - Click on **"System"** (or search for "Environment Variables")
   - Click **"Environment Variables"** button at the bottom right

2. **Create ANDROID_HOME variable:**
   - Click **"New"** under System Variables
   - Variable name: `ANDROID_HOME`
   - Variable value: `C:\Users\Oceanspas\AppData\Local\Android\Sdk`
   - Click **"OK"**

3. **Add to PATH:**
   - Select **"Path"** in System Variables
   - Click **"Edit"**
   - Click **"New"** and add: `%ANDROID_HOME%\platform-tools`
   - Click **"New"** and add: `%ANDROID_HOME%\tools`
   - Click **"OK"** three times to close all dialogs

4. **IMPORTANT: Close and reopen PowerShell** for changes to take effect

---

## Step 5: Verify Installation

Open a **NEW PowerShell window** (important!) and run:

```powershell
# Verify Java
java -version

# Verify Android SDK
echo $env:ANDROID_HOME

# Verify ADB
adb version
```

Each command should show version information, NOT "not found" errors.

**If any command fails:**
- Make sure you used a NEW PowerShell window (close and reopen)
- Verify environment variables were set correctly (recheck Step 4)
- Restart your computer if still having issues

---

## Step 6: Build the Debug APK

Once all three commands above work:

```powershell
# Navigate to android-app directory
cd c:\Users\Oceanspas\Desktop\gps_tracker\android-app

# Build the debug APK (first time takes 3-5 minutes)
.\gradlew.bat assembleDebug
```

**Expected output:**
```
...
BUILD SUCCESSFUL in 4m 32s
```

**APK is created at:**
```
app\build\outputs\apk\debug\app-debug.apk
```

---

## Step 7: Install on Android Device

### Prerequisites:
- Android phone or emulator connected via USB
- USB Debugging enabled (Settings > Developer Options > USB Debugging)
- Device has granted USB permission

### Install:

```powershell
# Install the APK
adb install -r app\build\outputs\apk\debug\app-debug.apk

# Verify installation worked
adb shell pm list packages | findstr "gps_tracker"
# Should output: package:com.example.gps_tracker

# Launch the app
adb shell am start -n com.example.gps_tracker/.MainActivity
```

---

## Step 8: Test the App

1. **App opens** on your Android device
2. **Login** with salesperson credentials:
   - Email: `devin@gps.com` or `pratik@gps.com`
   - Password: (check with your admin)
3. **Tap "Start Tracking"** button
   - You should see notification: "Employee Location Tracking"
4. **Wait 30 seconds** for first location update
   - Check logs: `adb logcat | findstr "TrackingService"`
5. **Tap orange "TEST: Upload Now"** button
   - Should see "Test upload succeeded" in logs

---

## Troubleshooting

### "gradlew.bat not recognized"
```powershell
# Make sure you're in the android-app directory
cd c:\Users\Oceanspas\Desktop\gps_tracker\android-app
ls gradlew*  # Should show gradlew and gradlew.bat
```

### "adb not found" or "SDK not found"
- **Did you restart PowerShell?** Must close and reopen after setting environment variables
- Check `echo $env:ANDROID_HOME` returns the SDK path
- If still failing, restart your computer

### Build fails with "SDK version not found"
- Open Android Studio
- Go to **Tools > SDK Manager**
- Install: **Android SDK Platform 34** (Android 14)
- Install: **Android SDK Build-Tools 34.x.x**
- Click **"OK"** and wait for download

### Device not found with "adb devices"
- **Windows**: Install USB drivers from phone manufacturer
- **Restart ADB**: `adb kill-server` then `adb devices`
- Try different USB cable or USB port
- Enable USB Debugging again (disable/enable in Settings)

---

## Command Reference

```powershell
# Check environment
java -version
echo $env:ANDROID_HOME
adb version

# Navigate to android-app
cd c:\Users\Oceanspas\Desktop\gps_tracker\android-app

# Build APK
.\gradlew.bat assembleDebug

# Check APK was created
ls app\build\outputs\apk\debug\app-debug.apk

# Work with device
adb devices              # List connected devices
adb install -r app\build\outputs\apk\debug\app-debug.apk  # Install app
adb uninstall com.example.gps_tracker  # Remove app
adb logcat | findstr "TAG"  # View logs
adb shell pm list packages | findstr "gps_tracker"  # Check installed
```

---

## Next Steps After APK Build

1. Install APK on device
2. Login and start tracking
3. Wait for location updates
4. Test manual upload button
5. Check backend audit log:
   ```bash
   curl http://116.74.77.22:8095/api/locations/upload-audit \
     -H "Authorization: Bearer ADMIN_TOKEN"
   ```

---

**Total time to complete:** 30-45 minutes (mostly waiting for downloads)
