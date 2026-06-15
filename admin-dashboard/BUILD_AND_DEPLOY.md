# Admin Dashboard - Build & Deploy Guide

## Changes Made

### 1. User Name Labels on Map Pins ✅
- **Status**: Already implemented (visible in markers below the location pin)
- **Details**: Shows salesperson name in white info box with live/stale status

### 2. Auto-Zoom to User Locations ✅
- **Status**: Newly implemented in `lib/screens/map_screen.dart`
- **Features**:
  - Single user: Zooms in to level 13 on page load
  - Multiple users: Automatically fits all pins in view with optimal zoom level
  - Only triggers on initial page load (not on filter changes)

## Prerequisites

1. **Flutter SDK** (v3.0+) installed and added to PATH
   - Install: https://flutter.dev/docs/get-started/install
   - Verify: `flutter --version`

2. **Web support enabled**:
   ```bash
   flutter config --enable-web
   ```

## Build Instructions

### Step 1: Build Web Version (Recommended for Production)

From the `admin-dashboard` directory:

```bash
# Clean previous builds
flutter clean

# Get dependencies
flutter pub get

# Build for web release
flutter build web --release
```

**Output Location**: `build/web/`

**Build Time**: ~2-5 minutes depending on machine

### Step 2: Build APK (If deploying to Android)

```bash
flutter build apk --release
```

**Output**: `build/app/outputs/flutter-apk/app-release.apk`

## Deployment

### Option A: Deploy to Linux Server (Web)

1. **Copy the `build/web` directory** to your deployment machine
2. **Run the deployment script**:
   ```bash
   chmod +x deploy_web.sh
   ./deploy_web.sh
   ```

   This script will:
   - Install nginx (if not present)
   - Copy files to `/var/www/gps-tracker-admin`
   - Configure nginx for the dashboard
   - Restart nginx service

3. **Verify deployment**: Open `http://<server-ip>/` in browser

### Option B: Manual Web Deployment

```bash
# Copy built files to your web root
sudo cp -r build/web/* /var/www/gps-tracker-admin/

# Verify files copied
sudo ls -la /var/www/gps-tracker-admin/

# Restart nginx
sudo systemctl restart nginx
```

### Option C: Deploy APK to Android Devices

```bash
# Connect device via USB
adb devices

# Install APK
adb install -r build/app/outputs/flutter-apk/app-release.apk

# Launch app
adb shell am start -n com.example.gps_tracker/.MainActivity
```

## Testing the Changes

After deployment:

1. **Open the Admin Dashboard** → Navigate to **Live Map**
2. **Verify User Names**: Check that salesperson names appear below the red pins
3. **Test Auto-Zoom**: 
   - With 1 active user: Map should zoom to level 13 on that location
   - With 2+ users: Map should fit all users in view at optimal zoom
   - Refresh the page: Auto-zoom should trigger again

## Troubleshooting

### Build Issues

**Error**: `flutter: command not found`
```bash
# Add Flutter to PATH
export PATH="$PATH:$HOME/flutter/bin"
```

**Error**: `Web platform not enabled`
```bash
flutter config --enable-web
flutter doctor -v  # Verify setup
```

### Deployment Issues

**Nginx won't start**:
```bash
sudo nginx -t  # Check config syntax
sudo systemctl status nginx
```

**Files not copying**:
```bash
# Ensure sufficient disk space
df -h /var/www/

# Check permissions
sudo chmod -R 755 /var/www/gps-tracker-admin/
```

## Rollback

If deployment issues occur:

```bash
# Restore from backup (if available)
sudo cp -r /var/www/gps-tracker-admin.backup/* /var/www/gps-tracker-admin/

# Or re-deploy previous version by rebuilding from prior commit
git checkout <previous-commit>
flutter build web --release
./deploy_web.sh
```

## Performance Notes

- **Map refresh**: 12 seconds (polling interval)
- **Auto-zoom**: Triggers once on page load
- **Zoom levels**: 3-18 (standard for web maps)
- **Single user zoom**: Level 13 (street level detail)
- **Multiple users**: Dynamic based on geographic spread

## Code Changes Summary

**File**: `lib/screens/map_screen.dart`

- Added `MapController` for programmatic map control
- Added `_hasInitializedMap` flag to track first load
- Added `_autoZoomToMarkers()` method to calculate optimal zoom
- Integrated bounds calculation for multiple markers
- MapController passed to FlutterMap widget

No other files were modified. Live Map is the only affected screen.
