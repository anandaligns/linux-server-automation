#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

require_root

NEW_USER="${NEW_USER:-anand}"
if ! validate_username "$NEW_USER" || ! id "$NEW_USER" >/dev/null 2>&1; then
    error "Deployment user is missing or invalid: $NEW_USER"
    exit 1
fi

USER_HOME="$(getent passwd "$NEW_USER" | cut -d: -f6)"
AUTHORIZED_KEYS="$USER_HOME/.ssh/authorized_keys"
DROP_IN_DIR="/etc/ssh/sshd_config.d"
DROP_IN="$DROP_IN_DIR/00-docker-web-host-hardening.conf"

if [[ ! -s "$AUTHORIZED_KEYS" ]]; then
    error "No authorized SSH keys are installed for $NEW_USER."
    exit 1
fi

if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
    error "/etc/ssh/sshd_config does not include /etc/ssh/sshd_config.d/*.conf."
    error "SSH was not changed. Review the server configuration manually."
    exit 1
fi

step "Applying key-only SSH hardening"
install -d -m 0755 "$DROP_IN_DIR"
backup_file "$DROP_IN"

rollback_copy=""
if [[ -e "$DROP_IN" ]]; then
    rollback_copy="$(mktemp)"
    cp -a "$DROP_IN" "$rollback_copy"
fi

cat > "$DROP_IN" <<EOF
# Managed by bash_scripts/setup_sshd_config.sh
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin no
PermitEmptyPasswords no
AllowUsers $NEW_USER
MaxAuthTries 5
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
EOF

if ! sshd -t; then
    error "The generated SSH configuration is invalid."
    if [[ -n "$rollback_copy" ]]; then
        cp -a "$rollback_copy" "$DROP_IN"
    else
        rm -f "$DROP_IN"
    fi
    if [[ -n "$rollback_copy" ]]; then
        rm -f "$rollback_copy"
    fi
    exit 1
fi

if [[ -n "$rollback_copy" ]]; then
    rm -f "$rollback_copy"
fi

systemctl reload ssh

effective_config="$(sshd -T -C user="$NEW_USER",host="$(hostname -f 2>/dev/null || hostname)",addr=127.0.0.1)"
grep -E '^(pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication|permitrootlogin|allowusers) ' <<< "$effective_config"

success "SSH now allows only public-key access for $NEW_USER."
warning "Do not close the current session until a fresh SSH login succeeds."
