#!/usr/bin/env pwsh
# Apply database migration on live server
# Run this from PowerShell on Windows

$server = "116.74.77.22"
$user = "dckakadia"

Write-Host "Applying database migration to live server..." -ForegroundColor Cyan
Write-Host "Server: $server"
Write-Host ""

# Migration SQL - adds username column if it doesn't exist
$migrationSQL = @"
ALTER TABLE users ADD COLUMN IF NOT EXISTS username TEXT UNIQUE;
SELECT column_name FROM information_schema.columns 
WHERE table_name = 'users' AND column_name = 'username';
"@

# Run migration on remote server
Write-Host "Executing migration..." -ForegroundColor Yellow
$migrationSQL | ssh $user@$server "psql gps_tracker"

if ($LASTEXITCODE -eq 0) {
    Write-Host "Migration applied successfully!" -ForegroundColor Green
    Write-Host ""
    Write-Host "Restarting backend..." -ForegroundColor Yellow
    ssh $user@$server "cd gps_tracker && pm2 restart gps-tracker"
    
    Write-Host ""
    Write-Host "Backend status:" -ForegroundColor Yellow
    ssh $user@$server "pm2 status"
} else {
    Write-Host "Migration failed!" -ForegroundColor Red
    exit 1
}
