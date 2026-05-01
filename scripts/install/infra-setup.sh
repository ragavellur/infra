#!/bin/bash
# adsblol Infrastructure - Main Installer Script
# Version: 1.0.0
#
# This script guides users through the complete setup of:
# 1. K3s cluster on Raspberry Pi
# 2. ADS-B/MLAT services
# 3. Optional FRP tunneling (frpc client)
# 4. SSL certificates and domain configuration

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(dirname "$SCRIPT_DIR")"
source "${SCRIPTS_DIR}/helpers/functions.sh"

# Default configuration
BASE_DOMAIN=""
FRP_SERVER_IP=""
FRP_AUTH_TOKEN=""
INSTALL_FRPC=false
READSB_LAT="52.3676"
READSB_LON="4.9041"
K3S_TOKEN=""
TIMEZONE="UTC"

# Subdomains managed by the platform
SUBDOMAINS=("map" "history" "mlat" "api" "feed" "ws")

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --domain DOMAIN         Base domain (e.g., bharat-radar.vellur.in)
  --lat LAT               Receiver latitude (default: 52.3676)
  --lon LON               Receiver longitude (default: 4.9041)
  --timezone TZ           System timezone (default: UTC)
  --frp-server IP         FRP server IP (enables FRPC setup)
  --frp-token TOKEN       FRP authentication token
  --k3s-token TOKEN       K3s cluster token for multi-node
  --help                  Show this help message

Examples:
  # Interactive installation
  sudo $0

  # Automated installation
  sudo $0 --domain bharat-radar.vellur.in --lat 18.48 --lon 73.89

EOF
    exit 0
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --domain)      BASE_DOMAIN="$2"; shift 2 ;;
        --lat)         READSB_LAT="$2"; shift 2 ;;
        --lon)         READSB_LON="$2"; shift 2 ;;
        --timezone)    TIMEZONE="$2"; shift 2 ;;
        --frp-server)  FRP_SERVER_IP="$2"; shift 2 ;;
        --frp-token)   FRP_AUTH_TOKEN="$2"; shift 2 ;;
        --k3s-token)   K3S_TOKEN="$2"; shift 2 ;;
        --help)        usage ;;
        *)             log_error "Unknown option: $1"; usage ;;
    esac
done

banner() {
    echo ""
    echo -e "${CYAN}================================================================${NC}"
    echo -e "${CYAN}        adsblol Infrastructure Installer v1.0.0${NC}"
    echo -e "${CYAN}        ADS-B/MLAT Aggregator Platform${NC}"
    echo -e "${CYAN}================================================================${NC}"
    echo ""
}

collect_config() {
    log_step "Configuration Collection"

    # Base domain
    if [ -z "$BASE_DOMAIN" ]; then
        prompt_input "Enter your base domain" "bharat-radar.vellur.in" BASE_DOMAIN
    fi

    while ! validate_domain "$BASE_DOMAIN"; do
        log_error "Invalid domain format. Use: example.com or sub.example.com"
        prompt_input "Enter your base domain" "$BASE_DOMAIN" BASE_DOMAIN
    done
    log_success "Base domain: $BASE_DOMAIN"

    # Location
    prompt_input "Receiver latitude" "$READSB_LAT" READSB_LAT
    prompt_input "Receiver longitude" "$READSB_LON" READSB_LON

    # Timezone
    if command -v timedatectl &>/dev/null; then
        TIMEZONE=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "UTC")
    fi
    prompt_input "Timezone" "$TIMEZONE" TIMEZONE

    # FRP setup
    if prompt_confirm "Set up FRP tunnel for external access?"; then
        INSTALL_FRPC=true
        if [ -z "$FRP_SERVER_IP" ]; then
            prompt_input "FRP server public IP (AWS EC2)" "" FRP_SERVER_IP
        fi
        while ! validate_ip "$FRP_SERVER_IP"; do
            log_error "Invalid IP address"
            prompt_input "FRP server public IP" "$FRP_SERVER_IP" FRP_SERVER_IP
        done

        if [ -z "$FRP_AUTH_TOKEN" ]; then
            prompt_input "FRP authentication token" "$(generate_token)" FRP_AUTH_TOKEN
        fi
    fi

    # K3s token
    if [ -z "$K3S_TOKEN" ]; then
        prompt_input "K3s cluster token (leave empty for auto-generated)" "" K3S_TOKEN
        if [ -z "$K3S_TOKEN" ]; then
            K3S_TOKEN=$(generate_token)
        fi
    fi

    # Summary
    echo ""
    log_step "Configuration Summary"
    echo -e "  Base Domain:    ${CYAN}$BASE_DOMAIN${NC}"
    echo -e "  Latitude:       ${CYAN}$READSB_LAT${NC}"
    echo -e "  Longitude:      ${CYAN}$READSB_LON${NC}"
    echo -e "  Timezone:       ${CYAN}$TIMEZONE${NC}"
    echo -e "  FRP Tunnel:     ${CYAN}$INSTALL_FRPC${NC}"
    if [ "$INSTALL_FRPC" = true ]; then
        echo -e "  FRP Server:     ${CYAN}$FRP_SERVER_IP${NC}"
    fi
    echo -e "  K3s Token:      ${CYAN}$K3S_TOKEN${NC}"
    echo ""

    if prompt_confirm "Proceed with installation?"; then
        return 0
    else
        log_info "Installation cancelled."
        exit 0
    fi
}

