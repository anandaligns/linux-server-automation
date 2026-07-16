#!/usr/bin/env bash

set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info() { echo -e "${BLUE}INFO:${NC} $*"; }
success() { echo -e "${GREEN}OK:${NC} $*"; }
warning() { echo -e "${YELLOW}WARNING:${NC} $*"; }
error() { echo -e "${RED}ERROR:${NC} $*" >&2; }
step() { echo -e "\n${CYAN}==> $*${NC}"; }

require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        error "Run this script as root or with sudo."
        exit 1
    fi
}

require_ubuntu() {
    if [[ ! -r /etc/os-release ]]; then
        error "Cannot identify the operating system."
        exit 1
    fi

    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" != "ubuntu" ]]; then
        error "This bundle supports Ubuntu only. Detected: ${PRETTY_NAME:-unknown}."
        exit 1
    fi
}

validate_username() {
    local username="$1"
    [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

backup_file() {
    local path="$1"
    if [[ -e "$path" ]]; then
        cp -a "$path" "${path}.backup.$(date +%Y%m%d_%H%M%S)"
    fi
}
