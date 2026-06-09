# Android Tracking App

This module contains the Android client for employee location tracking.

## Setup

1. Open `android-app` in Android Studio.
2. Add your backend token storage or login flow.
3. Set `ApiClient.BASE_URL` to the backend API host in `ApiClient.kt`.
4. Implement a login screen or populate `AuthManager` with a valid JWT.
5. Run the app on a physical device or emulator with location permissions.

## Local build

1. Install Android SDK command-line tools and ensure `android-app/local.properties` points to the SDK root.
2. Use JDK 17 for local builds. The project already includes `android-app/gradle.properties` configured for JDK 17.
3. From `android-app`, run:
   - `gradle-8.4\gradle-8.4\bin\gradle.bat assembleDebug`
4. The produced APK is at `android-app/app/build/outputs/apk/debug/app-debug.apk`.

## Behavior

- Uses Fused Location Provider with `PRIORITY_BALANCED_POWER_ACCURACY`.
- Saves location points locally in Room when network or authorization is unavailable.
- Uses WorkManager to sync cached points when connectivity returns.
- Runs as a foreground service to keep tracking active even if the UI is closed.
