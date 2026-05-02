# BharatRadar Infrastructure Scripts

Automated installation and management for the BharatRadar ADS-B/MLAT platform.

## Architecture

```
                    Cloudflare DNS → map.bharat-radar.vellur.in
                                          |
                                    AWS frps + nginx
                                      /    |    \
                              port 30004  31090  HTTP/HTTPS
                                 |         |         |
                                 v         v         v
              ┌─────────────────────────────────────────────────┐
              │           HUB (K3s server)                      │
              │           192.168.200.145 (Ubuntu i7)           │
              │                                                 │
              │  planes  api  mlat  hub  reapi  ingest          │
              │  haproxy  redis  mlat-map  external  website    │
              └──────────────────────┬──────────────────────────┘
                                     │ k3s join
                                     v
              ┌─────────────────────────────────────────┐
              │  BR-AGGRIGATOR (K3s agent)              │
              │  192.168.200.187 (Raspberry Pi, arm64)  │
              │  Failover node                          │
              └─────────────────────────────────────────┘

    FEEDER PI (not K3s, standalone)
    192.168.200.127
    readsb → feed.bharat-radar.vellur.in:30004 (via AWS FRP)
    mlat-client → feed.bharat-radar.vellur.in:31090 (via AWS FRP)
```

## Quick Start

### Online Install (Recommended)

Run these commands on each machine depending on its role:

```bash
# FRP Server (Cloud/VPS with public IP)
curl -Ls https://raw.githubusercontent.com/ragavellur/infra/main/scripts/bharatradar-install | sudo bash -s -- frp-server

# Hub (K3s server, runs all services)
curl -Ls https://raw.githubusercontent.com/ragavellur/infra/main/scripts/bharatradar-install | sudo bash -s -- hub

# Aggregator (K3s agent, joins existing hub)
curl -Ls https://raw.githubusercontent.com/ragavellur/infra/main/scripts/bharatradar-install | sudo bash -s -- aggregator

# Feeder Pi (RTL-SDR receiver, standalone)
curl -Ls https://raw.githubusercontent.com/ragavellur/infra/main/scripts/bharatradar-install | sudo bash -s -- feeder
```

### Local Install

```bash
# Clone the repo
git clone https://github.com/ragavellur/infra.git
cd infra/scripts

# Interactive wizard (asks you what you want to set up)
sudo ./bharatradar-install

# Or specify role directly
sudo ./bharatradar-install hub
```

### Post-Install Commands

```bash
sudo ./bharatradar-install status      # Health dashboard
sudo ./bharatradar-install uninstall   # Remove components
sudo ./bharatradar-install update      # Update scripts and redeploy
sudo ./bharatradar-install backup      # Backup configuration
```

## Scripts Overview

| Script | Purpose |
|--------|---------|
| `bharatradar-install` | **Main entry point** - unified installer for all roles |
| `bharatradar-setup` | DEPRECATED - redirects to bharatradar-install |
| `bharatradar-cluster` | Advanced CLI for CI/CD and power users |

### Role Modules (`roles/`)

| Module | Description |
|--------|-------------|
| `roles/frp-server.sh` | FRP server setup (AWS/cloud VPS) |
| `roles/hub.sh` | K3s server + all BharatRadar services |
| `roles/aggregator.sh` | K3s agent join to existing hub |
| `roles/feeder.sh` | RTL-SDR standalone receiver setup |

### Helper Modules (`helpers/`)

| Module | Description |
|--------|-------------|
| `helpers/functions.sh` | Shared utilities (logging, validation, prompts) |
| `helpers/templating.sh` | Runtime manifest overlay generation |
| `helpers/verify.sh` | Post-install health checks |
| `helpers/uninstall.sh` | Cleanup and reset functions |

### Standalone Scripts (kept for compatibility)

| Script | Description |
|--------|-------------|
| `frp/setup-frps.sh` | Standalone FRP server setup |
| `frp/setup-frpc.sh` | Standalone FRP client setup |
| `install/setup-nginx-ssl.sh` | Standalone nginx + Let's Encrypt setup |

## Installation Flow

```
bharatradar-install
│
├── [1] Prerequisites check
│     ├── Root access
│     ├── OS (Debian/Ubuntu/RPi OS)
│     ├── Architecture (amd64/arm64/arm)
│     └── Network connectivity
│
├── [2] Role selection
│     ├── 1) FRP Server (cloud/VPS)
│     ├── 2) Hub (K3s server)
│     ├── 3) Aggregator (K3s agent)
│     └── 4) Feeder Pi (RTL-SDR)
│
├── [3] Configuration collection
│     ├── Base domain
│     ├── Email (for Let's Encrypt)
│     ├── Lat/lon/altitude
│     └── Role-specific (GHCR creds, FRP token, etc.)
│
├── [4] Installation
│     ├── Package installation
│     ├── Binary downloads
│     ├── Service configuration
│     └── Deployment
│
└── [5] Post-install
      ├── Configuration saved to /etc/bharatradar/
      ├── Health verification
      └── URLs and next steps displayed
```

## Node Roles

| Feature | FRP Server | Hub | Aggregator | Feeder Pi |
|---------|------------|-----|------------|-----------|
| OS | Ubuntu/Debian (cloud) | Ubuntu/Debian | Debian/RPi OS | Raspberry Pi OS |
| K3s | No | Server | Agent | No |
| Services | frps, nginx, certbot | All (planes, api, mlat, etc.) | Runs pods on failover | readsb + mlat-client |
| FRP | Server (frps) | Client (frpc) | None | None |
| Hardware | Cloud VPS / AWS EC2 | Powerful machine (i7+) | Raspberry Pi (arm64) | Raspberry Pi + RTL-SDR |
| Connects to | - | frps via tunnel | Hub (k3s join) | `feed.domain.com` |
| Public IP | Required | Optional | Not needed | Not needed |

## Requirements

- **Root/sudo** access on all machines
- **bash** shell (4.0+)
- **curl**, **wget**, **openssl**
- **systemd** for service management
- **Linux**: Debian 11+, Ubuntu 20.04+, Raspberry Pi OS
- **Architectures**: amd64, arm64, arm (armv7l)

## Configuration

All scripts save configuration to `/etc/bharatradar/config.env`.

```bash
# View current configuration
cat /etc/bharatradar/config.env

# Backup configuration
sudo ./bharatradar-install backup

# Restore from backup
sudo tar xzf /tmp/bharatradar-backup-YYYYMMDD_HHMMSS.tar.gz -C /
```

## Troubleshooting

```bash
# Check overall status
sudo ./bharatradar-install status

# Check K3s cluster
kubectl get nodes
kubectl get pods -n bharatradar

# Check FRP
sudo systemctl status frps     # On FRP server
sudo systemctl status frpc     # On Hub
journalctl -u frpc -f          # FRP client logs

# Check feeder services
sudo systemctl status bharat-feeder
sudo systemctl status bharat-mlat
journalctl -u bharat-feeder -f

# Full uninstall and clean start
sudo ./bharatradar-install uninstall
```
