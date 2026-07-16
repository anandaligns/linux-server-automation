#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

require_root
require_ubuntu

TIMEZONE="${TIMEZONE:-Asia/Kolkata}"
NEW_HOSTNAME="${NEW_HOSTNAME:-docker-web-host}"
NEW_USER="${NEW_USER:-anand}"
SERVER_IP="${SERVER_IP:-}"
PASSWORDLESS_SUDO="${PASSWORDLESS_SUDO:-yes}"

echo
echo "=============================================="
echo "  Multi-site Docker Server Initial Setup"
echo "=============================================="
echo
echo "This installs:"
echo "  - Docker Engine, Buildx, and Docker Compose"
echo "  - Shared host Nginx reverse proxy and Certbot"
echo "  - UFW plus Docker-port firewall protection"
echo "  - Fail2Ban and safe SSH key authentication"
echo "  - Multi-key support for every .pub file here"
echo

mapfile -d '' -t PUBLIC_KEYS < <(find "$SCRIPT_DIR" -maxdepth 1 -type f -name '*.pub' -print0 | sort -z)
if (( ${#PUBLIC_KEYS[@]} == 0 )); then
    error "No .pub files were found in $SCRIPT_DIR"
    echo "Copy at least one public key, for example dpm_do.pub, beside this script."
    exit 1
fi

step "Public keys found"
for public_key in "${PUBLIC_KEYS[@]}"; do
    if ! ssh-keygen -lf "$public_key"; then
        error "Invalid SSH public key: $public_key"
        exit 1
    fi
done

echo
echo "Current defaults:"
echo "  Timezone: $TIMEZONE"
echo "  Hostname: $NEW_HOSTNAME"
echo "  Admin user: $NEW_USER"
echo "  Public IP: ${SERVER_IP:-not set (used only in final instructions)}"
echo
read -r -p "Use these values? [Y/n]: " use_defaults

if [[ "$use_defaults" =~ ^[Nn]$ ]]; then
    read -r -p "Timezone [$TIMEZONE]: " input
    TIMEZONE="${input:-$TIMEZONE}"
    read -r -p "Hostname [$NEW_HOSTNAME]: " input
    NEW_HOSTNAME="${input:-$NEW_HOSTNAME}"
    read -r -p "Admin username [$NEW_USER]: " input
    NEW_USER="${input:-$NEW_USER}"
    read -r -p "Public server IP (optional) [$SERVER_IP]: " input
    SERVER_IP="${input:-$SERVER_IP}"
fi

if ! validate_username "$NEW_USER"; then
    error "Invalid Linux username: $NEW_USER"
    exit 1
fi

if [[ ! -e "/usr/share/zoneinfo/$TIMEZONE" ]]; then
    error "Unknown timezone: $TIMEZONE"
    exit 1
fi

export SCRIPT_DIR TIMEZONE NEW_HOSTNAME NEW_USER SERVER_IP PASSWORDLESS_SUDO

echo
echo "Final configuration:"
echo "  Timezone: $TIMEZONE"
echo "  Hostname: $NEW_HOSTNAME"
echo "  Admin user: $NEW_USER"
echo "  SSH keys: ${#PUBLIC_KEYS[@]}"
echo "  Host gateway: Nginx on ports 80 and 443"
echo "  Site containers: unique 127.0.0.1 ports (8081, 8082, ...)"
echo
read -r -p "Type SETUP to begin: " confirmation
if [[ "$confirmation" != "SETUP" ]]; then
    warning "Setup cancelled."
    exit 0
fi

step "1/6 Base server and SSH keys"
bash "$SCRIPT_DIR/setup_server.sh"

step "2/6 Docker Engine and Compose"
bash "$SCRIPT_DIR/setup_docker.sh"

step "3/6 Shared host Nginx and Certbot"
bash "$SCRIPT_DIR/setup_nginx.sh"

step "4/6 Firewall"
bash "$SCRIPT_DIR/setup_ufw.sh"

step "5/6 Fail2Ban"
bash "$SCRIPT_DIR/setup_fail2ban.sh"

step "6/6 Optional SSH hardening"
echo "Before disabling root/password login, open a SECOND terminal on your Mac and test:"
echo
if [[ -n "$SERVER_IP" ]]; then
    echo "  ssh -i ~/.ssh/dpm_do $NEW_USER@$SERVER_IP"
else
    echo "  ssh -i ~/.ssh/dpm_do $NEW_USER@YOUR_SERVER_IP"
fi
echo
warning "Keep this current root session open until that second login succeeds."
read -r -p "After the second login succeeds, type HARDEN. Type SKIP to leave SSH unchanged: " harden_confirmation

if [[ "$harden_confirmation" == "HARDEN" ]]; then
    bash "$SCRIPT_DIR/setup_sshd_config.sh"
else
    warning "SSH hardening skipped. Run later with: sudo NEW_USER=$NEW_USER bash $SCRIPT_DIR/setup_sshd_config.sh"
fi

bash "$SCRIPT_DIR/check_server.sh"

echo
echo "=============================================="
success "Initial Docker host setup is complete."
echo "=============================================="
echo
echo "Website projects belong under: /srv/sites"
echo "Clone and deploy a configured website with:"
echo "  sudo bash $SCRIPT_DIR/manage.sh deploy --config /root/project-configs/example.conf --non-interactive"
echo
echo "Read $SCRIPT_DIR/README.md before starting the first website."
