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
PASSWORDLESS_SUDO="${PASSWORDLESS_SUDO:-yes}"

if ! validate_username "$NEW_USER"; then
    error "Invalid Linux username: $NEW_USER"
    exit 1
fi

step "Updating Ubuntu and installing base tools"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
apt-get install -y \
    ca-certificates \
    curl \
    fail2ban \
    git \
    gnupg \
    htop \
    jq \
    openssh-server \
    rsync \
    snapd \
    sudo \
    ufw \
    unattended-upgrades \
    unzip \
    vim

step "Configuring timezone and hostname"
timedatectl set-timezone "$TIMEZONE"
hostnamectl set-hostname "$NEW_HOSTNAME"

if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
    sed -i -E "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1 $NEW_HOSTNAME/" /etc/hosts
else
    echo "127.0.1.1 $NEW_HOSTNAME" >> /etc/hosts
fi

step "Creating deployment administrator"
if id "$NEW_USER" >/dev/null 2>&1; then
    info "User already exists: $NEW_USER"
else
    adduser --disabled-password --gecos "" "$NEW_USER"
fi
usermod -aG sudo "$NEW_USER"

if [[ "$PASSWORDLESS_SUDO" =~ ^([Yy][Ee][Ss]|[Yy]|1|true)$ ]]; then
    printf '%s ALL=(ALL:ALL) NOPASSWD:ALL\n' "$NEW_USER" > "/etc/sudoers.d/90-$NEW_USER"
    chmod 0440 "/etc/sudoers.d/90-$NEW_USER"
    visudo -cf "/etc/sudoers.d/90-$NEW_USER"
else
    warning "Passwordless sudo was not enabled. The account currently has no password."
fi

NEW_USER="$NEW_USER" KEY_DIR="$SCRIPT_DIR" bash "$SCRIPT_DIR/sync_ssh_keys.sh"

step "Creating deployment directories"
install -d -m 0750 -o "$NEW_USER" -g "$NEW_USER" /srv/sites
install -d -m 0750 -o "$NEW_USER" -g "$NEW_USER" /srv/backups

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

systemctl enable --now ssh
success "Base server is ready for Docker installation."
