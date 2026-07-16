#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

require_root
require_ubuntu

NEW_USER="${NEW_USER:-anand}"
if ! validate_username "$NEW_USER" || ! id "$NEW_USER" >/dev/null 2>&1; then
    error "Deployment user is missing or invalid: $NEW_USER"
    exit 1
fi

step "Installing Docker from Docker's official Ubuntu repository"
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y ca-certificates curl gnupg jq
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# shellcheck disable=SC1091
. /etc/os-release
ARCHITECTURE="$(dpkg --print-architecture)"
CODENAME="${UBUNTU_CODENAME:-$VERSION_CODENAME}"

cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $CODENAME
Components: stable
Architectures: $ARCHITECTURE
Signed-By: /etc/apt/keyrings/docker.asc
EOF

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

step "Configuring Docker log rotation and live restore"
install -d -m 0755 /etc/docker

if [[ -s /etc/docker/daemon.json ]]; then
    if ! jq empty /etc/docker/daemon.json >/dev/null 2>&1; then
        error "/etc/docker/daemon.json exists but is not valid JSON. Fix it before continuing."
        exit 1
    fi
    backup_file /etc/docker/daemon.json
    temp_daemon_json="$(mktemp)"
    jq '. + {
        "log-driver": "json-file",
        "log-opts": {"max-size": "10m", "max-file": "5"},
        "live-restore": true
    }' /etc/docker/daemon.json > "$temp_daemon_json"
    install -m 0644 "$temp_daemon_json" /etc/docker/daemon.json
    rm -f "$temp_daemon_json"
else
    cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "5"
  },
  "live-restore": true
}
EOF
fi

systemctl enable --now docker
systemctl restart docker
usermod -aG docker "$NEW_USER"

install -d -m 0750 -o "$NEW_USER" -g "$NEW_USER" /srv/sites
install -d -m 0750 -o "$NEW_USER" -g "$NEW_USER" /srv/backups

docker info >/dev/null
docker compose version
success "Docker Engine, Buildx, and Compose are installed."
warning "Membership in the docker group is root-equivalent. Only trusted administrators should be added."
info "$NEW_USER must sign out and back in before docker commands work without sudo."