install_dependencies() {
    log_step "Installing Dependencies"

    local os
    os=$(detect_os)

    case "$os" in
        debian|ubuntu|raspbian)
            apt-get update
            apt-get install -y curl wget jq bc openssl kmod
            ;;
        fedora|centos|rhel)
            dnf install -y curl wget jq bc openssl kmod
            ;;
        alpine)
            apk add curl wget jq bc openssl kmod
            ;;
        *)
            log_error "Unsupported OS: $os"
            exit 1
            ;;
    esac

    log_success "Dependencies installed"
}

install_k3s() {
    log_step "Installing K3s"

    if command -v k3s &>/dev/null; then
        log_info "K3s already installed, skipping..."
        return 0
    fi

    export K3S_TOKEN
    curl -sfL https://get.k3s.io | sh -

    # Wait for K3s to be ready
    log_info "Waiting for K3s to be ready..."
    for i in $(seq 1 30); do
        if kubectl cluster-info &>/dev/null; then
            break
        fi
        sleep 2
    done

    log_success "K3s installed successfully"
}

setup_infra_manifests() {
    log_step "Deploying Infrastructure Manifests"

    # Create namespace
    kubectl create namespace adsblol --dry-run=client -o yaml | kubectl apply -f -

    # Apply secrets and configmaps first
    create_secrets

    # Apply all manifests using kustomize
    if command -v kustomize &>/dev/null; then
        kustomize build "${SCRIPTS_DIR}/../manifests/default" 2>/dev/null | kubectl apply -f - -n adsblol || true
    else
        # Apply individual components
        for component in api redis mlat mlat-map haproxy ingest hub external reapi planes; do
            local manifest_dir="${SCRIPTS_DIR}/../manifests/default/${component}/default"
            if [ -d "$manifest_dir" ]; then
                kustomize build "$manifest_dir" 2>/dev/null | kubectl apply -f - -n adsblol || \
                    log_warn "Failed to deploy $component"
            fi
        done
    fi

    log_success "Infrastructure manifests deployed"
}

create_secrets() {
    log_step "Creating Kubernetes Secrets"

    # Create ghcr-secret for private images
    if [ ! -f /root/.docker/config.json ]; then
        kubectl create secret generic ghcr-secret \
            --from-file=.dockerconfigjson=/dev/null \
            --type=kubernetes.io/dockerconfigjson \
            -n adsblol --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true
    fi

    # Create rclone secret (placeholder - user should configure)
    if ! kubectl get secret adsblol-rclone -n adsblol &>/dev/null; then
        kubectl create secret generic adsblol-rclone \
            --from-literal=rclone.conf="[placeholder]\n" \
            -n adsblol --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true
        log_warn "Rclone secret created with placeholder. Configure manually with:"
        log_info "  kubectl create secret generic adsblol-rclone --from-file=rclone.conf=/path/to/rclone.conf -n adsblol"
    fi

    # Create TLS secret (placeholder)
    if ! kubectl get secret adsblol-tls -n adsblol &>/dev/null; then
        openssl req -x509 -nodes -days 365 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
            -keyout /tmp/tls.key -out /tmp/tls.crt \
            -subj "/CN=adsblol.local" 2>/dev/null

        kubectl create secret tls adsblol-tls \
            --cert=/tmp/tls.crt --key=/tmp/tls.key \
            -n adsblol 2>/dev/null || true

        rm -f /tmp/tls.crt /tmp/tls.key
        log_warn "Self-signed TLS certificate created. Replace with Let's Encrypt cert on FRP server."
    fi
}

