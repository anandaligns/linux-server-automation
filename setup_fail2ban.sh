#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

require_root
require_ubuntu

step "Configuring Fail2Ban for SSH and the host Nginx gateway"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y fail2ban

install -d -m 0755 /etc/fail2ban/jail.d
cat > /etc/fail2ban/jail.d/docker-web-host.local <<'EOF'
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
banaction = ufw

[sshd]
enabled = true
backend = systemd
mode = normal
port = ssh
maxretry = 5

[nginx-http-auth]
enabled = true
port = http,https
logpath = /var/log/nginx/error.log
maxretry = 5

[nginx-botsearch]
enabled = true
port = http,https
logpath = /var/log/nginx/access.log
maxretry = 8
EOF

systemctl enable --now fail2ban
fail2ban-client -t
fail2ban-client reload
fail2ban-client status
success "Fail2Ban is protecting SSH and host Nginx logs."
