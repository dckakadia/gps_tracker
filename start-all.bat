@echo off
set ROOT=%~dp0
set "SERVER_DIR=%ROOT%server"
set "DASHBOARD_DIR=%ROOT%admin-dashboard"
set "FLUTTER_EXE=flutter"

where npm >nul 2>nul || (
  echo npm is not installed or not available on PATH.
  pause
  exit /b 1
)

where flutter >nul 2>nul || (
  if exist "%DASHBOARD_DIR%\flutter\bin\flutter.bat" (
    set "FLUTTER_EXE=%DASHBOARD_DIR%\flutter\bin\flutter.bat"
  ) else (
    echo flutter is not installed or not available on PATH, and no bundled SDK was found.
    pause
    exit /b 1
  )
)

start "GPS Backend" /D "%SERVER_DIR%" cmd /k "npm start"
start "Admin Dashboard" /D "%DASHBOARD_DIR%" cmd /k "%FLUTTER_EXE% pub get && %FLUTTER_EXE% run -d chrome"

echo Launched backend and dashboard in separate windows.
pause
