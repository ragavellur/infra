# adsblol Infrastructure - Installation Guide

> **Version:** 1.0.0
> **Author:** @adsblol/sre
> **Last Updated:** May 2026

Complete guide to deploying the adsblol ADS-B/MLAT aggregator platform with optional FRP tunneling and multi-cluster support.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Prerequisites](#prerequisites)
3. [Quick Start](#quick-start)
4. [Step-by-Step Installation](#step-by-step-installation)
   - [Option A: All-in-One (Raspberry Pi Only)](#option-a-all-in-one-raspberry-pi-only)
   - [Option B: With FRP Tunneling (Recommended)](#option-b-with-frp-tunneling-recommended)
5. [FRP Server Setup (AWS/Cloud)](#frp-server-setup-awscloud)
6. [FRP Client Setup (Raspberry Pi)](#frp-client-setup-raspberry-pi)
7. [SSL/TLS Configuration](#ssltls-configuration)
8. [Cluster Management](#cluster-management)
9. [Configuration Reference](#configuration-reference)
10. [Troubleshooting](#troubleshooting)
11. [Useful Commands](#useful-commands)

---

## Architecture Overview

```
                    Cloudflare (DNS + CDN)
                            |
                            v
                    AWS EC2 (frps + nginx)
                            |
                    frp tunnel (HTTP + TCP)
                            |
                            v
               Raspberry Pi (K3s + frpc)
                /      |      |      \
          ingest    hub    planes   mlat
           |         |       |        |
           +---------+-------+--------+
                     |
                   reapi
                     |
                   api
```

### Components

| Component | Description | Port |
|-----------|-------------|------|
| **K3s** | Lightweight Kubernetes | 6443 |
| **ingest-readsb** | Public ADS-B ingest | 30004, 30005 |
| **hub-readsb** | Aggregation layer | 30004 |
| **planes-readsb** | Public map (tar1090) | 80, 30152 |
| **mlat-mlat-server** | MLAT processing | 31090, 30104 |
| **reapi-readsb** | REST API data | 30006, 32006 |
| **api** | Main web API | 8080 |
| **mlat-map** | MLAT sync UI | 80 |
| **haproxy** | Load balancer | 80, 443 |
| **redis** | Cache | 6379 |

---

## Prerequisites

### Raspberry Pi (Edge Node)

- Raspberry Pi 4 (4GB+ RAM recommended)
- Raspberry Pi OS (64-bit) or Debian/Ubuntu
- RTL-SDR dongle (optional, for direct receiver)
- Static IP on local network
- Ports 80, 30004, 30005, 31090 accessible

### AWS/Cloud Server (FRP Server - Optional)

- Any cloud VPS (AWS EC2, DigitalOcean, etc.)
- Ubuntu 22.04+ or Debian 12+
- Public IP address
- Ports 7000, 80, 443, 30004, 30005, 31090 open

### DNS Setup

- Domain registered with DNS provider (Cloudflare recommended)
- DNS records pointing to FRP server IP (if using FRP)

---

## Quick Start

### Option A: All-in-One (Raspberry Pi Only)

If you only need local access (no public internet exposure):

```bash
# Clone the repository
git clone https://github.com/ragavellur/infra.git
cd infra

# Run the main installer
sudo scripts/install/infra-setup.sh \
  --domain bharat-radar.vellur.in \
  --lat 18.480718 \
  --lon 73.898235
```

### Option B: With FRP Tunneling (Recommended)

For public access through a cloud server:

```
1. Set up FRP server on AWS → scripts/frp/setup-frps.sh
2. Set up FRP client on Pi  → scripts/frp/setup-frpc.sh
3. Configure SSL             → scripts/install/setup-nginx-ssl.sh
4. Deploy infrastructure     → scripts/cluster/manage-cluster.sh deploy
```

See [Step-by-Step Installation](#step-by-step-installation) for detailed instructions.

---

## Step-by-Step Installation

### Option A: All-in-One (Raspberry Pi Only)

This installs everything on a single Raspberry Pi. The platform will be accessible on the local network.

```bash
# 1. Clone repository
git clone https://github.com/ragavellur/infra.git
cd infra

# 2. Run interactive installer
sudo scripts/install/infra-setup.sh

# Or with parameters:
sudo scripts/install/infra-setup.sh \
  --domain bharat-radar.vellur.in \
  --lat 18.480718 \
  --lon 73.898235 \
  --timezone Asia/Kolkata
```

The installer will:
1. Install system dependencies
2. Install K3s (lightweight Kubernetes)
3. Create Kubernetes namespace and secrets
4. Deploy all ADS-B/MLAT services
5. Save configuration to `/etc/adsblol/config.env`

### Option B: With FRP Tunneling (Recommended)

This provides public internet access through an AWS/cloud server with SSL.

#### Step 1: Set up DNS

In Cloudflare (or your DNS provider), create A records pointing to your AWS server IP:

```
Type    Name                        Value
A       bharat-radar.vellur.in      13.48.249.103
A       map.bharat-radar.vellur.in  13.48.249.103
A       history.bharat-radar.vellur.in  13.48.249.103
A       mlat.bharat-radar.vellur.in  13.48.249.103
A       api.bharat-radar.vellur.in  13.48.249.103
A       feed.bharat-radar.vellur.in  13.48.249.103
A       ws.bharat-radar.vellur.in   13.48.249.103
```

> **Note:** Set proxy status to **DNS Only** (grey cloud) initially. The FRP server handles SSL.

#### Step 2: Set up FRP Server on AWS

See [FRP Server Setup](#frp-server-setup-awscloud) below.

#### Step 3: Set up FRP Client on Raspberry Pi

See [FRP Client Setup](#frp-client-setup-raspberry-pi) below.

#### Step 4: Deploy Infrastructure

```bash
# On Raspberry Pi:
cd infra
sudo scripts/cluster/manage-cluster.sh deploy --domain bharat-radar.vellur.in
```

---

## FRP Server Setup (AWS/Cloud)

The FRP server runs on your cloud machine and acts as a reverse proxy, forwarding traffic to your Raspberry Pi.

### Prerequisites

- Ubuntu/Debian cloud server
- Public IP
- DNS records pointing to this IP

### Setup

```bash
# On AWS server:
git clone https://github.com/ragavellur/infra.git
cd infra

# Interactive setup
sudo scripts/frp/setup-frps.sh

# Or automated:
sudo scripts/frp/setup-frps.sh \
  --domain bharat-radar.vellur.in \
  --frp-token "your-secret-token" \
  --email admin@example.com
```

This will:
1. Install FRP server (frps)
2. Configure frps.toml with auth and ports
3. Create systemd service for frps
4. Install nginx as reverse proxy
5. Configure nginx to proxy to FRP vhost port
6. Obtain Let's Encrypt SSL certificates for all subdomains
7. Set up automatic certificate renewal

### Manual Setup

If you prefer manual configuration:

```bash
# 1. Download frps
FRP_VERSION="0.68.1"
ARCH=$(uname -m)
curl -L "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_${ARCH}.tar.gz" | tar xz
sudo cp "frp_${FRP_VERSION}_linux_${ARCH}/frps" /usr/local/bin/

# 2. Configure frps
sudo tee /etc/frps.toml << 'EOF'
bindPort = 7000
vhostHTTPPort = 8080

auth.method = "token"
auth.token = "YOUR_SECRET_TOKEN"

webServer.addr = "0.0.0.0"
webServer.port = 7500
webServer.user = "admin"
webServer.password = "YOUR_DASHBOARD_PASSWORD"
EOF

# 3. Create systemd service
sudo tee /etc/systemd/system/frps.service << 'EOF'
[Unit]
Description=FRP Server (adsblol)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/frps -c /etc/frps.toml
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

# 4. Enable and start
sudo systemctl daemon-reload
sudo systemctl enable frps
sudo systemctl start frps

# 5. Continue with nginx + SSL setup
sudo scripts/install/setup-nginx-ssl.sh --domain bharat-radar.vellur.in --email admin@example.com
```

---

## FRP Client Setup (Raspberry Pi)

The FRP client runs on your Raspberry Pi and creates a secure tunnel to the FRP server.

### Prerequisites

- K3s installed (via `infra-setup.sh` or manually)
- FRP server already running on AWS

### Setup

```bash
# On Raspberry Pi:
cd infra

# Interactive setup
sudo scripts/frp/setup-frpc.sh

# Or automated:
sudo scripts/frp/setup-frpc.sh \
  --server 13.48.249.103 \
  --token "your-secret-token" \
  --domain bharat-radar.vellur.in
```

This will:
1. Download and install frpc
2. Generate frpc.toml with all proxy configurations
3. Create systemd service
4. Start and verify the connection

### Manual Setup

```bash
# 1. Download frpc
FRP_VERSION="0.68.1"
ARCH=$(uname -m)
curl -L "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_${ARCH}.tar.gz" | tar xz
sudo cp "frp_${FRP_VERSION}_linux_${ARCH}/frpc" /usr/local/bin/

# 2. Configure frpc
sudo tee /etc/frpc.toml << EOF
serverAddr = "13.48.249.103"
serverPort = 7000

auth.method = "token"
auth.token = "YOUR_SECRET_TOKEN"

[[proxies]]
name = "web-ui"
type = "http"
localIP = "127.0.0.1"
localPort = 80
customDomains = [
    "bharat-radar.vellur.in",
    "map.bharat-radar.vellur.in",
    "history.bharat-radar.vellur.in",
    "mlat.bharat-radar.vellur.in",
    "api.bharat-radar.vellur.in",
    "feed.bharat-radar.vellur.in",
    "ws.bharat-radar.vellur.in"
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
EOF

# 3. Create systemd service
sudo tee /etc/systemd/system/frpc.service << 'EOF'
[Unit]
Description=FRP Client (adsblol)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/frpc -c /etc/frpc.toml
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

# 4. Enable and start
sudo systemctl daemon-reload
sudo systemctl enable frpc
sudo systemctl start frpc

# 5. Check status
sudo systemctl status frpc
journalctl -u frpc -f
```

---

## SSL/TLS Configuration

### Let's Encrypt with Nginx (on FRP Server)

The `setup-frps.sh` script handles SSL automatically. For manual setup:

```bash
sudo scripts/install/setup-nginx-ssl.sh \
  --domain bharat-radar.vellur.in \
  --email admin@example.com
```

### Cloudflare Edge Certificates

If using Cloudflare proxy (orange cloud), you need either:
1. **Flexible SSL mode** - Cloudflare handles HTTPS, connects to origin via HTTP
2. **Full SSL mode** - Requires valid certificate on origin server
3. **Advanced Certificate Manager** - For wildcard certificates on free tier

> **Note:** On free Cloudflare plans, Edge Certificates may not cover all subdomains immediately. Use DNS-only mode with origin SSL for immediate coverage.

### Certificate Auto-Renewal

Let's Encrypt certificates auto-renew via certbot timer:

```bash
# Check timer status
sudo systemctl status certbot.timer

# Test renewal
sudo certbot renew --dry-run

# View certificates
sudo certbot certificates
```

---

## Cluster Management

### Create a New Cluster

```bash
sudo scripts/cluster/manage-cluster.sh create \
  --domain bharat-radar.vellur.in \
  --lat 18.480718 \
  --lon 73.898235
```

### Join an Existing Cluster

```bash
sudo scripts/cluster/manage-cluster.sh join \
  --server 192.168.1.100 \
  --token "your-k3s-token"
```

### Deploy Infrastructure

```bash
sudo scripts/cluster/manage-cluster.sh deploy \
  --domain bharat-radar.vellur.in
```

### View Cluster Info

```bash
sudo scripts/cluster/manage-cluster.sh info
```

---

## Configuration Reference

### Configuration Files

| File | Location | Description |
|------|----------|-------------|
| K3s config | `/etc/rancher/k3s/k3s.yaml` | Kubernetes admin config |
| FRP server | `/etc/frps.toml` | FRP server configuration |
| FRP client | `/etc/frpc.toml` | FRP client configuration |
| Nginx HTTP | `/etc/nginx/sites-available/adsblol-http` | HTTP server block |
| Nginx SSL | `/etc/nginx/sites-available/adsblol-ssl` | HTTPS server block |
| Platform config | `/etc/adsblol/config.env` | Generated platform config |

### Environment Variables

```bash
# /etc/adsblol/config.env
BASE_DOMAIN=bharat-radar.vellur.in
READSB_LAT=18.480718
READSB_LON=73.898235
TIMEZONE=Asia/Kolkata
K3S_TOKEN=your-k3s-token
```

### Subdomains

| Subdomain | Service | Description |
|-----------|---------|-------------|
| `map.*` | planes-readsb | tar1090 map interface |
| `mlat.*` | mlat-map | MLAT sync visualization |
| `history.*` | history | Historical flight data |
| `api.*` | api | REST API |
| `feed.*` | ingest | ADS-B feed endpoint |
| `ws.*` | api | WebSocket connections |

---

## Troubleshooting

### K3s Issues

```bash
# Check K3s status
sudo systemctl status k3s

# View K3s logs
sudo journalctl -u k3s -f

# Reset K3s (WARNING: destroys cluster)
sudo k3s-uninstall.sh
```

### FRP Issues

```bash
# Check FRP client
sudo systemctl status frpc
journalctl -u frpc -f

# Check FRP server
sudo systemctl status frps
journalctl -u frps -f

# Test FRP dashboard
curl http://localhost:7500
```

### Pod Issues

```bash
# View all pods
kubectl get pods -n adsblol

# View pod logs
kubectl logs -n adsblol <pod-name>

# Describe pod for events
kubectl describe pod -n adsblol <pod-name>

# Restart a deployment
kubectl rollout restart deployment/<name> -n adsblol
```

### Common Problems

| Problem | Solution |
|---------|----------|
| `readsb` crash loop | Add `READSB_DEVICE_TYPE=none` env var |
| `mlat-server` crash | Python 3.13 compatibility - pkg_resources stub is installed |
| SSL handshake failure | Check certificate covers the subdomain |
| Pods in CrashLoopBackOff | Check logs: `kubectl logs <pod> -n adsblol` |
| FRP connection refused | Verify firewall allows port 7000 |
| nginx 502 Bad Gateway | Check frps is running on port 8080 |

### FRP Connection Troubleshooting

```bash
# On Pi: Check frpc can reach server
curl -v telnet://13.48.249.103:7000

# On Pi: Check frpc logs
journalctl -u frpc --since "5 minutes ago"

# On AWS: Check frps logs
journalctl -u frps --since "5 minutes ago"

# On AWS: Check if frps is listening
sudo ss -tlnp | grep 7000
sudo ss -tlnp | grep 8080
```

---

## Useful Commands

### K3s / Kubernetes

```bash
# kubectl is available via symlink
sudo k3s kubectl get pods -n adsblol
# or
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get pods -n adsblol

# Common kubectl commands
kubectl get pods -n adsblol                    # List pods
kubectl get svc -n adsblol                     # List services
kubectl get ingress -n adsblol                 # List ingresses
kubectl logs -n adsblol -l app=planes          # View plane logs
kubectl describe pod <name> -n adsblol         # Pod details
kubectl exec -it <pod> -n adsblol -- bash      # Shell into pod
```

### FRP

```bash
sudo systemctl {start|stop|restart|status} frpc   # FRP client
sudo systemctl {start|stop|restart|status} frps   # FRP server
journalctl -u frpc -f                              # FRP client logs
journalctl -u frps -f                              # FRP server logs
cat /etc/frpc.toml                                 # View frpc config
cat /etc/frps.toml                                 # View frps config
```

### Nginx

```bash
sudo systemctl {start|stop|restart|reload|status} nginx
sudo nginx -t                    # Test config
sudo nginx -T                    # Show full config
tail -f /var/log/nginx/access.log
tail -f /var/log/nginx/error.log
```

### SSL

```bash
sudo certbot certificates         # List certificates
sudo certbot renew --dry-run      # Test renewal
sudo ls -la /etc/letsencrypt/live/
```

---

## Updating

```bash
# Update repository
git pull origin main

# Rebuild and apply manifests
kustomize build manifests/default | kubectl apply -f - -n adsblol
```

---

## Support

- **GitHub:** https://github.com/ragavellur/infra
- **Issues:** https://github.com/ragavellur/infra/issues
- **Original Project:** https://github.com/adsblol
