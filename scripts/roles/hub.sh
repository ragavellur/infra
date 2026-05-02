#!/bin/bash
# Role: Primary Hub (First K3s server, runs all services)
# Installs K3s server with optional external PostgreSQL datastore,
# creates secrets, deploys all BharatRadar services.

set -euo pipefail

role_hub_collect_config() {
    log_step "Primary Hub Configuration"

    echo ""
    echo "  This is the first K3s server in your cluster."
    echo "  It runs all BharatRadar services and serves as the control plane."
    echo ""

    prompt_input "Base domain" "bharat-radar.vellur.in" BASE_DOMAIN

    while ! validate_domain "$BASE_DOMAIN"; do
        log_error "Invalid domain format"
        prompt_input "Base domain" "$BASE_DOMAIN" BASE_DOMAIN
    done

    prompt_input "Receiver latitude" "18.480718" READSB_LAT
    prompt_input "Receiver longitude" "73.898235" READSB_LON

    TZ_DEFAULT="Etc/UTC"
    prompt_input "Timezone" "$TZ_DEFAULT" TIMEZONE

    echo ""
    log_step "External Redis Configuration"
    echo ""
    echo "  The API service connects to Redis on the shared services host."
    echo "  Enter the Redis server details."
    echo ""

    prompt_input "Redis host IP" "${REDIS_HOST:-}" REDIS_HOST
    while [ -z "$REDIS_HOST" ] || ! validate_ip "$REDIS_HOST"; do
        log_error "Invalid IP address"
        prompt_input "Redis host IP" "${REDIS_HOST:-}" REDIS_HOST
    done

    prompt_input "Redis port" "${REDIS_PORT:-6379}" REDIS_PORT
    prompt_input "Redis password" "${REDIS_PASSWORD:-}" REDIS_PASSWORD
    while [ -z "$REDIS_PASSWORD" ]; do
        log_error "Password cannot be empty"
        prompt_input "Redis password" "" REDIS_PASSWORD
    done

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
    log_step "Datastore Configuration"
    echo ""
    echo "  K3s stores cluster state in a database. Choose one:"
    echo ""
    echo "  1) Embedded etcd (simple, single server)"
    echo "  2) External PostgreSQL (required for HA multi-server)"
    echo ""

    local ds_choice
    prompt_select "Datastore type" \
        "Embedded etcd" \
        "External PostgreSQL" ds_choice

    if [ "$ds_choice" = "Embedded etcd" ]; then
        USE_EXTERNAL_DB=false
        DB_CONNECTION_STRING=""
        unset K3S_DATASTORE_ENDPOINT 2>/dev/null || true
        log_info "Using embedded etcd datastore"
    else
        USE_EXTERNAL_DB=true
        echo ""
        log_info "Enter your PostgreSQL server details:"
        collect_pg_config "DB"
        log_info "Using external PostgreSQL: ${DB_HOST}:${DB_PORT}/${DB_DBNAME}"
    fi

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
    log_step "Keepalived VIP (Optional)"
    echo ""
    echo "  Keepalived provides a floating IP for automatic failover"
    echo "  when you add a second K3s server later."
    echo ""

    if prompt_confirm "Set up Keepalived VIP now?"; then
        KEEPALIVED_ENABLED=true
        source "${SCRIPT_DIR}/roles/keepalived.sh"
        keepalived_collect_config
    else
        KEEPALIVED_ENABLED=false
        KEEPALIVED_VIP=""
    fi

    echo ""
    log_step "Configuration Summary"
    echo -e "  Domain:    ${CYAN}${BASE_DOMAIN}${NC}"
    echo -e "  Lat/Lon:   ${CYAN}${READSB_LAT}, ${READSB_LON}${NC}"
    echo -e "  Timezone:  ${CYAN}${TIMEZONE}${NC}"
    echo -e "  ${CYAN}GHCR User: ${CYAN}${GHCR_USERNAME}${NC}"
    echo -e "  ${CYAN}Redis:     ${CYAN}${REDIS_HOST}:${REDIS_PORT}${NC}"
    if [ "$USE_EXTERNAL_DB" = true ]; then
        echo -e "  Datastore: ${CYAN}External PostgreSQL${NC}"
    else
        echo -e "  Datastore: ${CYAN}Embedded etcd${NC}"
    fi
    if [ "$FRP_ENABLED" = true ]; then
        echo -e "  FRP:       ${CYAN}${FRP_SERVER}:7000${NC}"
    else
        echo -e "  FRP:       ${CYAN}disabled${NC}"
    fi
    if [ "$KEEPALIVED_ENABLED" = true ]; then
        echo -e "  VIP:       ${CYAN}${KEEPALIVED_VIP}${NC}"
    fi
    echo ""

    if ! prompt_confirm "Proceed with Primary Hub setup?"; then
        log_info "Installation cancelled."
        exit 0
    fi
}

