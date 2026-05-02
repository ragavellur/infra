#!/bin/bash
# Role: Worker Node (K3s agent, joins existing cluster)
# Simple agent node that runs pods but has no control plane or DB.

set -euo pipefail

role_worker_collect_config() {
    log_step "Worker Node Configuration"

    echo ""
    echo "  This machine will join your cluster as a K3s agent (worker)."
    echo "  It runs pods scheduled by the K3s servers but does not"
    echo "  participate in the control plane or datastore."
    echo ""

    prompt_input "Primary Hub IP" "" HUB_IP

    while ! validate_ip "$HUB_IP"; do
        log_error "Invalid IP address"
        prompt_input "Primary Hub IP" "$HUB_IP" HUB_IP
    done

    prompt_input "K3s join token" "" K3S_TOKEN

    while [ -z "$K3S_TOKEN" ]; do
        log_error "Token cannot be empty"
        echo ""
        log_info "Get the token from your Hub with:"
        echo "  ssh user@${HUB_IP} 'sudo cat /var/lib/rancher/k3s/server/node-token'"
        echo ""
        prompt_input "K3s join token" "" K3S_TOKEN
    done

    prompt_input "Base domain" "bharat-radar.vellur.in" BASE_DOMAIN

    while ! validate_domain "$BASE_DOMAIN"; do
        log_error "Invalid domain format"
        prompt_input "Base domain" "$BASE_DOMAIN" BASE_DOMAIN
    done

    echo ""
    log_step "Configuration Summary"
    echo -e "  Hub IP:    ${CYAN}${HUB_IP}${NC}"
    echo -e "  Domain:    ${CYAN}${BASE_DOMAIN}${NC}"
    echo ""

    if ! prompt_confirm "Proceed with Worker Node setup?"; then
        log_info "Installation cancelled."
        exit 0
    fi
}

role_worker_install_k3s_agent() {
    log_step "Installing K3s Agent"

    if command -v k3s &>/dev/null; then
        log_error "K3s is already installed on this machine."
        log_info "To rejoin, run: sudo k3s-agent-uninstall.sh"
        exit 1
    fi

    export K3S_URL="https://${HUB_IP}:6443"
    export K3S_TOKEN

    log_info "Connecting to K3s server at ${HUB_IP}:6443..."
    curl -sfL https://get.k3s.io | sh -

    log_info "Waiting for agent to register..."
    for i in $(seq 1 30); do
        if systemctl is-active --quiet k3s-agent 2>/dev/null; then
            log_success "K3s agent is running and registered"
            return 0
        fi
        sleep 2
    done

    log_warn "Agent may still be registering. Check: systemctl status k3s-agent"
}

role_worker_save_config() {
    log_step "Saving Configuration"

    mkdir -p /etc/bharatradar

    cat > /etc/bharatradar/config.env <<EOF
# BharatRadar Worker Node Configuration
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Version: 3.0.5

ROLE=worker
HUB_IP=${HUB_IP}
K3S_TOKEN=${K3S_TOKEN}
BASE_DOMAIN=${BASE_DOMAIN}
EOF

    chmod 600 /etc/bharatradar/config.env
    log_success "Configuration saved to /etc/bharatradar/config.env"
}

role_worker_post_install() {
    echo ""
    echo -e "${GREEN}================================================================${NC}"
    echo -e "${GREEN}        Worker Node Setup Complete!${NC}"
    echo -e "${GREEN}================================================================${NC}"
    echo ""
    echo -e "  ${CYAN}This node has joined the cluster at:${NC} ${HUB_IP}"
    echo ""
    echo -e "  ${CYAN}To verify, run on the Hub:${NC}"
    echo "    ssh user@${HUB_IP} 'sudo kubectl get nodes'"
    echo ""
    echo -e "  ${CYAN}Note: kubectl only works on K3s server nodes.${NC}"
    echo "  This node is an agent and does not serve the Kubernetes API."
    echo ""
    echo -e "  ${CYAN}Local commands:${NC}"
    echo "    sudo systemctl status k3s-agent"
    echo "    sudo journalctl -u k3s-agent -f"
    echo "    sudo bharatradar-install status"
    echo ""
    echo -e "${GREEN}================================================================${NC}"
}

role_worker_run() {
    require_root

    if [ -f /etc/bharatradar/config.env ]; then
        source /etc/bharatradar/config.env
        HUB_IP="${HUB_IP:-}"
        K3S_TOKEN="${K3S_TOKEN:-}"
        BASE_DOMAIN="${BASE_DOMAIN:-}"
    fi

    role_worker_collect_config
    role_worker_install_k3s_agent
    role_worker_save_config
    role_worker_post_install
}
