# BharatRadar Infrastructure Scripts

Automated installation and management scripts for the BharatRadar ADS-B/MLAT platform.

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
              │  haproxy  redis  mlat-map  external             │
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

### Interactive Setup
```bash
sudo ./scripts/bharatradar-setup
```

### Hub Node (runs all services)
```bash
sudo ./scripts/bharatradar-cluster create \
    --role hub \
    --domain bharat-radar.vellur.in \
    --lat 18.480718 \
    --lon 73.898235 \
    --timezone Asia/Kolkata \
    --frp-server 13.48.249.103 \
    --frp-token "your-frp-token"
```

### Aggregator Node (K3s agent, failover)
```bash
# First get join token from Hub:
sudo cat /var/lib/rancher/k3s/server/node-token

# Then on aggregator Pi:
curl -sfL https://get.k3s.io | \
  K3S_URL=https://HUB_IP:6443 \
  K3S_TOKEN=$TOKEN \
  sh -
```

### Feeder Pi (RTL-SDR receiver, not K3s)
```bash
# The Feeder Pi is NOT a K3s node.
# It runs readsb + mlat-client and connects to feed.bharat-radar.vellur.in
# See INSTALL.md for Feeder Pi setup instructions.
```

### View Cluster Info
```bash
sudo ./scripts/bharatradar-cluster info
```

## Scripts Overview

| Script | Purpose |
|--------|---------|
| `bharatradar-setup` | Interactive wizard (recommended for first-time users) |
| `bharatradar-cluster` | Core cluster management (create/info subcommands) |
| `frp/setup-frps.sh` | FRP server setup for AWS/cloud machines |
| `frp/setup-frpc.sh` | Standalone FRP client setup (runs on Hub) |
| `install/setup-nginx-ssl.sh` | Nginx + Let's Encrypt SSL setup |

## Directory Structure

```
scripts/
├── bharatradar-setup              # Interactive wizard
├── bharatradar-cluster            # Core cluster management
├── frp/
│   ├── setup-frps.sh              # FRP server (AWS/Cloud)
│   └── setup-frpc.sh              # FRP client (Hub node)
├── install/
│   └── setup-nginx-ssl.sh         # Nginx + Let's Encrypt
└── helpers/
    └── functions.sh               # Shared utilities
```

## Node Roles

| Feature | Hub | Aggregator | Feeder Pi |
|---------|-----|------------|-----------|
| K3s type | Server | Agent | None |
| Services | All (planes, api, mlat, etc.) | Runs pods on failover | readsb + mlat-client only |
| FRP | Client (frpc) | None | None |
| Hardware | Ubuntu i7 / powerful machine | Raspberry Pi (arm64) | Raspberry Pi + RTL-SDR |
| Connects to | AWS FRP server | Hub (k3s join) | `feed.bharat-radar.vellur.in` |
| User-facing URL | map.domain.com | - | - |

## Requirements

- **Root/sudo** access
- **bash** shell
- **curl**, **wget**, **openssl**
- **systemd** for service management
- **Linux** (Debian/Ubuntu/Raspberry Pi OS)
- ARM64, AMD64 architectures

## Configuration

All scripts save configuration to `/etc/bharatradar/config.env`.
