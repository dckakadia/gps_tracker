@echo off
REM Setup script for Android development on Windows
REM This script checks for required tools and helps configure the environment

setlocal enabledelayedexpansion

echo ======================================
echo Android Development Environment Setup
echo ======================================
echo.

REM Check for Java
echo [*] Checking for Java...
where java >nul 2>&1
if %errorlevel% neq 0 (
    echo [X] Java not found. Install Java JDK 17 or later from:
    echo     https://www.oracle.com/java/technologies/downloads/
    pause
    exit /b 1
) else (
    for /f "tokens=*" %%A in ('java -version 2^>^&1') do (
        echo [OK] %%A
    )
)
echo.

REM Check for Android SDK
echo [*] Checking for Android SDK...
if not defined ANDROID_HOME (
    echo [X] ANDROID_HOME environment variable not set.
    echo.
    echo To set up Android SDK:
    echo 1. Download Android Studio from: https://developer.android.com/studio
    echo 2. Install Android Studio
    echo 3. In Android Studio, go to: Tools ^> SDK Manager
    echo 4. Install SDK Platform ^> Android 14 (API 34^)
    echo 5. Install SDK Tools ^> Android SDK Command-line Tools
    echo.
    echo 6. Set ANDROID_HOME environment variable:
    echo    - Open System Properties ^> Environment Variables
    echo    - Add new System Variable:
    echo      Name: ANDROID_HOME
    echo      Value: C:\Users\[YourUsername]\AppData\Local\Android\Sdk
    echo.
    pause
    exit /b 1
) else (
    echo [OK] ANDROID_HOME: !ANDROID_HOME!
)
echo.

REM Check for ADB
echo [*] Checking for ADB (Android Debug Bridge)...
where adb >nul 2>&1
if %errorlevel% neq 0 (
    echo [X] adb not found in PATH
    echo     Add this to your system PATH: %ANDROID_HOME%\platform-tools
    echo     Then restart PowerShell or Command Prompt
    echo.
    pause
    exit /b 1
) else (
    for /f "tokens=*" %%A in ('adb version 2^>^&1 ^| findstr /R "^Android"') do (
        echo [OK] %%A
    )
)
echo.

REM Navigate to android-app
if exist "android-app" (
    cd android-app
    echo [*] Navigated to android-app directory
) else (
    echo [X] Could not find android-app directory
    echo     Make sure you run this from the gps_tracker root directory
    pause
    exit /b 1
)
echo.

REM Build APK
echo [*] Building debug APK...
echo     This may take 2-5 minutes on first build
echo.

gradlew.bat assembleDebug
if %errorlevel% neq 0 (
    echo [X] Build failed
    pause
    exit /b 1
) else (
    echo [OK] Build succeeded!
    echo.
    echo APK location: app\build\outputs\apk\debug\app-debug.apk
    echo.
)

echo ======================================
echo [*] Installation Steps:
echo ======================================
echo 1. Connect Android device via USB
echo 2. Enable Developer Mode: Settings ^> About Phone ^> Tap Build Number 7 times
echo 3. Enable USB Debugging: Settings ^> Developer Options ^> USB Debugging
echo 4. Run this command:
echo.
echo     adb install -r app\build\outputs\apk\debug\app-debug.apk
echo.
echo ======================================
pause
