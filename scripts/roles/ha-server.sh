#!/bin/bash
# Role: HA Hub (Second K3s server, joins existing cluster)
# Installs K3s server with shared PostgreSQL datastore and optional keepalived.

set -euo pipefail

role_ha_server_collect_config() {
    log_step "HA Hub Configuration"

    echo ""
    echo "  This machine will be a second K3s server in your cluster."
    echo "  It shares the same PostgreSQL datastore as the Primary Hub."
    echo "  If the Primary Hub fails, this server keeps the cluster running."
    echo ""

    # DB connection string
    prompt_input "PostgreSQL connection string (from Shared Services)" "" DB_CONNECTION_STRING

    while ! validate_pg_connstring "$DB_CONNECTION_STRING"; do
        log_error "Invalid format. Expected: postgres://user:pass@host:port/dbname"
        prompt_input "PostgreSQL connection string" "$DB_CONNECTION_STRING" DB_CONNECTION_STRING
    done

    # Cluster token from primary
    prompt_input "K3s cluster token (from Primary Hub)" "" K3S_CLUSTER_TOKEN

    while [ -z "$K3S_CLUSTER_TOKEN" ]; do
        log_error "Token cannot be empty"
        echo ""
        log_info "Get the token from your Primary Hub with:"
        echo "  ssh user@<hub-ip> 'sudo cat /var/lib/rancher/k3s/server/node-token'"
        echo ""
        prompt_input "K3s cluster token" "" K3S_CLUSTER_TOKEN
    done

    # Primary Hub IP (for keepalived awareness)
    prompt_input "Primary Hub IP" "" PRIMARY_HUB_IP

    while ! validate_ip "$PRIMARY_HUB_IP"; do
        log_error "Invalid IP address"
        prompt_input "Primary Hub IP" "$PRIMARY_HUB_IP" PRIMARY_HUB_IP
    done

    # Domain
    prompt_input "Base domain (from Primary Hub)" "bharat-radar.vellur.in" BASE_DOMAIN

    while ! validate_domain "$BASE_DOMAIN"; do
        log_error "Invalid domain format"
        prompt_input "Base domain" "$BASE_DOMAIN" BASE_DOMAIN
    done

    # Keepalived
    echo ""
    if prompt_confirm "Set up Keepalived VIP for automatic failover?"; then
        KEEPALIVED_ENABLED=true
        # Source keepalived config
        source "${SCRIPT_DIR}/roles/keepalived.sh"
        keepalived_collect_config
    else
        KEEPALIVED_ENABLED=false
        KEEPALIVED_VIP=""
    fi

    echo ""
    log_step "Configuration Summary"
    echo -e "  Role:        ${CYAN}HA Server (K3s)${NC}"
    echo -e "  Primary Hub: ${CYAN}${PRIMARY_HUB_IP}${NC}"
    echo -e "  Domain:      ${CYAN}${BASE_DOMAIN}${NC}"
    if [ "$KEEPALIVED_ENABLED" = true ]; then
        echo -e "  VIP:         ${CYAN}${KEEPALIVED_VIP}${NC}"
    fi
    echo ""

    if ! prompt_confirm "Proceed with HA Hub setup?"; then
        log_info "Installation cancelled."
        exit 0
    fi
}

role_ha_server_install_k3s() {
    log_step "Installing K3s Server (HA Mode)"

    if command -v k3s &>/dev/null && kubectl cluster-info &>/dev/null 2>&1; then
        log_info "K3s already installed and running"
        return 0
    fi

    export K3S_TOKEN="$K3S_CLUSTER_TOKEN"
    export K3S_DATASTORE_ENDPOINT="$DB_CONNECTION_STRING"

    log_info "Installing K3s with external datastore..."
    curl -sfL https://get.k3s.io | sh -s - server

    log_info "Waiting for K3s to join cluster..."
    for i in $(seq 1 60); do
        if kubectl cluster-info &>/dev/null 2>&1; then
            log_success "K3s server joined cluster"
            return 0
        fi
        sleep 2
    done

    log_error "K3s failed to join cluster"
    log_info "Check logs: journalctl -u k3s -f"
    exit 1
}

role_ha_server_setup_keepalived() {
    if [ "$KEEPALIVED_ENABLED" = true ]; then
        keepalived_install
        keepalived_configure
    fi
}

role_ha_server_save_config() {
    log_step "Saving Configuration"

    mkdir -p /etc/bharatradar

    cat > /etc/bharatradar/config.env <<EOF
# BharatRadar HA Hub Configuration
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Version: 3.0.2

ROLE=ha-server
BASE_DOMAIN=${BASE_DOMAIN}
DB_CONNECTION_STRING=${DB_CONNECTION_STRING}
K3S_CLUSTER_TOKEN=${K3S_CLUSTER_TOKEN}
PRIMARY_HUB_IP=${PRIMARY_HUB_IP}
KEEPALIVED_ENABLED=${KEEPALIVED_ENABLED}
KEEPALIVED_VIP=${KEEPALIVED_VIP:-}
KEEPALIVED_PRIORITY=${KEEPALIVED_PRIORITY:-90}
EOF

    chmod 600 /etc/bharatradar/config.env
    log_success "Configuration saved to /etc/bharatradar/config.env"
}

role_ha_server_post_install() {
    echo ""
    echo -e "${GREEN}================================================================${NC}"
    echo -e "${GREEN}        HA Hub Setup Complete!${NC}"
    echo -e "${GREEN}================================================================${NC}"
    echo ""
    echo -e "  ${CYAN}This server has joined the cluster.${NC}"
    echo -e "  ${CYAN}Primary Hub:${NC} ${PRIMARY_HUB_IP}"
    if [ "$KEEPALIVED_ENABLED" = true ]; then
        echo -e "  ${CYAN}VIP:${NC} ${KEEPALIVED_VIP} (this server is BACKUP)"
    fi
    echo ""
    echo -e "  ${CYAN}To verify from the Primary Hub:${NC}"
    echo "    kubectl get nodes"
    echo "    kubectl get pods -n bharatradar -o wide"
    echo ""
    echo -e "  ${CYAN}Useful commands:${NC}"
    echo "    sudo systemctl status k3s"
    echo "    sudo journalctl -u k3s -f"
    if [ "$KEEPALIVED_ENABLED" = true ]; then
        echo "    sudo systemctl status keepalived"
        echo "    ip addr show | grep ${KEEPALIVED_VIP:-VIP}"
    fi
    echo ""
    echo -e "${GREEN}================================================================${NC}"
}

role_ha_server_run() {
    require_root

    # Load existing config if present
    if [ -f /etc/bharatradar/config.env ]; then
        source /etc/bharatradar/config.env
        BASE_DOMAIN="${BASE_DOMAIN:-}"
        DB_CONNECTION_STRING="${DB_CONNECTION_STRING:-}"
        K3S_CLUSTER_TOKEN="${K3S_CLUSTER_TOKEN:-}"
        PRIMARY_HUB_IP="${PRIMARY_HUB_IP:-}"
    fi

    role_ha_server_collect_config
    role_ha_server_install_k3s
    role_ha_server_setup_keepalived
    role_ha_server_save_config
    role_ha_server_post_install
}
