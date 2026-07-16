#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

require_root

NEW_USER="${NEW_USER:-anand}"
KEY_DIR="${KEY_DIR:-$SCRIPT_DIR}"

if ! validate_username "$NEW_USER"; then
    error "Invalid Linux username: $NEW_USER"
    exit 1
fi

if ! id "$NEW_USER" >/dev/null 2>&1; then
    error "User does not exist: $NEW_USER"
    exit 1
fi

USER_HOME="$(getent passwd "$NEW_USER" | cut -d: -f6)"
SSH_DIR="$USER_HOME/.ssh"
AUTHORIZED_KEYS="$SSH_DIR/authorized_keys"

install -d -m 0700 -o "$NEW_USER" -g "$NEW_USER" "$SSH_DIR"
touch "$AUTHORIZED_KEYS"
chown "$NEW_USER:$NEW_USER" "$AUTHORIZED_KEYS"
chmod 0600 "$AUTHORIZED_KEYS"
backup_file "$AUTHORIZED_KEYS"

mapfile -d '' -t PUBLIC_KEYS < <(find "$KEY_DIR" -maxdepth 1 -type f -name '*.pub' -print0 | sort -z)
if (( ${#PUBLIC_KEYS[@]} == 0 )); then
    error "No .pub files found in $KEY_DIR"
    exit 1
fi

added=0
existing=0

for public_key in "${PUBLIC_KEYS[@]}"; do
    if ! ssh-keygen -lf "$public_key" >/dev/null 2>&1; then
        error "Invalid public key file: $public_key"
        exit 1
    fi

    while IFS= read -r key_line || [[ -n "$key_line" ]]; do
        [[ -z "$key_line" || "$key_line" == \#* ]] && continue
        if grep -Fqx -- "$key_line" "$AUTHORIZED_KEYS"; then
            ((existing += 1))
        else
            printf '%s\n' "$key_line" >> "$AUTHORIZED_KEYS"
            ((added += 1))
        fi
    done < "$public_key"
done

chown "$NEW_USER:$NEW_USER" "$AUTHORIZED_KEYS"
chmod 0600 "$AUTHORIZED_KEYS"

success "SSH keys synchronized for $NEW_USER: $added added, $existing already present."
ssh-keygen -lf "$AUTHORIZED_KEYS" || true
