$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$serverDir = Join-Path $root 'server'
$dashboardDir = Join-Path $root 'admin-dashboard'

function Test-Executable($name) {
  try {
    Get-Command $name -ErrorAction Stop | Out-Null
    return $true
  } catch {
    return $false
  }
}

if (-not (Test-Executable npm)) {
  Write-Error 'npm is not installed or not available on PATH.'
  exit 1
}

$flutterPath = 'flutter'
if (-not (Test-Executable flutter)) {
  $localFlutter = Join-Path $dashboardDir 'flutter\bin\flutter.bat'
  if (Test-Path $localFlutter) {
    Write-Host 'Using bundled Flutter SDK from the repo.'
    $flutterPath = $localFlutter
  } else {
    Write-Error 'flutter is not installed or not available on PATH, and no bundled SDK was found.'
    exit 1
  }
}

$psPath = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
if (-not $psPath) {
  $psPath = (Get-Command powershell.exe -ErrorAction SilentlyContinue)?.Source
}
if (-not $psPath) {
  Write-Error 'PowerShell executable not found in PATH.'
  exit 1
}

Write-Host 'Starting backend in a new terminal...'
Start-Process -FilePath $psPath -ArgumentList '-NoExit', '-Command', 'npm start' -WorkingDirectory $serverDir

Start-Sleep -Milliseconds 500
Write-Host 'Starting Flutter admin dashboard in a new terminal...'
Start-Process -FilePath $psPath -ArgumentList '-NoExit', '-Command', "& '$flutterPath' pub get; & '$flutterPath' run -d chrome" -WorkingDirectory $dashboardDir

Write-Host 'Both startup commands have been launched.'
Write-Host 'Check the new terminal windows for backend and dashboard output.'
