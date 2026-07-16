#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

NEW_USER="${NEW_USER:-anand}"

echo
echo "=============================================="
echo "  Docker Web Host Status"
echo "=============================================="

for service in ssh docker nginx fail2ban docker-host-firewall; do
    if systemctl is-active --quiet "$service"; then
        success "$service is active"
    else
        warning "$service is not active"
    fi
done

if command -v docker >/dev/null 2>&1; then
    docker --version
    docker compose version
    echo
    docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

    exposed="$(docker ps --format '{{.Names}} {{.Ports}}' | grep -E '0\.0\.0\.0:|\[::\]:' || true)"
    if [[ -n "$exposed" ]]; then
        warning "Containers are directly exposed on all interfaces:"
        echo "$exposed"
        echo "Bind website ingress to 127.0.0.1 instead."
    else
        success "No running container is directly exposed on all interfaces."
    fi
fi

if command -v nginx >/dev/null 2>&1; then
    nginx -t
    echo "Enabled host sites:"
    find /etc/nginx/sites-enabled -maxdepth 1 -type l -printf '  %f -> %l\n' 2>/dev/null | sort || true
fi

if command -v ufw >/dev/null 2>&1; then
    ufw status verbose
fi

if id "$NEW_USER" >/dev/null 2>&1; then
    USER_HOME="$(getent passwd "$NEW_USER" | cut -d: -f6)"
    if [[ -s "$USER_HOME/.ssh/authorized_keys" ]]; then
        echo "Authorized key fingerprints for $NEW_USER:"
        ssh-keygen -lf "$USER_HOME/.ssh/authorized_keys" || true
    else
        warning "No authorized keys found for $NEW_USER."
    fi
fi

echo "Listening web and loopback ingress ports:"
ss -ltnp | grep -E ':(80|443|80[0-9][0-9])[[:space:]]' || true
