#!/bin/bash
# Helper functions for installation scripts

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "\n${CYAN}>>> $1${NC}"
}

# Validation functions
validate_domain() {
    local domain="$1"
    if [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?\.[a-zA-Z]{2,}$ ]]; then
        return 0
    else
        return 1
    fi
}

validate_ip() {
    local ip="$1"
    if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 0
    else
        return 1
    fi
}

validate_latitude() {
    local lat="$1"
    if (( $(echo "$lat >= -90 && $lat <= 90" | bc -l 2>/dev/null) )); then
        return 0
    else
        return 1
    fi
}

validate_longitude() {
    local lon="$1"
    if (( $(echo "$lon >= -180 && $lon <= 180" | bc -l 2>/dev/null) )); then
        return 0
    else
        return 1
    fi
}

# Input functions
# All reads from /dev/tty to work when script is piped (curl | bash)

prompt_input() {
    local prompt_msg="$1"
    local default_value="$2"
    local result_var="$3"
    local input

    if [ -n "$default_value" ]; then
        read -rp "${prompt_msg} [${default_value}]: " input < /dev/tty
        eval "$result_var=\"${input:-$default_value}\""
    else
        read -rp "${prompt_msg}: " input < /dev/tty
        eval "$result_var=\"$input\""
    fi
}

prompt_confirm() {
    local prompt_msg="$1"
    local default_value="${2:-y}"
    local response

    if [ "$default_value" = "y" ]; then
        read -rp "${prompt_msg} [Y/n]: " response < /dev/tty
        response=${response:-y}
    else
        read -rp "${prompt_msg} [y/N]: " response < /dev/tty
        response=${response:-n}
    fi

    [[ "$response" =~ ^[Yy]$ ]]
}

prompt_select() {
    local prompt_msg="$1"
    local options=("${@:2:$(( $# - 3 ))}")
    local result_var="${@: -1}"
    local i=1
    local choice

    echo "$prompt_msg"
    for option in "${options[@]}"; do
        echo "  ${i}) ${option}"
        i=$((i + 1))
    done

    while true; do
        read -rp "Select [1-${#options[@]}]: " choice < /dev/tty
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#options[@]}" ]; then
            eval "$result_var=\"${options[$((choice - 1))]}\""
            return 0
        else
            echo "Invalid selection. Please enter a number between 1 and ${#options[@]}."
        fi
    done
}

# Requirement checks
require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "This script must be run as root. Use 'sudo'."
        exit 1
    fi
}

require_command() {
    local cmd="$1"
    if ! command -v "$cmd" &>/dev/null; then
        log_error "Required command not found: $cmd"
        return 1
    fi
    return 0
}

detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l)  echo "arm" ;;
        *)       echo "$arch" ;;
    esac
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID"
    else
        echo "unknown"
    fi
}

# Token generation
generate_token() {
    openssl rand -hex 32
}

generate_secret() {
    openssl rand -base64 32 | tr -d '/+='
}
