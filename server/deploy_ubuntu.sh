#!/bin/bash
set -e

# Use the script directory as the app deploy path.
APP_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_FILE="/etc/systemd/system/gps-backend.service"

cd "$APP_DIR"

# Install dependencies
npm install

# Copy env template if needed
if [ ! -f .env ]; then
  cp .env.example .env
  echo "Created .env from .env.example. Please edit .env with DATABASE_URL, JWT_SECRET, ADMIN_EMAIL, ADMIN_PASSWORD, and PORT."
  exit 1
fi

# Seed admin user if needed
npm run seed || true

# Install service file and start backend via systemd
sudo cp "$APP_DIR/gps-backend.service" "$SERVICE_FILE"
sudo systemctl daemon-reload
sudo systemctl enable gps-backend.service
sudo systemctl restart gps-backend.service
sudo systemctl status gps-backend.service --no-pager

echo "Deployment script complete. If the service is not running, inspect 'sudo journalctl -u gps-backend.service -n 50'."
