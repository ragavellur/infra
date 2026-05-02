#!/bin/bash
# Role: DB Standby (PostgreSQL streaming replica)
# Sets up a read-only PostgreSQL replica for HA database failover.

set -euo pipefail

role_db_standby_collect_config() {
    log_step "DB Standby Configuration"

    echo ""
    echo "  This sets up a PostgreSQL streaming replica on this machine."
    echo "  It continuously replicates data from the primary DB server."
    echo "  If the primary fails, this standby can be promoted to primary."
    echo ""

    prompt_input "Primary DB server IP" "" PRIMARY_DB_IP

    while ! validate_ip "$PRIMARY_DB_IP"; do
        log_error "Invalid IP address"
        prompt_input "Primary DB server IP" "$PRIMARY_DB_IP" PRIMARY_DB_IP
    done

    prompt_input "Primary DB server SSH username" "bharatradar" PRIMARY_DB_USER

    prompt_input "Primary DB password (from Shared Services)" "" PRIMARY_DB_PASSWORD

    while [ -z "$PRIMARY_DB_PASSWORD" ]; do
        log_error "Password cannot be empty"
        prompt_input "Primary DB password" "" PRIMARY_DB_PASSWORD
    done

    # Detect local IP
    local detected_ip
    detected_ip=$(detect_local_ip || echo "192.168.200.1")
    prompt_input "This machine's IP" "$detected_ip" STANDBY_IP

    while ! validate_ip "$STANDBY_IP"; do
        log_error "Invalid IP address"
        prompt_input "This machine's IP" "$STANDBY_IP" STANDBY_IP
    done

    echo ""
    log_step "Configuration Summary"
    echo -e "  Primary DB:  ${CYAN}${PRIMARY_DB_IP}${NC}"
    echo -e "  Standby IP:  ${CYAN}${STANDBY_IP}${NC}"
    echo ""

    if ! prompt_confirm "Proceed with DB Standby setup?"; then
        log_info "Installation cancelled."
        exit 0
    fi
}

role_db_standby_install_postgresql() {
    log_step "Installing PostgreSQL"

    if command -v psql &>/dev/null; then
        log_info "PostgreSQL already installed"
        return 0
    fi

    local os
    os=$(detect_os)

    case "$os" in
        debian|ubuntu|raspbian)
            apt-get update -qq
            apt-get install -y -qq postgresql postgresql-client
            ;;
    esac

    log_success "PostgreSQL installed"
}

role_db_standby_configure_replication() {
    log_step "Configuring Streaming Replication"

    # Stop standby PostgreSQL
    systemctl stop postgresql 2>/dev/null || true

    # Configure primary for replication (via SSH)
    log_info "Configuring primary for replication..."

    source "${SCRIPT_DIR}/helpers/ssh-helpers.sh"
    SSH_USER="${PRIMARY_DB_USER}"
    SSH_CMD="ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no"

    # Create replication user on primary
    ssh_remote "$PRIMARY_DB_IP" "sudo -u postgres psql -c \"CREATE USER repuser WITH REPLICATION ENCRYPTED PASSWORD '${PRIMARY_DB_PASSWORD}';\"" 2>/dev/null || {
        log_warn "Replication user may already exist"
    }

    # Update primary postgresql.conf
    ssh_remote "$PRIMARY_DB_IP" "sudo bash -c \"
        pg_conf=\$(find /etc/postgresql -name postgresql.conf | head -1)
        sed -i \\\"s/#wal_level = replica/wal_level = replica/\\\" \\\$pg_conf
        sed -i \\\"s/#max_wal_senders = 10/max_wal_senders = 5/\\\" \\\$pg_conf
        sed -i \\\"s/#wal_keep_size = 0/wal_keep_size = 1GB/\\\" \\\$pg_conf
        pg_hba=\$(find /etc/postgresql -name pg_hba.conf | head -1)
        echo 'host replication repuser ${STANDBY_IP}/32 md5' >> \\\$pg_hba
        systemctl restart postgresql
    \""

    sleep 3

    # Clear standby data directory and take base backup
    local pg_version
    pg_version=$(ls /etc/postgresql/ 2>/dev/null | head -1)
    local data_dir="/var/lib/postgresql/${pg_version}/main"

    log_info "Taking base backup from primary..."
    rm -rf "${data_dir}"/*

    sudo -u postgres pg_basebackup \
        -h "$PRIMARY_DB_IP" \
        -U repuser \
        -D "$data_dir" \
        -P \
        --wal-method=stream \
        --checkpoint=fast || {
        log_error "Base backup failed"
        return 1
    }

    # Create standby.signal
    touch "${data_dir}/standby.signal"

    # Configure recovery on standby
    local pg_conf="${data_dir}/postgresql.conf"
    echo "primary_conninfo = 'host=${PRIMARY_DB_IP} port=5432 user=repuser password=${PRIMARY_DB_PASSWORD}'" >> "$pg_conf"
    echo "hot_standby = on" >> "$pg_conf"

    # Start standby
    systemctl start postgresql
    systemctl enable postgresql

    sleep 3

    if systemctl is-active --quiet postgresql; then
        log_success "DB Standby configured and replicating"
    else
        log_warn "Standby may still be starting. Check: journalctl -u postgresql -f"
    fi
}

role_db_standby_save_config() {
    log_step "Saving Configuration"

    mkdir -p /etc/bharatradar

    cat > /etc/bharatradar/config.env <<EOF
# BharatRadar DB Standby Configuration
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Version: 3.2.0

ROLE=db-standby
PRIMARY_DB_IP="${PRIMARY_DB_IP}"
STANDBY_IP="${STANDBY_IP}"
EOF

    chmod 600 /etc/bharatradar/config.env
    log_success "Configuration saved"
}

role_db_standby_post_install() {
    echo ""
    echo -e "${GREEN}================================================================${NC}"
    echo -e "${GREEN}        DB Standby Setup Complete!${NC}"
    echo -e "${GREEN}================================================================${NC}"
    echo ""
    echo -e "  ${CYAN}Primary:  ${PRIMARY_DB_IP}${NC}"
    echo -e "  ${CYAN}Standby:  ${STANDBY_IP}${NC}"
    echo ""
    echo -e "  ${CYAN}Check replication status (on standby):${NC}"
    echo "    sudo -u postgres psql -c 'SELECT * FROM pg_stat_wal_receiver;'"
    echo ""
    echo -e "  ${CYAN}To promote standby to primary (if primary fails):${NC}"
    echo "    sudo -u postgres pg_ctl promote -D /var/lib/postgresql/*/main"
    echo ""
    echo -e "${GREEN}================================================================${NC}"
}

role_db_standby_run() {
    require_root

    if [ -f /etc/bharatradar/config.env ]; then
        source /etc/bharatradar/config.env
        PRIMARY_DB_IP="${PRIMARY_DB_IP:-}"
        STANDBY_IP="${STANDBY_IP:-}"
    fi

    role_db_standby_collect_config
    role_db_standby_install_postgresql
    role_db_standby_configure_replication
    role_db_standby_save_config
    role_db_standby_post_install
}
