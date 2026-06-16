#!/bin/bash
# Ubuntu production deployment script for GPS Tracker backend.
# Run as a non-root user with sudo access:
#   chmod +x deploy_ubuntu.sh && ./deploy_ubuntu.sh
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER_USER="${SUDO_USER:-$(whoami)}"
NODE_VERSION="20"
DB_NAME="gps_tracker"
DB_USER="gps_tracker"
SERVICE_NAME="gps-backend"
WEB_ROOT="/var/www/gps-tracker-admin"
NGINX_SITE="gps-tracker"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[DEPLOY]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC}   $1"; }
die()  { echo -e "${RED}[ERROR]${NC}  $1"; exit 1; }

# ---------- 1. System packages ----------
log "Updating package list..."
sudo apt-get update -qq

# Node.js 20 LTS
if ! command -v node &>/dev/null || [[ "$(node -v 2>/dev/null)" != v${NODE_VERSION}* ]]; then
    log "Installing Node.js ${NODE_VERSION} LTS..."
    curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | sudo -E bash -
    sudo apt-get install -y nodejs
fi
log "Node: $(node -v)  npm: $(npm -v)"

# PostgreSQL
if ! command -v psql &>/dev/null; then
    log "Installing PostgreSQL..."
    sudo apt-get install -y postgresql postgresql-contrib
fi
sudo systemctl enable postgresql
sudo systemctl start postgresql

# nginx
if ! command -v nginx &>/dev/null; then
    log "Installing nginx..."
    sudo apt-get install -y nginx
fi
sudo systemctl enable nginx
sudo systemctl start nginx

# ---------- 2. PostgreSQL database & user ----------
log "Setting up PostgreSQL..."
DB_EXISTS=$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" 2>/dev/null || echo "")
if [ -z "$DB_EXISTS" ]; then
    DB_PW=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 40)
    sudo -u postgres psql -c "CREATE USER ${DB_USER} WITH PASSWORD '${DB_PW}';"
    log "Created PostgreSQL user '${DB_USER}' with auto-generated password"
else
    warn "PostgreSQL user '${DB_USER}' already exists — skipping creation"
    DB_PW=""
fi

DB_CREATED=$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" 2>/dev/null || echo "")
if [ -z "$DB_CREATED" ]; then
    sudo -u postgres psql -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};"
    log "Created database '${DB_NAME}'"
fi

# Apply schema (idempotent — all statements use IF NOT EXISTS)
log "Applying database schema..."
sudo -u postgres psql -d "${DB_NAME}" -f "${APP_DIR}/db/schema.sql"
log "Schema applied"

# ---------- 3. .env setup ----------
if [ ! -f "${APP_DIR}/.env" ]; then
    cp "${APP_DIR}/.env.example" "${APP_DIR}/.env"
    log "Created .env from .env.example"
fi

# Fill DATABASE_URL if not already pointing to postgres
if ! grep -qE "^DATABASE_URL=postgresql://.+@" "${APP_DIR}/.env"; then
    if [ -n "${DB_PW:-}" ]; then
        sed -i "s|^DATABASE_URL=.*|DATABASE_URL=postgresql://${DB_USER}:${DB_PW}@localhost:5432/${DB_NAME}|" "${APP_DIR}/.env"
        log "Set DATABASE_URL in .env"
    else
        warn "Could not auto-set DATABASE_URL (user already existed). Edit ${APP_DIR}/.env manually."
    fi
fi

# Disable in-memory fallback
sed -i "s|^USE_IN_MEMORY_DB=true|USE_IN_MEMORY_DB=false|" "${APP_DIR}/.env"

# Auto-generate JWT secrets if still placeholder
if grep -q "replace_with_64_char_random_string" "${APP_DIR}/.env"; then
    JWT_SECRET=$(openssl rand -base64 48)
    REFRESH_SECRET=$(openssl rand -base64 48)
    sed -i "s|^JWT_SECRET=.*|JWT_SECRET=${JWT_SECRET}|" "${APP_DIR}/.env"
    sed -i "s|^REFRESH_SECRET=.*|REFRESH_SECRET=${REFRESH_SECRET}|" "${APP_DIR}/.env"
    log "Generated JWT secrets"
fi

# Validate required vars exist
set -a; source "${APP_DIR}/.env"; set +a
[ -z "${DATABASE_URL:-}" ] && die "DATABASE_URL is not set in .env. Edit ${APP_DIR}/.env and re-run."
[ -z "${JWT_SECRET:-}" ]   && die "JWT_SECRET is not set in .env."

# ---------- 4. Node dependencies ----------
log "Installing Node.js dependencies..."
cd "${APP_DIR}"
npm install --omit=dev

# ---------- 5. Seed admin user ----------
log "Seeding admin user (skipped if already exists)..."
npm run seed || warn "Seed returned non-zero — admin may already exist"

# ---------- 6. Systemd service ----------
log "Installing systemd service..."
NODE_BIN="$(which node)"

sudo tee /etc/systemd/system/${SERVICE_NAME}.service > /dev/null <<UNIT
[Unit]
Description=GPS Tracker Node.js Backend
After=network.target postgresql.service
Requires=postgresql.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${APP_DIR}
EnvironmentFile=${APP_DIR}/.env
Environment=NODE_ENV=production
ExecStart=${NODE_BIN} ${APP_DIR}/app.js
Restart=on-failure
RestartSec=5s
StartLimitBurst=5
KillSignal=SIGINT
TimeoutStopSec=20s
User=${SERVER_USER}
Group=${SERVER_USER}
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable ${SERVICE_NAME}.service
sudo systemctl restart ${SERVICE_NAME}.service
log "Backend service started"

# ---------- 7. nginx ----------
log "Configuring nginx..."
sudo mkdir -p "${WEB_ROOT}"
sudo chown -R www-data:www-data "${WEB_ROOT}"

NGINX_CONF="${APP_DIR}/../admin-dashboard/gps-tracker-nginx.conf"
if [ -f "${NGINX_CONF}" ]; then
    sudo cp "${NGINX_CONF}" /etc/nginx/sites-available/${NGINX_SITE}
    sudo ln -sf /etc/nginx/sites-available/${NGINX_SITE} /etc/nginx/sites-enabled/${NGINX_SITE}
    sudo rm -f /etc/nginx/sites-enabled/default
    sudo nginx -t && sudo systemctl reload nginx
    log "nginx configured"
else
    warn "nginx config not found at ${NGINX_CONF} — skipping nginx setup"
fi

# ---------- 8. Summary ----------
echo ""
log "=========================================="
log " Deployment complete!"
log "=========================================="
echo ""
sudo systemctl status ${SERVICE_NAME}.service --no-pager || true
echo ""
SERVER_IP=$(curl -s --max-time 3 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
echo "  Backend health:  http://${SERVER_IP}:4000/health"
echo "  Admin dashboard: http://${SERVER_IP}  (after uploading Flutter build)"
echo ""
echo "  To upload the Flutter web dashboard (run from your Mac):"
echo "    cd gps_tracker/admin-dashboard"
echo "    flutter build web"
echo "    scp -r build/web/* ${SERVER_USER}@${SERVER_IP}:${WEB_ROOT}/"
echo ""
echo "  To check backend logs:"
echo "    sudo journalctl -u ${SERVICE_NAME} -f"
echo ""
