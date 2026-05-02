#!/bin/bash
# Uninstall and cleanup functions for BharatRadar

set -euo pipefail

# Uninstall K3s server
uninstall_k3s_server() {
    log_step "Uninstalling K3s Server"

    if prompt_confirm "This will remove K3s and all workloads. Continue?"; then
        if command -v k3s &>/dev/null; then
            log_info "Running k3s-uninstall.sh..."
            /usr/local/bin/k3s-uninstall.sh 2>/dev/null || {
                log_warn "k3s-uninstall.sh failed, cleaning manually..."
                systemctl stop k3s 2>/dev/null || true
                rm -rf /usr/local/bin/k3s /usr/local/bin/k3s-uninstall.sh
                rm -rf /etc/rancher/k3s
                rm -rf /var/lib/rancher/k3s
                rm -rf /var/lib/cni
            }
            log_success "K3s server removed"
        else
            log_info "K3s server is not installed"
        fi
    fi
}

# Uninstall K3s agent
uninstall_k3s_agent() {
    log_step "Uninstalling K3s Agent"

    if prompt_confirm "This will remove K3s agent. Continue?"; then
        if command -v k3s &>/dev/null; then
            log_info "Running k3s-agent-uninstall.sh..."
            /usr/local/bin/k3s-agent-uninstall.sh 2>/dev/null || {
                log_warn "k3s-agent-uninstall.sh failed, cleaning manually..."
                systemctl stop k3s-agent 2>/dev/null || true
                rm -rf /usr/local/bin/k3s /usr/local/bin/k3s-agent-uninstall.sh
                rm -rf /etc/rancher/k3s
                rm -rf /var/lib/rancher/k3s
            }
            log_success "K3s agent removed"
        else
            log_info "K3s agent is not installed"
        fi
    fi
}

# Uninstall FRP client
uninstall_frpc() {
    log_step "Uninstalling FRP Client"

    if systemctl is-active --quiet frpc 2>/dev/null; then
        systemctl stop frpc 2>/dev/null || true
        systemctl disable frpc 2>/dev/null || true
        rm -f /etc/systemd/system/frpc.service
        systemctl daemon-reload
        log_info "FRP client service removed"
    fi

    if [ -f /usr/local/bin/frpc ]; then
        rm -f /usr/local/bin/frpc
        log_info "FRP client binary removed"
    fi

    if [ -f /etc/frpc.toml ]; then
        rm -f /etc/frpc.toml
        log_info "FRP client config removed"
    fi

    log_success "FRP client uninstalled"
}

# Uninstall FRP server
uninstall_frps() {
    log_step "Uninstalling FRP Server"

    if systemctl is-active --quiet frps 2>/dev/null; then
        systemctl stop frps 2>/dev/null || true
        systemctl disable frps 2>/dev/null || true
        rm -f /etc/systemd/system/frps.service
        systemctl daemon-reload
        log_info "FRP server service removed"
    fi

    if [ -f /usr/local/bin/frps ]; then
        rm -f /usr/local/bin/frps
        log_info "FRP server binary removed"
    fi

    if [ -f /etc/frps.toml ]; then
        rm -f /etc/frps.toml
        log_info "FRP server config removed"
    fi

    log_success "FRP server uninstalled"
}

# Uninstall nginx
uninstall_nginx() {
    log_step "Uninstalling Nginx"

    if prompt_confirm "This will remove nginx and its configuration. Continue?"; then
        local os
        os=$(detect_os)

        case "$os" in
            debian|ubuntu|raspbian)
                apt-get remove -y nginx 2>/dev/null || true
                apt-get autoremove -y 2>/dev/null || true
                ;;
            fedora|centos|rhel)
                dnf remove -y nginx 2>/dev/null || true
                ;;
        esac

        rm -f /etc/nginx/sites-available/adsblol-http
        rm -f /etc/nginx/sites-available/adsblol-ssl
        rm -f /etc/nginx/sites-enabled/adsblol-http
        rm -f /etc/nginx/sites-enabled/adsblol-ssl

        log_success "Nginx uninstalled"
    fi
}

# Uninstall feeder services
uninstall_feeder() {
    log_step "Uninstalling Feeder Services"

    # Stop and remove bharat-feeder
    if systemctl is-active --quiet bharat-feeder 2>/dev/null; then
        systemctl stop bharat-feeder 2>/dev/null || true
        systemctl disable bharat-feeder 2>/dev/null || true
        rm -f /etc/systemd/system/bharat-feeder.service
        systemctl daemon-reload
        log_info "bharat-feeder service removed"
    fi

    # Stop and remove bharat-mlat
    if systemctl is-active --quiet bharat-mlat 2>/dev/null; then
        systemctl stop bharat-mlat 2>/dev/null || true
        systemctl disable bharat-mlat 2>/dev/null || true
        rm -f /etc/systemd/system/bharat-mlat.service
        systemctl daemon-reload
        log_info "bharat-mlat service removed"
    fi

    # Remove UUID file
    if [ -f /etc/bharat-radar-id ]; then
        rm -f /etc/bharat-radar-id
        log_info "UUID file removed"
    fi

    log_success "Feeder services uninstalled"
}

# Remove BharatRadar config directory
uninstall_config() {
    log_step "Removing Configuration"

    if [ -d /etc/bharatradar ]; then
        rm -rf /etc/bharatradar
        log_success "Configuration directory removed"
    else
        log_info "No configuration directory found"
    fi
}

# Remove certbot certificates
uninstall_certbot() {
    log_step "Removing SSL Certificates"

    if prompt_confirm "This will delete Let's Encrypt certificates. Continue?"; then
        if command -v certbot &>/dev/null; then
            log_info "Deleting certificates..."
            certbot delete --non-interactive 2>/dev/null || true
            log_success "Certificates removed"
        fi
    fi
}

# Full uninstall: prompts for what to remove
uninstall_all() {
    local role="${1:-}"

    echo ""
    echo -e "${RED}================================================================${NC}"
    echo -e "${RED}        BharatRadar Uninstall${NC}"
    echo -e "${RED}================================================================${NC}"
    echo ""
    log_warn "This will remove BharatRadar components from this machine."
    echo ""

    if [ -f /etc/bharatradar/config.env ]; then
        source /etc/bharatradar/config.env
        role="${ROLE:-${role}}"
    fi

    case "$role" in
        frp-server)
            uninstall_frps
            uninstall_nginx
            uninstall_certbot
            ;;
        hub)
            uninstall_frpc
            uninstall_k3s_server
            ;;
        aggregator)
            uninstall_k3s_agent
            ;;
        feeder)
            uninstall_feeder
            uninstall_frpc 2>/dev/null || true
            ;;
        *)
            # Unknown role: ask what to remove
            log_info "Unknown role, showing all uninstall options:"
            echo ""

            if prompt_confirm "Remove K3s server?"; then
                uninstall_k3s_server
            fi

            if prompt_confirm "Remove K3s agent?"; then
                uninstall_k3s_agent
            fi

            if prompt_confirm "Remove FRP client?"; then
                uninstall_frpc
            fi

            if prompt_confirm "Remove FRP server?"; then
                uninstall_frps
            fi

            if prompt_confirm "Remove feeder services?"; then
                uninstall_feeder
            fi

            if prompt_confirm "Remove nginx?"; then
                uninstall_nginx
            fi
            ;;
    esac

    if prompt_confirm "Remove BharatRadar configuration files?"; then
        uninstall_config
    fi

    echo ""
    echo -e "${GREEN}================================================================${NC}"
    echo -e "${GREEN}        Uninstall Complete${NC}"
    echo -e "${GREEN}================================================================${NC}"
}
