#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

require_root
require_ubuntu

step "Configuring the host firewall"
apt-get update
apt-get install -y ufw iptables

ufw default deny incoming
ufw default allow outgoing
ufw limit 22/tcp comment 'SSH rate limit'
ufw allow 80/tcp comment 'Shared Nginx HTTP'
ufw allow 443/tcp comment 'Shared Nginx HTTPS'
ufw logging medium
ufw --force enable

step "Blocking direct external access to Docker-published ports"
cat > /usr/local/sbin/apply-docker-host-firewall <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

external_interface="$(ip -4 route show default | awk '/default/ {print $5; exit}')"
if [[ -z "$external_interface" ]]; then
    echo "Could not determine the external interface" >&2
    exit 1
fi

if ! iptables -nL DOCKER-USER >/dev/null 2>&1; then
    echo "DOCKER-USER is not available yet; Docker may not be running" >&2
    exit 1
fi

iptables -N DPM-DOCKER-FIREWALL 2>/dev/null || true
iptables -F DPM-DOCKER-FIREWALL
iptables -A DPM-DOCKER-FIREWALL -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A DPM-DOCKER-FIREWALL -i "$external_interface" -j DROP
iptables -A DPM-DOCKER-FIREWALL -j RETURN
iptables -C DOCKER-USER -j DPM-DOCKER-FIREWALL 2>/dev/null || \
    iptables -I DOCKER-USER 1 -j DPM-DOCKER-FIREWALL

if ip6tables -nL DOCKER-USER >/dev/null 2>&1; then
    ip6tables -N DPM-DOCKER-FIREWALL 2>/dev/null || true
    ip6tables -F DPM-DOCKER-FIREWALL
    ip6tables -A DPM-DOCKER-FIREWALL -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ip6tables -A DPM-DOCKER-FIREWALL -i "$external_interface" -j DROP
    ip6tables -A DPM-DOCKER-FIREWALL -j RETURN
    ip6tables -C DOCKER-USER -j DPM-DOCKER-FIREWALL 2>/dev/null || \
        ip6tables -I DOCKER-USER 1 -j DPM-DOCKER-FIREWALL
fi
EOF
chmod 0755 /usr/local/sbin/apply-docker-host-firewall

cat > /etc/systemd/system/docker-host-firewall.service <<'EOF'
[Unit]
Description=Protect Docker published ports from direct external access
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/apply-docker-host-firewall
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now docker-host-firewall.service

ufw status verbose
success "Only SSH, HTTP, and HTTPS are exposed by the host firewall."
info "Website ingress ports must still bind to 127.0.0.1, for example 127.0.0.1:8081:80."