setup_frpc() {
    if [ "$INSTALL_FRPC" != true ]; then
        return 0
    fi

    log_step "Setting up FRP Client (frpc)"

    local arch
    arch=$(detect_arch)
    local FRPC_VERSION="0.68.1"

    # Download and install frpc
    log_info "Downloading frpc v${FRPC_VERSION}..."
    local frpc_url="https://github.com/fatedier/frp/releases/download/v${FRPC_VERSION}/frp_${FRPC_VERSION}_linux_${arch}.tar.gz"
    wget -q "$frpc_url" -O /tmp/frp.tar.gz
    tar xzf /tmp/frp.tar.gz -C /tmp
    cp "/tmp/frp_${FRPC_VERSION}_linux_${arch}/frpc" /usr/local/bin/frpc
    chmod +x /usr/local/bin/frpc
    rm -rf /tmp/frp_*

    # Generate frpc.toml
    log_info "Generating frpc configuration..."
    local frpc_config="/etc/frpc.toml"
    cat > "$frpc_config" <<FRPC_EOF
serverAddr = "${FRP_SERVER_IP}"
serverPort = 7000

auth.method = "token"
auth.token = "${FRP_AUTH_TOKEN}"

[[proxies]]
name = "web-ui"
type = "http"
localIP = "127.0.0.1"
localPort = 80
customDomains = [
    "${BASE_DOMAIN}",
    "map.${BASE_DOMAIN}",
    "history.${BASE_DOMAIN}",
    "mlat.${BASE_DOMAIN}",
    "api.${BASE_DOMAIN}",
    "feed.${BASE_DOMAIN}",
    "ws.${BASE_DOMAIN}"
]

[[proxies]]
name = "feed-beast-30005"
type = "tcp"
localIP = "127.0.0.1"
localPort = 30005
remotePort = 30005

[[proxies]]
name = "feed-beast-30004"
type = "tcp"
localIP = "127.0.0.1"
localPort = 30004
remotePort = 30004

[[proxies]]
name = "feed-mlat-31090"
type = "tcp"
localIP = "127.0.0.1"
localPort = 31090
remotePort = 31090
FRPC_EOF

    # Create systemd service
    cat > /etc/systemd/system/frpc.service <<SERVICE_EOF
[Unit]
Description=FRP Client (adsblol)
After=network.target k3s.service
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/frpc -c /etc/frpc.toml
Restart=always
RestartSec=5
User=root
Group=root
StandardOutput=journal
StandardError=journal
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SERVICE_EOF

    systemctl daemon-reload
    systemctl enable frpc
    systemctl start frpc

    log_success "FRP client configured and started"
    log_info "FRP dashboard: http://${FRP_SERVER_IP}:7500"
}

save_config() {
    log_step "Saving Configuration"

    local config_file="/etc/adsblol/config.env"
    mkdir -p /etc/adsblol

    cat > "$config_file" <<EOF
# adsblol Infrastructure Configuration
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Version: 1.0.0

BASE_DOMAIN=${BASE_DOMAIN}
READSB_LAT=${READSB_LAT}
READSB_LON=${READSB_LON}
TIMEZONE=${TIMEZONE}
K3S_TOKEN=${K3S_TOKEN}
INSTALL_FRPC=${INSTALL_FRPC}
FRP_SERVER_IP=${FRP_SERVER_IP:-}
FRP_AUTH_TOKEN=${FRP_AUTH_TOKEN:-}

# Subdomains
SUBDOMAINS="${SUBDOMAINS[*]}"
EOF

    chmod 600 "$config_file"
    log_success "Configuration saved to ${config_file}"
}

post_install_info() {
    echo ""
    log_step "Installation Complete!"
    echo -e "${GREEN}================================================================${NC}"
    echo ""
    echo -e "  Your adsblol infrastructure is now running!"
    echo ""
    echo -e "  ${CYAN}Services:${NC}"
    echo "  - Map:       https://map.${BASE_DOMAIN}"
    echo "  - MLAT Map:  https://mlat.${BASE_DOMAIN}"
    echo "  - API:       https://api.${BASE_DOMAIN}"
    echo "  - Feed:      https://feed.${BASE_DOMAIN}"
    echo "  - History:   https://history.${BASE_DOMAIN}"
    echo ""
    echo -e "  ${CYAN}Useful Commands:${NC}"
    echo "  kubectl get pods -n adsblol           # Check pod status"
    echo "  kubectl logs -n adsblol -l app=planes  # View plane logs"
    echo "  sudo systemctl status frpc             # Check FRP status"
    echo ""

    if [ "$INSTALL_FRPC" = true ]; then
        echo -e "  ${CYAN}Next Steps on FRP Server (AWS):${NC}"
        echo "  1. Run: scripts/frp/setup-frps.sh --domain ${BASE_DOMAIN} --frp-token ${FRP_AUTH_TOKEN}"
        echo "  2. Configure nginx reverse proxy"
        echo "  3. Run Certbot for SSL certificates"
        echo ""
    fi

    echo -e "  ${CYAN}Configuration saved to: /etc/adsblol/config.env${NC}"
    echo -e "${GREEN}================================================================${NC}"
}

main() {
    banner
    require_root

    collect_config
    install_dependencies
    install_k3s
    setup_infra_manifests
    setup_frpc
    save_config
    post_install_info
}

main "$@"
