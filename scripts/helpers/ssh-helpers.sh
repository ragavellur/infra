#!/bin/bash
# SSH helper functions for remote operations
# Used by node removal, DB standby setup, and cross-node management.

set -euo pipefail

SSH_CMD=""
SSH_USER=""
SSH_PASSWORD=""
SSH_KEY_PATH=""

# Prompt for SSH credentials interactively
ssh_prompt() {
    local target_ip="${1:-}"
    log_step "SSH Connection to ${target_ip}"

    prompt_input "SSH username" "bharatradar" SSH_USER

    local auth_method
    prompt_select "Authentication method" \
        "Password" \
        "SSH key file" auth_method

    if [ "$auth_method" = "Password" ]; then
        prompt_input "SSH password" "" SSH_PASSWORD
        while [ -z "$SSH_PASSWORD" ]; do
            log_error "Password cannot be empty"
            prompt_input "SSH password" "" SSH_PASSWORD
        done

        if ! command -v sshpass &>/dev/null; then
            log_info "Installing sshpass..."
            local os
            os=$(detect_os)
            case "$os" in
                debian|ubuntu|raspbian)
                    apt-get install -y -qq sshpass
                    ;;
                fedora|centos|rhel)
                    dnf install -y -qq sshpass
                    ;;
            esac
        fi

        SSH_CMD="sshpass -p '${SSH_PASSWORD}' ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no"
    else
        prompt_input "SSH key file path" "~/.ssh/id_rsa" SSH_KEY_PATH
        SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"
        while [ ! -f "$SSH_KEY_PATH" ]; do
            log_error "Key file not found: ${SSH_KEY_PATH}"
            prompt_input "SSH key file path" "$SSH_KEY_PATH" SSH_KEY_PATH
            SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"
        done

        SSH_CMD="ssh -i '${SSH_KEY_PATH}' -o ConnectTimeout=10 -o StrictHostKeyChecking=no"
    fi

    # Test connection
    log_info "Testing connection to ${SSH_USER}@${target_ip}..."
    if ssh_remote "$target_ip" "echo ok" 2>/dev/null | grep -q "ok"; then
        log_success "SSH connection successful"
    else
        log_error "Failed to connect to ${SSH_USER}@${target_ip}"
        return 1
    fi
}

# Execute command on remote host
ssh_remote() {
    local host="$1"
    shift
    ${SSH_CMD} "${SSH_USER}@${host}" "$@"
}

# Copy file to remote host
ssh_copy_to() {
    local host="$1"
    local local_file="$2"
    local remote_path="$3"

    if [ -n "${SSH_PASSWORD:-}" ]; then
        sshpass -p "${SSH_PASSWORD}" scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$local_file" "${SSH_USER}@${host}:${remote_path}"
    else
        scp -i "${SSH_KEY_PATH}" -o StrictHostKeyChecking=no "$local_file" "${SSH_USER}@${host}:${remote_path}"
    fi
}

# Copy file from remote host
ssh_copy_from() {
    local host="$1"
    local remote_path="$2"
    local local_file="$3"

    if [ -n "${SSH_PASSWORD:-}" ]; then
        sshpass -p "${SSH_PASSWORD}" scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "${SSH_USER}@${host}:${remote_path}" "$local_file"
    else
        scp -i "${SSH_KEY_PATH}" -o StrictHostKeyChecking=no "${SSH_USER}@${host}:${remote_path}" "$local_file"
    fi
}

# Execute script on remote host (sends local script via stdin)
ssh_remote_script() {
    local host="$1"
    local script_file="$2"
    shift 2

    ${SSH_CMD} "${SSH_USER}@${host}" "bash -s -- $*" < "$script_file"
}

# Drain and remove a node from the cluster
remove_node_interactive() {
    local node_name=""
    local node_ip=""

    prompt_input "Node name (as shown in kubectl get nodes)" "" node_name
    while [ -z "$node_name" ]; do
        log_error "Node name cannot be empty"
        prompt_input "Node name" "" node_name
    done

    prompt_input "Node IP address" "" node_ip
    while ! validate_ip "$node_ip"; do
        log_error "Invalid IP address"
        prompt_input "Node IP address" "" node_ip
    done

    echo ""
    log_warn "This will:"
    echo "  1. Cordon node ${node_name} (stop scheduling)"
    echo "  2. Drain all pods from ${node_name}"
    echo "  3. Delete node from cluster"
    echo "  4. Uninstall K3s on ${node_ip}"
    echo "  5. Remove configuration files"
    echo ""

    if ! prompt_confirm "Proceed with node removal?"; then
        log_info "Cancelled."
        return 0
    fi

    ssh_prompt "$node_ip"

    # Check if node exists
    if ! kubectl get node "$node_name" &>/dev/null; then
        log_error "Node '${node_name}' not found in cluster"
        log_info "Available nodes:"
        kubectl get nodes 2>/dev/null || true
        return 1
    fi

    # Cordon
    log_step "Cordoning node ${node_name}..."
    kubectl cordon "$node_name"
    log_success "Node cordoned"

    # Drain
    log_step "Draining node ${node_name}..."
    kubectl drain "$node_name" --ignore-daemonsets --delete-emptydir-data --force --timeout=120s || {
        log_warn "Drain timed out or partially failed. Continuing with removal..."
    }
    log_success "Node drained"

    # Delete from cluster
    log_step "Removing node from cluster..."
    kubectl delete node "$node_name"
    log_success "Node deleted from cluster"

    # Uninstall K3s on remote
    log_step "Uninstalling K3s on ${node_ip}..."
    if ssh_remote "$node_ip" "test -f /usr/local/bin/k3s-agent-uninstall.sh"; then
        ssh_remote "$node_ip" "sudo /usr/local/bin/k3s-agent-uninstall.sh" || {
            log_warn "Agent uninstall failed, cleaning manually..."
            ssh_remote "$node_ip" "sudo systemctl stop k3s-agent 2>/dev/null; sudo rm -rf /usr/local/bin/k3s /usr/local/bin/k3s-agent-uninstall.sh /etc/rancher/k3s /var/lib/rancher/k3s /etc/systemd/system/k3s-agent.service"
        }
    elif ssh_remote "$node_ip" "test -f /usr/local/bin/k3s-uninstall.sh"; then
        ssh_remote "$node_ip" "sudo /usr/local/bin/k3s-uninstall.sh" || {
            log_warn "Server uninstall failed, cleaning manually..."
            ssh_remote "$node_ip" "sudo systemctl stop k3s 2>/dev/null; sudo rm -rf /usr/local/bin/k3s /usr/local/bin/k3s-uninstall.sh /etc/rancher/k3s /var/lib/rancher/k3s /etc/systemd/system/k3s.service"
        }
    else
        log_warn "No K3s uninstall script found, cleaning manually..."
        ssh_remote "$node_ip" "sudo systemctl stop k3s k3s-agent 2>/dev/null; sudo rm -rf /usr/local/bin/k3s /etc/rancher/k3s /var/lib/rancher/k3s"
    fi

    # Clean config
    ssh_remote "$node_ip" "sudo rm -rf /etc/bharatradar /etc/keepalived /etc/bharat-radar-id" || true

    log_success "Node ${node_name} (${node_ip}) fully removed"
}
