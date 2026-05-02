#!/bin/bash
# Role: Hub (K3s server, runs all services)
# Installs K3s, creates secrets, deploys all BharatRadar services.

set -euo pipefail

role_hub_collect_config() {
    log_step "Hub Configuration"

    prompt_input "Base domain" "bharat-radar.vellur.in" BASE_DOMAIN

    while ! validate_domain "$BASE_DOMAIN"; do
        log_error "Invalid domain format"
        prompt_input "Base domain" "$BASE_DOMAIN" BASE_DOMAIN
    done

    prompt_input "Receiver latitude" "18.480718" READSB_LAT
    prompt_input "Receiver longitude" "73.898235" READSB_LON

    if command -v timedatectl &>/dev/null; then
        TZ_DEFAULT=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "UTC")
    else
        TZ_DEFAULT="UTC"
    fi
    prompt_input "Timezone" "$TZ_DEFAULT" TIMEZONE

    echo ""
    log_step "GitHub Container Registry (GHCR) Authentication"
    echo ""
    echo "  BharatRadar images are hosted on GitHub Container Registry."
    echo "  You need a GitHub Personal Access Token (PAT) with 'read:packages' scope."
    echo "  Create one at: https://github.com/settings/tokens"
    echo ""

    prompt_input "GitHub username" "" GHCR_USERNAME
    prompt_input "GitHub PAT (read:packages)" "" GHCR_PASSWORD

    while [ -z "$GHCR_USERNAME" ] || [ -z "$GHCR_PASSWORD" ]; do
        log_error "Both username and PAT are required"
        prompt_input "GitHub username" "$GHCR_USERNAME" GHCR_USERNAME
        prompt_input "GitHub PAT (read:packages)" "$GHCR_PASSWORD" GHCR_PASSWORD
    done

    echo ""
    log_step "FRP Tunnel (Optional)"
    echo ""
    echo "  If your hub is behind a NAT/router and needs public access,"
    echo "  set up an FRP tunnel to a cloud server."
    echo "  If your hub has a public IP, skip this."
    echo ""

    if prompt_confirm "Set up FRP tunnel for public access?"; then
        prompt_input "FRP server public IP" "" FRP_SERVER

        while ! validate_ip "$FRP_SERVER"; do
            log_error "Invalid IP address"
            prompt_input "FRP server public IP" "$FRP_SERVER" FRP_SERVER
        done

        prompt_input "FRP authentication token" "" FRP_TOKEN

        while [ -z "$FRP_TOKEN" ]; do
            log_error "Token cannot be empty"
            prompt_input "FRP authentication token" "" FRP_TOKEN
        done

        FRP_ENABLED=true
    else
        FRP_ENABLED=false
        FRP_SERVER=""
        FRP_TOKEN=""
        log_info "No FRP tunnel. Services accessible on local network only."
    fi

    echo ""
    log_step "Configuration Summary"
    echo -e "  Domain:    ${CYAN}${BASE_DOMAIN}${NC}"
    echo -e "  Lat/Lon:   ${CYAN}${READSB_LAT}, ${READSB_LON}${NC}"
    echo -e "  Timezone:  ${CYAN}${TIMEZONE}${NC}"
    echo -e "  GHCR User: ${CYAN}${GHCR_USERNAME}${NC}"
    if [ "$FRP_ENABLED" = true ]; then
        echo -e "  FRP:       ${CYAN}${FRP_SERVER}:7000${NC}"
    else
        echo -e "  FRP:       ${CYAN}disabled${NC}"
    fi
    echo ""

    if ! prompt_confirm "Proceed with Hub setup?"; then
        log_info "Installation cancelled."
        exit 0
    fi
}

role_hub_install_k3s() {
    log_step "Installing K3s Server"

    if command -v k3s &>/dev/null && kubectl cluster-info &>/dev/null 2>&1; then
        log_info "K3s already installed and running"
        return 0
    fi

    K3S_TOKEN=$(generate_token)
    export K3S_TOKEN

    curl -sfL https://get.k3s.io | sh -

    log_info "Waiting for K3s to be ready..."
    for i in $(seq 1 60); do
        if kubectl cluster-info &>/dev/null 2>&1; then
            log_success "K3s server is ready"
            return 0
        fi
        sleep 2
    done

    log_error "K3s failed to become ready"
    exit 1
}