role_hub_install_k3s() {
    log_step "Installing K3s Server"

    local k3s_installed=false
    if command -v k3s &>/dev/null; then
        k3s_installed=true
    fi

    if [ "$k3s_installed" = true ] && kubectl cluster-info &>/dev/null 2>&1; then
        log_info "K3s already installed and running"
        return 0
    fi

    # If K3s is installed but not running, diagnose the failure
    if [ "$k3s_installed" = true ]; then
        local svc_status
        svc_status=$(systemctl is-active k3s 2>/dev/null || echo "inactive")
        if [ "$svc_status" = "activating" ] || [ "$svc_status" = "failed" ]; then
            local journal_output
            journal_output=$(journalctl -u k3s.service --no-pager -n 20 2>/dev/null || true)
            if echo "$journal_output" | grep -q "bootstrap data already found and encrypted with different token"; then
                log_warn "K3s service is failing: stale bootstrap data in PostgreSQL."
                log_info "The database contains data from a previous installation with a different token."
                echo ""
                if prompt_confirm "Clear stale data and restart K3s?"; then
                    local db_host db_dbname
                    db_host=$(echo "$DB_CONNECTION_STRING" | sed "s|postgres://||" | cut -d"@" -f2 | cut -d":" -f1)
                    db_dbname=$(echo "$DB_CONNECTION_STRING" | sed "s|postgres://||" | cut -d"@" -f2 | cut -d"/" -f2)
                    log_info "Run this command on the PostgreSQL host (${db_host}):"
                    echo ""
                    echo -e "  ${CYAN}sudo -u postgres psql -c 'DROP TABLE kine;' ${db_dbname}${NC}"
                    echo ""
                    read -rp "Press Enter after clearing the database..." < /dev/tty
                    systemctl stop k3s 2>/dev/null || true
                    sleep 2
                    log_info "Restarting K3s..."
                    systemctl restart k3s
                    log_info "Waiting for K3s to be ready..."
                    for i in $(seq 1 60); do
                        if kubectl cluster-info &>/dev/null 2>&1; then
                            log_success "K3s server is ready"
                            return 0
                        fi
                        sleep 2
                    done
                    log_error "K3s still not ready after restart"
                    log_info "Check logs: journalctl -u k3s.service -e"
                    exit 1
                else
                    log_error "K3s cannot start with stale data"
                    exit 1
                fi
            fi
        fi
    fi

    K3S_TOKEN=$(generate_token)
    export K3S_TOKEN

    local k3s_args=()

    if [ "$USE_EXTERNAL_DB" = true ]; then
        export K3S_DATASTORE_ENDPOINT="$DB_CONNECTION_STRING"
        k3s_args=("--datastore-endpoint=${DB_CONNECTION_STRING}")
        log_info "Installing K3s with external datastore..."
    else
        k3s_args=("--cluster-init")
        log_info "Installing K3s with embedded etcd..."
    fi

    curl -sfL https://get.k3s.io | sh -s - server "${k3s_args[@]}"

    log_info "Waiting for K3s to be ready..."
    for i in $(seq 1 60); do
        if kubectl cluster-info &>/dev/null 2>&1; then
            log_success "K3s server is ready"
            return 0
        fi

        # Check for bootstrap token mismatch every 10 iterations
        if [ $(( i % 10 )) -eq 0 ] && [ "$USE_EXTERNAL_DB" = true ]; then
            local journal_output
            journal_output=$(journalctl -u k3s.service --no-pager -n 5 2>/dev/null || true)
            if echo "$journal_output" | grep -q "bootstrap data already found and encrypted with different token"; then
                log_warn "K3s bootstrap failed: stale data in PostgreSQL."
                log_info "The database contains data from a previous installation with a different token."
                echo ""
                if prompt_confirm "Clear stale data and retry?"; then
                    local db_host db_dbname
                    db_host=$(echo "$DB_CONNECTION_STRING" | sed "s|postgres://||" | cut -d"@" -f2 | cut -d":" -f1)
                    db_dbname=$(echo "$DB_CONNECTION_STRING" | sed "s|postgres://||" | cut -d"@" -f2 | cut -d"/" -f2)
                    log_info "Run this on the PostgreSQL host (${db_host}):"
                    echo ""
                    echo -e "  ${CYAN}sudo -u postgres psql -c 'DROP TABLE kine;' ${db_dbname}${NC}"
                    echo ""
                    read -rp "Press Enter after clearing the database..." < /dev/tty
                    systemctl stop k3s 2>/dev/null || true
                    sleep 2
                    log_info "Restarting K3s..."
                    systemctl restart k3s
                    # Reset loop counter
                    i=0
                    continue
                else
                    log_error "K3s cannot start with stale data"
                    exit 1
                fi
            fi
        fi

        sleep 2
    done

    log_error "K3s failed to become ready"
    log_info "Check logs: journalctl -u k3s.service -e"
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

    # Rclone secret (dummy config - users should replace with real remote config)
    if ! kubectl get secret adsblol-rclone -n bharatradar &>/dev/null; then
        kubectl create secret generic adsblol-rclone \
            --from-literal=rclone.conf="[adsblol]
type = s3
provider = Other
access_key_id = YOUR_ACCESS_KEY
secret_access_key = YOUR_SECRET_KEY
endpoint = https://your-s3-endpoint.example.com" \
            -n bharatradar --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true
        log_warn "Rclone secret created with dummy config (update with real S3 credentials)"
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

    # Helper: deploy a component and strip ServiceMonitor resources
    deploy_component() {
        local component="$1"
        local manifest_dir="${SCRIPT_DIR}/../manifests/default/${component}/default"
        if [ ! -d "$manifest_dir" ]; then
            return 0
        fi
        log_info "Deploying ${component}..."
        kustomize build "$manifest_dir" 2>/dev/null \
            | awk 'BEGIN{RS="---"; ORS="---"} !/kind: ServiceMonitor/ && /kind:/' \
            | kubectl apply -f - -n bharatradar 2>&1 || true
    }

    # Helper: wait for a deployment to be ready
    wait_for_deployment() {
        local name="$1"
        log_info "Waiting for ${name} to be ready..."
        kubectl rollout status "deployment/${name}" -n bharatradar --timeout=120s 2>/dev/null || true
    }

    # Phase 1: Core services (no external dependencies)
    deploy_component "api"
    deploy_component "website"

    # Phase 2: ADS-B data sources (must exist before haproxy can resolve them)
    deploy_component "ingest"
    deploy_component "hub"
    deploy_component "external"
    deploy_component "reapi"
    deploy_component "mlat"
    deploy_component "planes"

    # Phase 3: Wait for data source deployments to be ready
    wait_for_deployment "ingest-readsb"
    wait_for_deployment "hub-readsb"
    wait_for_deployment "external-readsb"
    wait_for_deployment "reapi-readsb"
    wait_for_deployment "planes-readsb"
    wait_for_deployment "mlat-mlat-server"
    wait_for_deployment "api-api"

    # Give CoreDNS time to register services
    log_info "Waiting for CoreDNS to register services..."
    sleep 10

    # Phase 4: Dependent services (require data sources to be resolvable)
    deploy_component "mlat-map"
    deploy_component "history"
    deploy_component "haproxy"

    log_success "All services deployed"

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

    # Apply API env patch (Redis URL + domain)
    kubectl set env deployment/api-api \
        MY_DOMAIN="my.${BASE_DOMAIN}" \
        ADSBLOL_REDIS_HOST="redis://:${REDIS_PASSWORD}@${REDIS_HOST}:${REDIS_PORT}" \
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

    # Install keepalived if enabled
    if [ "$KEEPALIVED_ENABLED" = true ]; then
        keepalived_install
        keepalived_configure
    fi
}

