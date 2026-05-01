#!/bin/bash
# adsblol Infrastructure - Cluster Management Script
# Version: 1.0.0
#
# This script manages K3s clusters:
# 1. Create a new primary cluster
# 2. Create worker nodes and join to existing cluster
# 3. Deploy infrastructure to the cluster
# 4. Manage cluster topology

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(dirname "$SCRIPT_DIR")"
source "${SCRIPTS_DIR}/helpers/functions.sh"

# Default configuration
MODE=""
CLUSTER_NAME="adsblol"
K3S_TOKEN=""
PRIMARY_NODE_IP=""
PRIMARY_NODE_USER="pi"
PRIMARY_NODE_KEY=""
INSTALL_INFRA=true
BASE_DOMAIN=""
READSB_LAT="52.3676"
READSB_LON="4.9041"
TIMEZONE="UTC"
K3S_VERSION=""
SERVER_ARGS=""
AGENT_ARGS=""

usage() {
    cat <<EOF
Usage: $0 <COMMAND> [OPTIONS]

Commands:
  create      Create a new primary K3s cluster
  join        Join this node to an existing cluster
  deploy      Deploy infrastructure to an existing cluster
  info        Show cluster information

Options:
  --name NAME         Cluster name (default: adsblol)
  --token TOKEN       K3s cluster token
  --domain DOMAIN     Base domain
  --lat LAT           Receiver latitude
  --lon LON           Receiver longitude
  --timezone TZ       System timezone
  --server IP         Primary server IP (for join)
  --user USER         SSH user for primary node (default: pi)
  --key PATH          SSH key path for primary node
  --k3s-version VER   K3s version to install
  --no-infra          Skip infrastructure deployment
  --help              Show this help message

Examples:
  # Create new primary cluster
  sudo $0 create --domain bharat-radar.vellur.in --lat 18.48 --lon 73.89

  # Join existing cluster
  sudo $0 join --server 192.168.1.100 --token "your-token"

  # Deploy infrastructure
  sudo $0 deploy --domain bharat-radar.vellur.in

EOF
    exit 0
}

if [ $# -eq 0 ]; then
    usage
fi

MODE="$1"
shift

while [[ $# -gt 0 ]]; do
    case $1 in
        --name)         CLUSTER_NAME="$2"; shift 2 ;;
        --token)        K3S_TOKEN="$2"; shift 2 ;;
        --domain)       BASE_DOMAIN="$2"; shift 2 ;;
        --lat)          READSB_LAT="$2"; shift 2 ;;
        --lon)          READSB_LON="$2"; shift 2 ;;
        --timezone)     TIMEZONE="$2"; shift 2 ;;
        --server)       PRIMARY_NODE_IP="$2"; shift 2 ;;
        --user)         PRIMARY_NODE_USER="$2"; shift 2 ;;
        --key)          PRIMARY_NODE_KEY="$2"; shift 2 ;;
        --k3s-version)  K3S_VERSION="$2"; shift 2 ;;
        --no-infra)     INSTALL_INFRA=false; shift ;;
        --help)         usage ;;
        *)              log_error "Unknown option: $1"; usage ;;
    esac
done

