# Salesperson App Upload Debugging Guide

## Root Cause Analysis

The salesperson app was NOT uploading any location data to the backend. The audit log table on the live server confirmed zero upload attempts.

### Issues Found

1. **100-meter displacement threshold** - App only sends location when device moves 100+ meters
2. **10-minute update interval** - Location updates requested only every 10 minutes
3. **Combined effect** - A stationary test device would never trigger a location upload
4. **No test mode** - Impossible to debug uploads without physical device movement

## Test Mode Implementation

Debug mode is now active in the salesperson app with:
- **30-second location polling** (vs 10 minutes in production)
- **Zero displacement threshold** (vs 100 meters in production)
- **TEST button** for manual upload testing

## Debug Workflow

### Step 1: Install and Launch App
```bash
# Build and install debug APK
cd android-app
./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

### Step 2: Login to App
1. Open salesperson app on Android device
2. Login with test credentials:
   - Email: `devin@gps.com` (id=4) or `pratik@gps.com` (id=2)
   - Password: your configured password

### Step 3: Start Tracking Service
1. Tap **"Start Tracking"** button
2. Verify notification appears: "Employee Location Tracking - Location service is running"
3. Check Android logs:
   ```bash
   adb logcat | grep "TrackingService\|ApiClient\|MainActivity"
   ```

### Step 4: Wait for First Location Update
- Service requests location every 30 seconds (debug mode)
- Should see logs like:
   ```
   TrackingService: Processing location: lat=40.7128, lng=-74.0060
   TrackingService: Location uploaded successfully: lat=40.7128, lng=-74.0060
   ```

### Step 5: Manual Upload Testing
1. Tap **"TEST: Upload Now"** button (orange button)
2. Check logs for:
   - "Uploading N test location(s)" - locations found locally
   - "Test upload succeeded" - upload to backend succeeded
   - "No offline locations to upload" - database is empty (means realtime uploads worked)

### Step 6: Verify on Backend

#### Check Audit Log
```bash
# SSH to server
ssh dckakadia@116.74.77.22

# Get admin auth token
curl -X POST http://localhost:4000/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@gps.com","password":"your_password"}'

# Check audit log
curl http://localhost:4000/api/locations/upload-audit \
  -H "Authorization: Bearer YOUR_TOKEN"
```

Response should include:
```json
{
  "audits": [
    {
      "id": 1,
      "user_id": 4,
      "points_count": 1,
      "valid_points_count": 1,
      "status": "success",
      "ip_address": "...",
      "attempted_at": "2026-06-10T...",
      "request_body": {"latitude": 40.7128, "longitude": -74.0060, "recorded_at": ...}
    }
  ]
}
```

#### Check Live Locations
```bash
curl http://localhost:4000/api/locations/latest \
  -H "Authorization: Bearer YOUR_TOKEN"
```

Should show salesperson location:
```json
{
  "locations": [
    {
      "id": 4,
      "name": "Devin Kakadia",
      "email": "devin@gps.com",
      "latitude": 40.7128,
      "longitude": -74.0060,
      "recorded_at": "2026-06-10T..."
    }
  ]
}
```

## Troubleshooting

### No Location Updates in Logs
**Symptoms**: No "Processing location" messages appear
- **Check permissions**: Does app have location permission granted?
  ```bash
  adb shell dumpsys package permissions | grep com.example.gps_tracker
  ```
- **Enable location**: On device, enable Location services (GPS)
- **Grant permission**: Settings > Apps > GPS Tracker > Permissions > Location > Allow
- **Full logs**: 
  ```bash
  adb logcat | grep -E "TrackingService|LocationRequest|Permission"
  ```

### Token Not Found
**Symptoms**: "No auth token for test upload" in logs
- **Solution**: Login again - token may have expired (8-hour expiry)
- **Check stored token**:
  ```bash
  adb shell run-as com.example.gps_tracker cat \
    /data/data/com.example.gps_tracker/shared_prefs/auth_prefs.xml
  ```

### Upload Failed
**Symptoms**: "Upload failed" or "Upload exception" in logs
- **Check network**: Is device connected to internet?
- **Verify backend URL**: Should be `http://116.74.77.22:8095`
- **Check network security config**: Allows cleartext HTTP?
- **Full error**: Look for exception details in logcat

### Audit Log Empty After Upload
**Symptoms**: Upload succeeds but nothing appears in audit endpoint
- **Check user ID**: Verify `user_id` matches logged-in salesperson (4 or 2)
- **Check database**:
  ```bash
  ssh dckakadia@116.74.77.22
  psql gps_tracker
  SELECT * FROM location_upload_audit LIMIT 5;
  ```

## Production Revert Steps

When ready to deploy to production:

1. **Update TrackingService.kt**:
   ```kotlin
   interval = 10 * 60 * 1000L  // 10 minutes (not 30 seconds)
   fastestInterval = 5 * 60 * 1000L  // 5 minutes
   smallestDisplacement = 100f  // 100 meters (not 0f)
   priority = LocationRequest.PRIORITY_BALANCED_POWER_ACCURACY  // Battery saving
   ```

2. **Remove TEST button** from activity_main.xml (optional - can leave for support)

3. **Rebuild and deploy**:
   ```bash
   ./gradlew assembleRelease
   # Deploy to Google Play or distribute signed APK
   ```

## Key Files Modified

- `android-app/app/src/main/java/com/example/gps_tracker/TrackingService.kt` - Location polling intervals
- `android-app/app/src/main/java/com/example/gps_tracker/MainActivity.kt` - Test upload button
- `android-app/app/src/main/res/layout/activity_main.xml` - UI button layout

## Backend Support

### Admin Audit Endpoint
- **URL**: `GET /api/locations/upload-audit`
- **Auth**: Requires admin token
- **Returns**: Last 100 upload attempts with full request context
- **Useful for**: Diagnosing why uploads fail

### Logs Endpoint
- **Location**: `/home/dckakadia/gps_tracker`
- **Command**: `pm2 logs gps-tracker`
- **Filter for salesperson uploads**: Look for user_id 4 or 2

## Common Tests

### Test 1: Immediate Upload (Requires Manual Action)
1. Start tracking service
2. Tap TEST button
3. Check audit log - should see entry

### Test 2: Automatic Periodic Upload (Requires Waiting)
1. Start tracking service
2. Wait 30+ seconds
3. Check audit log - should see entry

### Test 3: Offline-to-Online Sync
1. Disable internet
2. Start tracking service (30s interval)
3. Enable internet
4. Tap TEST button
5. Check audit log - should see entries

### Test 4: Token Expiry
1. Start tracking
2. Wait 8+ hours
3. Upload fails - user logs back in
4. Upload succeeds - token refreshed

---

**Last Updated**: 2026-06-10
**Debug Mode**: ACTIVE (For testing only - will be reverted for production)
