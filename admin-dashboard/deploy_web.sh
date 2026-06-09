#!/usr/bin/env bash
set -euo pipefail

BUILD_DIR="$(pwd)/build/web"
WEB_ROOT="/var/www/gps-tracker-admin"
SITE_CONF="/etc/nginx/sites-available/gps-tracker-admin.conf"

if [ ! -d "$BUILD_DIR" ]; then
  echo "Error: build/web folder not found. Run 'flutter build web --release' first."
  exit 1
fi

sudo apt update
sudo apt install -y nginx
sudo mkdir -p "$WEB_ROOT"
sudo rm -rf "$WEB_ROOT"/*
sudo cp -r "$BUILD_DIR"/* "$WEB_ROOT/"

sudo tee "$SITE_CONF" > /dev/null <<'EOF'
server {
    listen 80;
    server_name _;
    root $WEB_ROOT;
    index index.html;

    location / {
        try_files $uri $uri/ /index.html;
    }

    location = /50x.html {
        root /usr/share/nginx/html;
    }
}
EOF

sudo ln -sf "$SITE_CONF" /etc/nginx/sites-enabled/gps-tracker-admin.conf
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl restart nginx

echo "Flutter web dashboard deployed to http://<server-ip>/"