cmd_create() {
    require_root

    log_step "Creating Primary K3s Cluster: ${CLUSTER_NAME}"

    # Collect configuration
    if [ -z "$BASE_DOMAIN" ]; then
        prompt_input "Base domain" "bharat-radar.vellur.in" BASE_DOMAIN
    fi
    prompt_input "Receiver latitude" "$READSB_LAT" READSB_LAT
    prompt_input "Receiver longitude" "$READSB_LON" READSB_LON

    if [ -z "$K3S_TOKEN" ]; then
        prompt_input "K3s cluster token" "$(generate_token)" K3S_TOKEN
    fi

    if [ -z "$TIMEZONE" ] && command -v timedatectl &>/dev/null; then
        TIMEZONE=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "UTC")
    fi

    log_step "Configuration"
    echo -e "  Cluster:    ${CYAN}${CLUSTER_NAME}${NC}"
    echo -e "  Domain:     ${CYAN}${BASE_DOMAIN}${NC}"
    echo -e "  Location:   ${CYAN}${READSB_LAT}, ${READSB_LON}${NC}"
    echo ""

    if ! prompt_confirm "Create cluster?"; then
        exit 0
    fi

    # Install dependencies
    install_dependencies

    # Install K3s
    log_step "Installing K3s"
    export K3S_TOKEN
    if [ -n "$K3S_VERSION" ]; then
        curl -sfL "https://get.k3s.io" | INSTALL_K3S_VERSION="$K3S_VERSION" sh -
    else
        curl -sfL https://get.k3s.io | sh -
    fi

    # Wait for K3s
    log_info "Waiting for K3s to be ready..."
    for i in $(seq 1 30); do
        if kubectl cluster-info &>/dev/null; then
            break
        fi
        sleep 2
    done

    log_success "Primary cluster created"

    # Get node token for future joins
    local node_token
    node_token=$(cat /var/lib/rancher/k3s/server/node-token 2>/dev/null || echo "Token not found")
    local server_ip
    server_ip=$(hostname -I | awk '{print $1}')

    echo ""
    log_step "Cluster Information"
    echo -e "  Server IP:       ${CYAN}${server_ip}${NC}"
    echo -e "  K3s Token:       ${CYAN}${K3S_TOKEN}${NC}"
    echo -e "  Node Token:      ${CYAN}${node_token}${NC}"
    echo ""
    echo -e "  ${CYAN}To join a worker node:${NC}"
    echo "  sudo scripts/cluster/manage-cluster.sh join --server ${server_ip} --token '${K3S_TOKEN}'"
    echo ""

    # Deploy infrastructure
    if [ "$INSTALL_INFRA" = true ]; then
        cmd_deploy
    fi

    # Save configuration
    save_config
}

cmd_join() {
    require_root

    log_step "Joining Existing K3s Cluster"

    if [ -z "$PRIMARY_NODE_IP" ]; then
        prompt_input "Primary server IP" "" PRIMARY_NODE_IP
    fi

    if [ -z "$K3S_TOKEN" ]; then
        prompt_input "K3s cluster token" "" K3S_TOKEN
    fi

    if [ -z "$PRIMARY_NODE_KEY" ]; then
        log_info "SSH key not provided. Will use password auth or existing keys."
    fi

    log_step "Configuration"
    echo -e "  Server:  ${CYAN}${PRIMARY_NODE_IP}${NC}"
    echo ""

    if ! prompt_confirm "Join cluster?"; then
        exit 0
    fi

    # Install dependencies
    install_dependencies

    # Join cluster
    log_step "Joining K3s Cluster"
    export K3S_URL="https://${PRIMARY_NODE_IP}:6443"
    export K3S_TOKEN

    curl -sfL https://get.k3s.io | K3S_URL="$K3S_URL" K3S_TOKEN="$K3S_TOKEN" sh -

    # Wait for node to register
    log_info "Waiting for node registration..."
    sleep 10

    log_success "Node joined cluster"
}

cmd_deploy() {
    require_root

    log_step "Deploying Infrastructure"

    # Collect configuration if not provided
    if [ -z "$BASE_DOMAIN" ]; then
        if [ -f /etc/adsblol/config.env ]; then
            source /etc/adsblol/config.env
        else
            prompt_input "Base domain" "bharat-radar.vellur.in" BASE_DOMAIN
        fi
    fi

    # Create namespace
    kubectl create namespace adsblol --dry-run=client -o yaml | kubectl apply -f -

    # Apply infrastructure manifests
    local manifest_root="${SCRIPTS_DIR}/../manifests/default"

    if [ ! -d "$manifest_root" ]; then
        log_error "Manifests directory not found: $manifest_root"
        return 1
    fi

    # Install kustomize if not present
    if ! command -v kustomize &>/dev/null; then
        log_info "Installing kustomize..."
        local arch
        arch=$(detect_arch)
        curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
        mv kustomize /usr/local/bin/
    fi

    # Create required secrets
    create_secrets

    # Apply all manifests
    log_info "Applying manifests..."

    local components=("api" "redis" "mlat" "mlat-map" "haproxy" "ingest" "hub" "external" "reapi" "planes")

    for component in "${components[@]}"; do
        local manifest_dir="${manifest_root}/${component}/default"
        if [ -d "$manifest_dir" ]; then
            log_info "Deploying ${component}..."
            if kustomize build "$manifest_dir" 2>/dev/null | kubectl apply -f - -n adsblol; then
                log_success "${component} deployed"
            else
                log_warn "Failed to deploy ${component}"
            fi
        fi
    done

    log_success "Infrastructure deployed"
    show_pod_status
}

