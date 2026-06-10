# Android App Setup for Windows

## Current Status

Your system has:
- ✅ Java 21.0.10 LTS installed
- ❌ Android SDK NOT installed
- ❌ ADB (Android Debug Bridge) NOT in PATH
- ❌ Gradle wrapper scripts missing

## Quick Start: Install Android Studio

### Step 1: Download & Install Android Studio
1. Go to: https://developer.android.com/studio
2. Click **"Download Android Studio"**
3. Run the installer
4. Choose **Standard Installation**
5. Accept defaults - this will install:
   - Android SDK
   - Gradle build system
   - ADB (Android Debug Bridge)
   - Emulator

**Installation takes ~5-10 minutes**

### Step 2: Configure Environment Variables

After Android Studio installs:

1. **Find your Android SDK location:**
   - Open Android Studio
   - File > Settings > Appearance & Behavior > System Settings > Android SDK
   - Note the "Android SDK Location" (usually `C:\Users\Oceanspas\AppData\Local\Android\Sdk`)

2. **Set environment variables (Windows):**
   - Press `Win+X` → Click "System" (or search "Environment Variables")
   - Click "Environment Variables" button
   - Under "System Variables" → Click "New"
   - Create variable:
     ```
     Variable name: ANDROID_HOME
     Variable value: C:\Users\Oceanspas\AppData\Local\Android\Sdk
     ```
   - Edit "Path" variable → Add these entries:
     ```
     %ANDROID_HOME%\platform-tools
     %ANDROID_HOME%\tools
     %ANDROID_HOME%\cmdline-tools\latest\bin
     ```
   - Click OK and close all dialogs

3. **Restart PowerShell** (must restart for PATH to take effect)

### Step 3: Verify Setup

Open a **NEW PowerShell window** and run:

```powershell
# Check Java
java -version

# Check ADB
adb version

# Check Android SDK
echo $env:ANDROID_HOME
```

All three should return version information (not "not found").

---

## Build the Debug APK

Once setup is complete:

```powershell
cd c:\Users\Oceanspas\Desktop\gps_tracker\android-app

# First time will download dependencies (5-10 minutes)
.\gradlew.bat assembleDebug

# If gradlew.bat fails, try gradle directly (if installed globally)
gradle assembleDebug
```

**Expected output:**
```
...
BUILD SUCCESSFUL in 2m 15s
```

**APK location:** `app\build\outputs\apk\debug\app-debug.apk`

---

## Install on Android Device

### Prepare Android Device:

1. **Enable Developer Mode:**
   - Go to Settings > About Phone
   - Tap "Build Number" 7 times
   - You'll see "Developer options unlocked"

2. **Enable USB Debugging:**
   - Go to Settings > Developer Options
   - Turn ON "USB Debugging"

3. **Connect to PC via USB**

### Install App:

```powershell
cd c:\Users\Oceanspas\Desktop\gps_tracker\android-app

# Install APK
adb install -r app\build\outputs\apk\debug\app-debug.apk

# Verify installation
adb shell pm list packages | findstr "gps_tracker"

# Launch app
adb shell am start -n com.example.gps_tracker/.MainActivity
```

---

## Troubleshooting

### "adb not found"
- Verify ANDROID_HOME is set: `echo $env:ANDROID_HOME`
- Verify Path includes: `$env:ANDROID_HOME\platform-tools`
- **Must restart PowerShell after setting environment variables**

### "gradlew.bat not found"
- Navigate to `android-app` directory
- Run: `ls gradlew*`
- Should see `gradlew` and `gradlew.bat`
- If missing, need to extract from Android gradle wrapper

### Build fails with "SDK not installed"
- Open Android Studio
- Go to Tools > SDK Manager
- Install: Android SDK Platform 34 (Android 14)
- Install: Android SDK Build-Tools 34.x.x

### Device not recognized
- Windows: Install USB drivers from device manufacturer
- Linux/Mac: Usually works automatically
- Try: `adb devices` to list connected devices

---

## Quick Verification Script

Save this as `Verify-AndroidSetup.ps1`:

```powershell
$errors = @()

# Check Java
try {
    $java = java -version 2>&1
    if ($?) { Write-Host "✓ Java found" -ForegroundColor Green }
} catch {
    $errors += "Java not found"
}

# Check ADB
try {
    $adb = adb version 2>&1
    if ($LASTEXITCODE -eq 0) { Write-Host "✓ ADB found" -ForegroundColor Green }
} catch {
    $errors += "ADB not found"
}

# Check ANDROID_HOME
if ($env:ANDROID_HOME) {
    Write-Host "✓ ANDROID_HOME set: $($env:ANDROID_HOME)" -ForegroundColor Green
} else {
    $errors += "ANDROID_HOME not set"
}

# Check Platform Tools
$platformTools = Join-Path $env:ANDROID_HOME "platform-tools\adb.exe"
if (Test-Path $platformTools) {
    Write-Host "✓ Platform tools found" -ForegroundColor Green
} else {
    $errors += "Platform tools not found"
}

# Report
if ($errors.Count -eq 0) {
    Write-Host "" -ForegroundColor Green
    Write-Host "All checks passed! Ready to build." -ForegroundColor Green
} else {
    Write-Host "" -ForegroundColor Red
    Write-Host "Issues found:" -ForegroundColor Red
    foreach ($err in $errors) {
        Write-Host "  - $err" -ForegroundColor Red
    }
}
```

---

## Next Steps

1. Install Android Studio from https://developer.android.com/studio
2. Set ANDROID_HOME and PATH environment variables
3. Restart PowerShell
4. Run `.\gradlew.bat assembleDebug` from android-app directory
5. Install APK on device: `adb install -r app\build\outputs\apk\debug\app-debug.apk`
6. Test on device:
   - Tap "Start Tracking" button
   - Wait 30 seconds for first location
   - Tap "TEST: Upload Now" button
   - Verify in backend: Check audit log

---

## Alternative: Use Android Emulator

If you don't have a physical device:

1. In Android Studio: Tools > AVD Manager
2. Create new Virtual Device (Android 14, Pixel 6)
3. Start emulator
4. Run: `adb install -r app\build\outputs\apk\debug\app-debug.apk`

The emulator simulates GPS - you can set mock location in Settings > Developer Options > Mock location app.

---

**Status**: Ready to build once Android Studio is installed
