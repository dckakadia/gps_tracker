#!/bin/bash
# Mac-side script: build the Flutter web dashboard and upload it to the Ubuntu server.
# Usage:
#   ./build_dashboard.sh USER@SERVER_IP
#   ./build_dashboard.sh ubuntu@203.0.113.42
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DASHBOARD_DIR="${SCRIPT_DIR}/admin-dashboard"
WEB_ROOT="/var/www/gps-tracker-admin"

if [ -z "${1:-}" ]; then
    echo "Usage: $0 USER@SERVER_IP"
    echo "  e.g. $0 ubuntu@203.0.113.42"
    exit 1
fi

SERVER="$1"

echo "[1/3] Building Flutter web (API routed through nginx /api)..."
cd "${DASHBOARD_DIR}"
flutter build web

echo "[2/3] Uploading to ${SERVER}:${WEB_ROOT} ..."
ssh "${SERVER}" "sudo mkdir -p ${WEB_ROOT} && sudo chown \$(whoami):\$(whoami) ${WEB_ROOT}"
scp -r build/web/* "${SERVER}:${WEB_ROOT}/"
ssh "${SERVER}" "sudo chown -R www-data:www-data ${WEB_ROOT}"

echo "[3/3] Done."
echo "  Dashboard: http://$(echo "$SERVER" | cut -d@ -f2)"