create_secrets() {
    log_info "Creating required secrets..."

    # ghcr-secret
    if ! kubectl get secret ghcr-secret -n adsblol &>/dev/null; then
        kubectl create secret generic ghcr-secret \
            --from-literal=.dockerconfigjson='{"auths":{"ghcr.io":{"username":"","password":""}}}' \
            --type=kubernetes.io/dockerconfigjson \
            -n adsblol --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true
        log_warn "ghcr-secret created with empty credentials. Update with:"
        log_info "  kubectl create secret docker-registry ghcr-secret --docker-server=ghcr.io --docker-username=USER --docker-password=PASS -n adsblol"
    fi

    # rclone secret
    if ! kubectl get secret adsblol-rclone -n adsblol &>/dev/null; then
        echo "[placeholder]" | kubectl create secret generic adsblol-rclone \
            --from-file=rclone.conf=/dev/stdin \
            -n adsblol --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true
    fi

    # TLS secret (self-signed placeholder)
    if ! kubectl get secret adsblol-tls -n adsblol &>/dev/null; then
        openssl req -x509 -nodes -days 365 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
            -keyout /tmp/tls.key -out /tmp/tls.crt -subj "/CN=adsblol.local" 2>/dev/null

        kubectl create secret tls adsblol-tls \
            --cert=/tmp/tls.crt --key=/tmp/tls.key \
            -n adsblol 2>/dev/null || true

        rm -f /tmp/tls.crt /tmp/tls.key
    fi
}

show_pod_status() {
    log_step "Pod Status"
    kubectl get pods -n adsblol 2>/dev/null || log_warn "Unable to get pod status"
}

cmd_info() {
    require_root

    echo -e "${CYAN}================================================================${NC}"
    echo -e "${CYAN}        adsblol Cluster Information${NC}"
    echo -e "${CYAN}================================================================${NC}"
    echo ""

    if command -v k3s &>/dev/null; then
        echo -e "  ${CYAN}K3s Version:${NC}"
        k3s --version 2>/dev/null | head -1
        echo ""
    fi

    if kubectl cluster-info &>/dev/null 2>&1; then
        echo -e "  ${CYAN}Cluster Info:${NC}"
        kubectl cluster-info 2>/dev/null | head -1
        echo ""

        echo -e "  ${CYAN}Nodes:${NC}"
        kubectl get nodes 2>/dev/null
        echo ""

        echo -e "  ${CYAN}Pods:${NC}"
        kubectl get pods -n adsblol 2>/dev/null | head -20
        echo ""

        echo -e "  ${CYAN}Services:${NC}"
        kubectl get svc -n adsblol 2>/dev/null | head -20
        echo ""
    else
        log_warn "K3s is not running"
    fi

    if [ -f /etc/adsblol/config.env ]; then
        echo -e "  ${CYAN}Configuration (${NC}/etc/adsblol/config.env):"
        cat /etc/adsblol/config.env | grep -v "TOKEN"
        echo ""
    fi

    if systemctl is-active --quiet frpc 2>/dev/null; then
        echo -e "  ${CYAN}FRP Client:${NC} Active"
    elif systemctl is-active --quiet frps 2>/dev/null; then
        echo -e "  ${CYAN}FRP Server:${NC} Active"
    fi

    echo -e "${CYAN}================================================================${NC}"
}

save_config() {
    mkdir -p /etc/adsblol

    cat > /etc/adsblol/config.env <<EOF
# adsblol Infrastructure Configuration
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Version: 1.0.0

CLUSTER_NAME=${CLUSTER_NAME}
BASE_DOMAIN=${BASE_DOMAIN}
READSB_LAT=${READSB_LAT}
READSB_LON=${READSB_LON}
TIMEZONE=${TIMEZONE}
K3S_TOKEN=${K3S_TOKEN}

# Subdomains
SUBDOMAINS="map history mlat api feed ws"
EOF

    chmod 600 /etc/adsblol/config.env
    log_success "Configuration saved to /etc/adsblol/config.env"
}

case "$MODE" in
    create)  cmd_create ;;
    join)    cmd_join ;;
    deploy)  cmd_deploy ;;
    info)    cmd_info ;;
    *)       log_error "Unknown command: $MODE"; usage ;;
esac