role_hub_create_secrets() {
    log_step "Creating Kubernetes Secrets"

    kubectl create namespace bharatradar --dry-run=client -o yaml | kubectl apply -f -

    # GHCR secret
    kubectl create secret docker-registry ghcr-secret \
        --docker-server=ghcr.io \
        --docker-username="$GHCR_USERNAME" \
        --docker-password="$GHCR_PASSWORD" \
        -n bharatradar \
        --dry-run=client -o yaml | kubectl apply -f -

    log_success "GHCR secret created"

    # TLS secret (self-signed placeholder)
    if ! kubectl get secret adsblol-tls -n bharatradar &>/dev/null; then
        openssl req -x509 -nodes -days 365 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
            -keyout /tmp/tls.key -out /tmp/tls.crt \
            -subj "/CN=${BASE_DOMAIN}" 2>/dev/null

        kubectl create secret tls adsblol-tls \
            --cert=/tmp/tls.crt --key=/tmp/tls.key \
            -n bharatradar 2>/dev/null || true

        rm -f /tmp/tls.crt /tmp/tls.key
        log_warn "Self-signed TLS certificate created (placeholder)"
    fi

    # Rclone secret (placeholder for history service)
    if ! kubectl get secret adsblol-rclone -n bharatradar &>/dev/null; then
        echo "[placeholder]" | kubectl create secret generic adsblol-rclone \
            --from-file=rclone.conf=/dev/stdin \
            -n bharatradar --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true
        log_warn "Rclone secret created with placeholder"
    fi
}

role_hub_deploy_services() {
    log_step "Deploying BharatRadar Services"

    source "${SCRIPT_DIR}/helpers/templating.sh"

    # Generate API salt
    API_SALT=$(openssl rand -hex 64)

    # Initialize overlay
    templating_init

    # Generate templated manifests
    templating_generate_kustomization \
        "${SCRIPT_DIR}/../manifests/default" \
        "$BASE_DOMAIN" "$READSB_LAT" "$READSB_LON" "$TIMEZONE" \
        "${FRP_SERVER:-}" "$API_SALT" "${FRP_TOKEN:-}"

    # Install kustomize if needed
    if ! command -v kustomize &>/dev/null; then
        log_info "Installing kustomize..."
        curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
        mv kustomize /usr/local/bin/
    fi

    # Apply shared resources first
    kubectl apply -f "${OVERLAY_DIR}/resources.yaml" -n bharatradar 2>/dev/null || true

    # Deploy components in dependency order
    local components=("redis" "api" "mlat" "mlat-map" "ingest" "hub" "external" "reapi" "planes" "history" "website" "haproxy")

    for component in "${components[@]}"; do
        local manifest_dir="${SCRIPT_DIR}/../manifests/default/${component}/default"
        if [ -d "$manifest_dir" ]; then
            log_info "Deploying ${component}..."
            if kustomize build "$manifest_dir" 2>/dev/null | kubectl apply -f - -n bharatradar 2>/dev/null; then
                log_success "${component} deployed"
            else
                log_warn "Failed to deploy ${component} (will retry in fallback)"
            fi
        fi
    done

    # Apply runtime patches
    if [ -n "${FRP_SERVER:-}" ]; then
        log_info "Configuring ingest to connect to FRP server..."
        kubectl set env deployment/ingest-readsb \
            READSB_NET_CONNECTOR="${FRP_SERVER},30004,beast_in" \
            -n bharatradar 2>/dev/null || true
    fi

    # Apply planes env patch
    kubectl set env deployment/planes-readsb \
        READSB_LAT="${READSB_LAT}" \
        READSB_LON="${READSB_LON}" \
        TZ="${TIMEZONE}" \
        -n bharatradar 2>/dev/null || true

    # Apply API env patch
    kubectl set env deployment/api-api \
        MY_DOMAIN="my.${BASE_DOMAIN}" \
        -n bharatradar 2>/dev/null || true

    # Apply API salt ConfigMap
    kubectl create configmap api-salts \
        --from-literal="ADSBLOL_API_SALT_MY=${API_SALT}" \
        -n bharatradar \
        --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true

    log_success "All services deployed"

    # Install FRP client if enabled
    if [ "$FRP_ENABLED" = true ]; then
        role_hub_setup_frpc
    fi
}

