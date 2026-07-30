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
SWAP_SIZE_MB="${SWAP_SIZE_MB:-2048}"
SWAP_FILE="${SWAP_FILE:-/swapfile}"

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

step "Ensuring swap exists for container builds"
# Website images are built on the server itself. A Next.js or similar production
# build exhausts a 1 GB droplet and the OOM killer takes out the build, so make
# sure some swap is present before any deployment runs.
if [[ -n "$(swapon --show --noheadings 2>/dev/null)" ]]; then
    info "Swap is already configured; leaving it unchanged."
elif [[ -e "$SWAP_FILE" ]]; then
    warning "$SWAP_FILE exists but is not active. Leaving it untouched."
else
    total_memory_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
    available_disk_kb="$(df --output=avail -k / | tail -1 | tr -d ' ')"
    required_disk_kb=$(( SWAP_SIZE_MB * 1024 + 2 * 1024 * 1024 ))

    if (( total_memory_kb >= 4 * 1024 * 1024 )); then
        info "Host has $(( total_memory_kb / 1024 )) MB RAM; skipping swap creation."
    elif (( available_disk_kb < required_disk_kb )); then
        warning "Not enough free disk for a ${SWAP_SIZE_MB} MB swapfile. Skipping."
        warning "Container builds may fail on a host with $(( total_memory_kb / 1024 )) MB RAM."
    else
        info "Creating a ${SWAP_SIZE_MB} MB swapfile at $SWAP_FILE"
        if ! fallocate -l "${SWAP_SIZE_MB}M" "$SWAP_FILE" 2>/dev/null; then
            dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$SWAP_SIZE_MB" status=none
        fi
        chmod 0600 "$SWAP_FILE"
        mkswap "$SWAP_FILE" >/dev/null
        swapon "$SWAP_FILE"

        if ! grep -qE "^${SWAP_FILE}[[:space:]]" /etc/fstab; then
            backup_file /etc/fstab
            printf '%s none swap sw 0 0\n' "$SWAP_FILE" >> /etc/fstab
        fi

        printf 'vm.swappiness=10\n' > /etc/sysctl.d/99-swappiness.conf
        sysctl -q -w vm.swappiness=10
        success "Swap is active: $(swapon --show=NAME,SIZE --noheadings | tr -s ' ')"
    fi
fi

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

systemctl enable --now ssh
success "Base server is ready for Docker installation."
