#!/bin/bash
# Role: Keepalived VIP Setup
# Configures a floating IP that moves between K3s servers for HA.
# Sourced by hub.sh and ha-server.sh, not run standalone.

set -euo pipefail

KEEPALIVED_VIP="${KEEPALIVED_VIP:-192.168.200.150}"
KEEPALIVED_STATE="${KEEPALIVED_STATE:-MASTER}"
KEEPALIVED_PRIORITY="${KEEPALIVED_PRIORITY:-100}"

keepalived_collect_config() {
    log_step "Keepalived VIP Configuration"

    echo ""
    echo "  Keepalived provides a floating Virtual IP (VIP) that"
    echo "  automatically moves to the surviving server if one fails."
    echo "  This ensures FRP and users always reach the active server."
    echo ""

    # Detect local IP for smart VIP suggestion
    local detected_ip
    detected_ip=$(detect_local_ip || echo "192.168.200.1")
    local suggested_vip
    suggested_vip=$(echo "$detected_ip" | sed 's/\.[0-9]*$/.150/')

    prompt_input "Virtual IP (VIP)" "$suggested_vip" KEEPALIVED_VIP

    while ! validate_ip "$KEEPALIVED_VIP"; do
        log_error "Invalid IP address"
        prompt_input "Virtual IP (VIP)" "$KEEPALIVED_VIP" KEEPALIVED_VIP
    done

    # Check if this node is likely the primary (lower IP = primary)
    local local_ip
    local_ip=$(detect_local_ip || echo "0.0.0.0")

    echo ""
    log_info "Detected local IP: ${local_ip}"
    echo ""

    if prompt_confirm "Is this the PRIMARY server (highest priority)?"; then
        KEEPALIVED_STATE="MASTER"
        KEEPALIVED_PRIORITY=100
    else
        KEEPALIVED_STATE="BACKUP"
        KEEPALIVED_PRIORITY=90
    fi
}

keepalived_install() {
    log_step "Installing Keepalived"

    if command -v keepalived &>/dev/null; then
        log_info "Keepalived already installed"
        return 0
    fi

    local os
    os=$(detect_os)

    case "$os" in
        debian|ubuntu|raspbian)
            apt-get install -y -qq keepalived
            ;;
        fedora|centos|rhel)
            dnf install -y -qq keepalived
            ;;
    esac

    log_success "Keepalived installed"
}

keepalived_configure() {
    log_step "Configuring Keepalived"

    local iface
    iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
    if [ -z "$iface" ]; then
        iface="eth0"
    fi

    cat > /etc/keepalived/keepalived.conf <<EOF
vrrp_instance K3S_HA {
    state ${KEEPALIVED_STATE}
    interface ${iface}
    virtual_router_id 51
    priority ${KEEPALIVED_PRIORITY}
    advert_int 1

    authentication {
        auth_type PASS
        auth_pass $(echo "$KEEPALIVED_VIP" | md5sum | cut -c1-8)
    }

    virtual_ipaddress {
        ${KEEPALIVED_VIP}
    }
}
EOF

    systemctl enable keepalived
    systemctl restart keepalived

    sleep 2

    if systemctl is-active --quiet keepalived; then
        log_success "Keepalived configured and running"
        log_info "VIP: ${KEEPALIVED_VIP} (state: ${KEEPALIVED_STATE}, priority: ${KEEPALIVED_PRIORITY})"
    else
        log_warn "Keepalived may still be starting. Check: systemctl status keepalived"
    fi
}
