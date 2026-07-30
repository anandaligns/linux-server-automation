#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

require_root

DOMAIN="${1:-}"
if [[ -z "$DOMAIN" ]]; then
    read -r -p "Domain to remove from host Nginx: " DOMAIN
fi
DOMAIN="${DOMAIN,,}"

if [[ ! "$DOMAIN" =~ ^[a-z0-9.-]+$ ]]; then
    error "Invalid domain."
    exit 1
fi

SITE_CONFIG="/etc/nginx/sites-available/$DOMAIN.conf"
SITE_LINK="/etc/nginx/sites-enabled/$DOMAIN.conf"
SITE_METADATA="/etc/nginx/docker-sites/$DOMAIN.env"

if [[ ! -e "$SITE_CONFIG" && ! -L "$SITE_LINK" ]]; then
    error "No managed Nginx site was found for $DOMAIN."
    exit 1
fi

read -r -p "Type REMOVE-$DOMAIN to disable this proxy: " confirmation
if [[ "$confirmation" != "REMOVE-$DOMAIN" ]]; then
    warning "Nothing was changed."
    exit 0
fi

rm -f "$SITE_LINK"
if [[ -e "$SITE_CONFIG" ]]; then
    mv "$SITE_CONFIG" "${SITE_CONFIG}.disabled.$(date +%Y%m%d_%H%M%S)"
fi

# deploy_project.sh reads these metadata files to detect loopback port collisions.
# Leaving one behind keeps the retired domain's port reserved forever, so a new
# website on that port is rejected with a conflict against a site that is gone.
if [[ -e "$SITE_METADATA" ]]; then
    released_port="$(awk -F= '$1 == "PORT" {print substr($0, index($0, "=") + 1); exit}' "$SITE_METADATA")"
    rm -f "$SITE_METADATA"
    info "Released loopback port ${released_port:-unknown} for reuse."
fi

nginx -t
systemctl reload nginx
success "$DOMAIN was removed from host Nginx. Its containers and certificate were not deleted."
