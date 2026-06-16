#!/bin/bash

# Quick Deploy Script
# Run this on your deployment server after copying the built files

set -euo pipefail

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}Admin Dashboard - Quick Deploy${NC}"
echo "This script deploys the built Flutter web dashboard"
echo ""

# Configuration
WEB_ROOT="${1:-/var/www/gps-tracker-admin}"
NGINX_CONF="/etc/nginx/sites-available/gps-tracker-admin.conf"

echo "Deployment Path: $WEB_ROOT"
echo ""

# Ensure we have the build directory
if [ ! -d "build/web" ]; then
    echo "❌ build/web directory not found!"
    echo "Run 'flutter build web --release' first"
    exit 1
fi

echo "📦 Creating web root directory..."
sudo mkdir -p "$WEB_ROOT"

echo "📋 Backing up current deployment (if exists)..."
if [ -d "$WEB_ROOT" ] && [ "$(ls -A "$WEB_ROOT")" ]; then
    sudo cp -r "$WEB_ROOT" "$WEB_ROOT.backup.$(date +%s)"
fi

echo "📤 Copying built files..."
sudo cp -r build/web/* "$WEB_ROOT/"

echo "⚙️  Configuring nginx..."
sudo tee "$NGINX_CONF" > /dev/null <<'EOF'
server {
    listen 80;
    server_name _;
    
    root /var/www/gps-tracker-admin;
    index index.html;
    
    # Enable gzip compression
    gzip on;
    gzip_types text/plain text/css text/javascript application/javascript application/json;
    
    # Prevent caching of the Flutter service worker and version file
    location = /flutter_service_worker.js {
        add_header Cache-Control "no-cache, must-revalidate";
        access_log off;
    }

    location = /version.json {
        add_header Cache-Control "no-cache, must-revalidate";
        access_log off;
    }
    
    # Regular asset caching
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        add_header Cache-Control "max-age=31536000, immutable";
        access_log off;
    }
    
    # Main routing - important for Flutter web
    location / {
        try_files $uri $uri/ /index.html;
    }
    
    # Error pages
    location = /50x.html {
        root /usr/share/nginx/html;
    }
}
EOF

echo "🔗 Enabling nginx configuration..."
sudo ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/gps-tracker-admin.conf
sudo rm -f /etc/nginx/sites-enabled/default

echo "✅ Testing nginx configuration..."
if ! sudo nginx -t; then
    echo "❌ Nginx configuration test failed!"
    exit 1
fi

echo "🔄 Restarting nginx..."
sudo systemctl restart nginx

echo ""
echo -e "${GREEN}✅ Deployment complete!${NC}"
echo ""
echo "Access your dashboard at:"
echo "  http://$(hostname -I | awk '{print $1}')/"
echo "  or http://your-server-ip/"
echo ""
echo "Logs available at:"
echo "  sudo tail -f /var/log/nginx/access.log"
echo "  sudo tail -f /var/log/nginx/error.log"