role_hub_setup_frpc() {
    log_step "Setting up FRP Client"

    local local_ip
    local_ip=$(hostname -I | awk '{print $1}')

    # If keepalived is enabled, point FRP to VIP instead of local
    local frp_local_ip="127.0.0.1"
    if [ "$KEEPALIVED_ENABLED" = true ]; then
        frp_local_ip="${KEEPALIVED_VIP}"
        log_info "FRP will use VIP: ${KEEPALIVED_VIP}"
    fi

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
localIP = "${frp_local_ip}"
localPort = 80
customDomains = [
${domain_list}    "${BASE_DOMAIN}"
]

[[proxies]]
name = "feed-beast-30004"
type = "tcp"
localIP = "${frp_local_ip}"
localPort = 30004
remotePort = 30004

[[proxies]]
name = "feed-beast-30005"
type = "tcp"
localIP = "${frp_local_ip}"
localPort = 30005
remotePort = 30005

[[proxies]]
name = "feed-mlat-31090"
type = "tcp"
localIP = "${frp_local_ip}"
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
# BharatRadar Primary Hub Configuration
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Version: 3.4.3

ROLE=hub
BASE_DOMAIN="${BASE_DOMAIN}"
READSB_LAT="${READSB_LAT}"
READSB_LON="${READSB_LON}"
TIMEZONE="${TIMEZONE}"
GHCR_USERNAME="${GHCR_USERNAME}"
REDIS_HOST="${REDIS_HOST}"
REDIS_PORT="${REDIS_PORT:-6379}"
USE_EXTERNAL_DB="${USE_EXTERNAL_DB}"
DB_HOST="${DB_HOST:-}"
DB_PORT="${DB_PORT:-5432}"
DB_DBNAME="${DB_DBNAME:-k3s}"
DB_DBUSER="${DB_DBUSER:-k3s}"
DB_CONNECTION_STRING="${DB_CONNECTION_STRING:-}"
FRP_ENABLED="${FRP_ENABLED}"
FRP_SERVER="${FRP_SERVER:-}"
K3S_TOKEN="${K3S_TOKEN:-}"
KEEPALIVED_ENABLED="${KEEPALIVED_ENABLED}"
KEEPALIVED_VIP="${KEEPALIVED_VIP:-}"
KEEPALIVED_PRIORITY=100
EOF

    chmod 600 /etc/bharatradar/config.env
    log_success "Configuration saved to /etc/bharatradar/config.env"
}

