#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

require_root

DOMAIN=""
PORT=""
EMAIL=""
INCLUDE_WWW="no"
ENABLE_SSL="no"

usage() {
    cat <<'EOF'
Usage:
  sudo bash add_docker_site.sh --domain example.com --port 8081 [--www] [--ssl --email admin@example.com]

The site's Docker Nginx container must publish only to loopback:
  127.0.0.1:8081:80
EOF
}

while (( $# > 0 )); do
    case "$1" in
        --domain) DOMAIN="${2:-}"; shift 2 ;;
        --port) PORT="${2:-}"; shift 2 ;;
        --email) EMAIL="${2:-}"; shift 2 ;;
        --www) INCLUDE_WWW="yes"; shift ;;
        --ssl) ENABLE_SSL="yes"; shift ;;
        --help|-h) usage; exit 0 ;;
        *) error "Unknown argument: $1"; usage; exit 1 ;;
    esac
done

if [[ -z "$DOMAIN" ]]; then
    read -r -p "Domain name (example.com): " DOMAIN
fi
if [[ -z "$PORT" ]]; then
    read -r -p "Unique loopback port (for example 8081): " PORT
fi

DOMAIN="${DOMAIN,,}"
if [[ ! "$DOMAIN" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]]; then
    error "Invalid domain: $DOMAIN"
    exit 1
fi
if [[ ! "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1024 || PORT > 65535 )); then
    error "Port must be a number from 1024 through 65535."
    exit 1
fi

if [[ "$ENABLE_SSL" == "yes" && -z "$EMAIL" ]]; then
    read -r -p "Email for Let's Encrypt: " EMAIL
fi
if [[ "$ENABLE_SSL" == "yes" && ! "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
    error "A valid email is required for SSL."
    exit 1
fi

SERVER_NAMES="$DOMAIN"
CERTBOT_DOMAINS=(-d "$DOMAIN")
if [[ "$INCLUDE_WWW" == "yes" ]]; then
    SERVER_NAMES="$DOMAIN www.$DOMAIN"
    CERTBOT_DOMAINS+=(-d "www.$DOMAIN")
fi

SITE_CONFIG="/etc/nginx/sites-available/$DOMAIN.conf"
SITE_LINK="/etc/nginx/sites-enabled/$DOMAIN.conf"
SITE_LOG_DIR="/var/log/nginx/docker-sites/$DOMAIN"
SITE_METADATA="/etc/nginx/docker-sites/$DOMAIN.env"

if ss -ltnH | awk '{print $4}' | grep -Eq "^(0\.0\.0\.0|\[::\]):$PORT$"; then
    error "Port $PORT is exposed on every network interface."
    error "Change Docker Compose to 127.0.0.1:$PORT:80 before continuing."
    exit 1
fi

if ! ss -ltnH | awk '{print $4}' | grep -Eq "^(127\.0\.0\.1|\[::1\]):$PORT$"; then
    warning "Nothing is currently listening on 127.0.0.1:$PORT."
    warning "The Nginx configuration can be created, but SSL and live traffic require healthy containers first."
fi

if [[ -e "$SITE_CONFIG" ]]; then
    backup_file "$SITE_CONFIG"
fi
install -d -m 0755 "$SITE_LOG_DIR"

cat > "$SITE_CONFIG" <<EOF
# Managed by add_docker_site.sh
server {
    listen 80;
    listen [::]:80;
    server_name $SERVER_NAMES;

    access_log $SITE_LOG_DIR/access.log;
    error_log $SITE_LOG_DIR/error.log warn;
    client_max_body_size 50m;

    location / {
        proxy_pass http://127.0.0.1:$PORT;
        include /etc/nginx/snippets/docker-proxy.conf;
    }
}
EOF

ln -sfn "$SITE_CONFIG" "$SITE_LINK"

if ! nginx -t; then
    rm -f "$SITE_LINK"
    error "Nginx rejected the new site configuration. It was disabled."
    exit 1
fi
systemctl reload nginx

cat > "$SITE_METADATA" <<EOF
DOMAIN=$DOMAIN
PORT=$PORT
INCLUDE_WWW=$INCLUDE_WWW
EOF
chmod 0644 "$SITE_METADATA"

success "HTTP reverse proxy created: $DOMAIN -> 127.0.0.1:$PORT"

if [[ "$ENABLE_SSL" == "yes" ]]; then
    if ! command -v certbot >/dev/null 2>&1; then
        error "Certbot is not installed. Run setup_nginx.sh first."
        exit 1
    fi
    info "Requesting the TLS certificate. DNS must already point to this server."
    certbot --nginx \
        --non-interactive \
        --agree-tos \
        --redirect \
        --email "$EMAIL" \
        "${CERTBOT_DOMAINS[@]}"
    success "HTTPS enabled for $SERVER_NAMES"
fi

echo
echo "Test locally on the server: curl -I http://127.0.0.1:$PORT"
echo "Test through Nginx:          curl -I http://$DOMAIN"
