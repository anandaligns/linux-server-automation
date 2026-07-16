#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

usage() {
    cat <<EOF
Usage:
  sudo bash $SCRIPT_DIR/manage.sh bootstrap
  sudo bash $SCRIPT_DIR/manage.sh deploy [--config /path/project.conf] [--non-interactive]
  sudo bash $SCRIPT_DIR/manage.sh sync-keys
  sudo bash $SCRIPT_DIR/manage.sh status

Run without a command to use the interactive menu.
EOF
}

command_name="${1:-}"
if [[ -n "$command_name" ]]; then
    shift
fi

if [[ -z "$command_name" ]]; then
    echo
    echo "DPM Docker Server Manager"
    echo "  1) Prepare a new Ubuntu server"
    echo "  2) Deploy or update a website project"
    echo "  3) Synchronize server-login public keys"
    echo "  4) Check server status"
    echo "  5) Exit"
    echo
    read -r -p "Choose an option [1-5]: " selection
    case "$selection" in
        1) command_name="bootstrap" ;;
        2) command_name="deploy" ;;
        3) command_name="sync-keys" ;;
        4) command_name="status" ;;
        5) exit 0 ;;
        *) error "Invalid selection."; exit 1 ;;
    esac
fi

case "$command_name" in
    bootstrap)
        exec bash "$SCRIPT_DIR/master_setup.sh" "$@"
        ;;
    deploy)
        exec bash "$SCRIPT_DIR/deploy_project.sh" "$@"
        ;;
    sync-keys)
        exec bash "$SCRIPT_DIR/sync_ssh_keys.sh" "$@"
        ;;
    status)
        exec bash "$SCRIPT_DIR/check_server.sh" "$@"
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        error "Unknown command: $command_name"
        usage
        exit 1
        ;;
esac