role_hub_post_install() {
    local local_ip
    local_ip=$(hostname -I | awk '{print $1}')

    echo ""
    echo -e "${GREEN}================================================================${NC}"
    echo -e "${GREEN}        Primary Hub Setup Complete!${NC}"
    echo -e "${GREEN}================================================================${NC}"
    echo ""
    echo -e "  ${CYAN}URLs:${NC}"
    echo "    Map:       https://map.${BASE_DOMAIN}"
    echo "    MLAT Map:  https://mlat.${BASE_DOMAIN}"
    echo "    API:       https://api.${BASE_DOMAIN}"
    echo "    My Map:    https://my.${BASE_DOMAIN}"
    echo "    History:   https://history.${BASE_DOMAIN}"
    echo ""
    if [ "$KEEPALIVED_ENABLED" = true ]; then
        echo -e "  ${CYAN}VIP:${NC} ${KEEPALIVED_VIP} (this server is MASTER)"
    fi
    if [ "$FRP_ENABLED" = true ]; then
        echo -e "  ${CYAN}FRP Tunnel:${NC} ${FRP_SERVER}:7000"
    else
        echo -e "  ${CYAN}Local Access:${NC} http://${local_ip}"
    fi
    echo ""
    echo -e "  ${CYAN}To add more nodes later:${NC}"
    echo "    HA Server:   curl -Ls https://raw.githubusercontent.com/ragavellur/infra/main/scripts/bharatradar-install | sudo bash -s -- ha-server"
    echo "    Worker Node: curl -Ls https://raw.githubusercontent.com/ragavellur/infra/main/scripts/bharatradar-install | sudo bash -s -- worker"
    echo ""
    echo -e "  ${CYAN}Cluster token (save this!):${NC} ${K3S_TOKEN}"
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
        REDIS_HOST="${REDIS_HOST:-}"
        REDIS_PORT="${REDIS_PORT:-6379}"
        DB_HOST="${DB_HOST:-}"
        DB_PORT="${DB_PORT:-5432}"
        DB_DBNAME="${DB_DBNAME:-k3s}"
        DB_DBUSER="${DB_DBUSER:-k3s}"
    fi

    role_hub_collect_config
    role_hub_install_k3s
    setup_kubectl
    install_bharatradar_cli
    role_hub_create_secrets
    role_hub_deploy_services
    role_hub_save_config
    role_hub_post_install
}