role_hub_setup_frpc() {
    log_step "Setting up FRP Client"

    local arch
    arch=$(detect_arch)

    if command -v frpc &>/dev/null; then
        log_info "frpc already installed, updating config..."
    else
        log_info "Downloading frpc v${FRP_VERSION}..."
        local frp_url="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_${arch}.tar.gz"
        wget -q "$frp_url" -O /tmp/frp.tar.gz
        tar xzf /tmp/frp.tar.gz -C /tmp
        cp "/tmp/frp_${FRP_VERSION}_linux_${arch}/frpc" /usr/local/bin/frpc
        chmod +x /usr/local/bin/frpc
        rm -rf /tmp/frp_*
    fi

    local domain_list=""
    local subdomains=("map" "mlat" "history" "api" "my" "feed" "ws")
    for sub in "${subdomains[@]}"; do
        domain_list+="    \"${sub}.${BASE_DOMAIN}\",
"
    done

    cat > /etc/frpc.toml <<EOF
serverAddr = "${FRP_SERVER}"
serverPort = 7000

auth.method = "token"
auth.token = "${FRP_TOKEN}"

[[proxies]]
name = "web-ui"
type = "http"
localIP = "127.0.0.1"
localPort = 80
customDomains = [
${domain_list}    "${BASE_DOMAIN}"
]

[[proxies]]
name = "feed-beast-30004"
type = "tcp"
localIP = "127.0.0.1"
localPort = 30004
remotePort = 30004

[[proxies]]
name = "feed-beast-30005"
type = "tcp"
localIP = "127.0.0.1"
localPort = 30005
remotePort = 30005

[[proxies]]
name = "feed-mlat-31090"
type = "tcp"
localIP = "127.0.0.1"
localPort = 31090
remotePort = 31090
EOF

    cat > /etc/systemd/system/frpc.service <<EOF
[Unit]
Description=FRP Client (BharatRadar Hub)
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
EOF

    systemctl daemon-reload
    systemctl enable frpc
    systemctl restart frpc

    sleep 3

    if systemctl is-active --quiet frpc; then
        log_success "FRP client started"
    else
        log_warn "FRP client may still be connecting. Check: journalctl -u frpc -f"
    fi
}

role_hub_save_config() {
    log_step "Saving Configuration"

    mkdir -p /etc/bharatradar

    cat > /etc/bharatradar/config.env <<EOF
# BharatRadar Hub Configuration
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Version: 2.0.0

ROLE=hub
BASE_DOMAIN=${BASE_DOMAIN}
READSB_LAT=${READSB_LAT}
READSB_LON=${READSB_LON}
TIMEZONE=${TIMEZONE}
GHCR_USERNAME=${GHCR_USERNAME}
FRP_ENABLED=${FRP_ENABLED}
FRP_SERVER=${FRP_SERVER:-}
K3S_TOKEN=${K3S_TOKEN:-}
EOF

    chmod 600 /etc/bharatradar/config.env
    log_success "Configuration saved to /etc/bharatradar/config.env"
}

role_hub_post_install() {
    local local_ip
    local_ip=$(hostname -I | awk '{print $1}')

    echo ""
    echo -e "${GREEN}================================================================${NC}"
    echo -e "${GREEN}        Hub Setup Complete!${NC}"
    echo -e "${GREEN}================================================================${NC}"
    echo ""
    echo -e "  ${CYAN}URLs:${NC}"
    echo "    Map:       https://map.${BASE_DOMAIN}"
    echo "    MLAT Map:  https://mlat.${BASE_DOMAIN}"
    echo "    API:       https://api.${BASE_DOMAIN}"
    echo "    My Map:    https://my.${BASE_DOMAIN}"
    echo "    History:   https://history.${BASE_DOMAIN}"
    echo ""
    if [ "$FRP_ENABLED" = true ]; then
        echo -e "  ${CYAN}FRP Tunnel:${NC} ${FRP_SERVER}:7000"
    else
        echo -e "  ${CYAN}Local Access:${NC} http://${local_ip}"
    fi
    echo ""
    echo -e "  ${CYAN}To add an aggregator node, run on another machine:${NC}"
    echo "    curl -Ls https://raw.githubusercontent.com/ragavellur/infra/main/scripts/bharatradar-install | sudo bash"
    echo "    Select: Aggregator"
    echo "    Hub IP: ${local_ip}"
    echo "    K3s Token: ${K3S_TOKEN}"
    echo ""
    echo -e "  ${CYAN}Useful commands:${NC}"
    echo "    kubectl get pods -n bharatradar"
    echo "    sudo bharatradar-install status"
    echo ""
    echo -e "${GREEN}================================================================${NC}"
}

role_hub_run() {
    require_root

    # Load existing config if present
    if [ -f /etc/bharatradar/config.env ]; then
        source /etc/bharatradar/config.env
        BASE_DOMAIN="${BASE_DOMAIN:-}"
        READSB_LAT="${READSB_LAT:-}"
        READSB_LON="${READSB_LON:-}"
    fi

    role_hub_collect_config
    role_hub_install_k3s
    role_hub_create_secrets
    role_hub_deploy_services
    role_hub_save_config
    role_hub_post_install
}
