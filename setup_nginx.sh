#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

require_root
require_ubuntu

step "Installing the shared host Nginx gateway"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y nginx snapd

install -d -m 0755 /etc/nginx/snippets /etc/nginx/docker-sites /var/log/nginx/docker-sites

cat > /etc/nginx/conf.d/00-connection-upgrade.conf <<'EOF'
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
EOF

cat > /etc/nginx/snippets/docker-proxy.conf <<'EOF'
proxy_http_version 1.1;
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Host $host;
proxy_set_header X-Forwarded-Port $server_port;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection $connection_upgrade;
proxy_connect_timeout 15s;
proxy_send_timeout 120s;
proxy_read_timeout 120s;
proxy_buffering off;
EOF

rm -f /etc/nginx/sites-enabled/default
cat > /etc/nginx/sites-available/000-default-catchall.conf <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 444;
}
EOF
ln -sfn /etc/nginx/sites-available/000-default-catchall.conf /etc/nginx/sites-enabled/000-default-catchall.conf

nginx -t
systemctl enable --now nginx
systemctl reload nginx

step "Installing Certbot"
systemctl enable --now snapd.socket
snap wait system seed.loaded

if snap list core >/dev/null 2>&1; then
    snap refresh core || true
else
    snap install core
fi

if ! snap list certbot >/dev/null 2>&1; then
    snap install --classic certbot
fi
ln -sfn /snap/bin/certbot /usr/local/bin/certbot

success "Host Nginx and Certbot are ready."
info "Do not publish any website container directly on host ports 80 or 443."
