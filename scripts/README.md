# BharatRadar Infrastructure Scripts

Automated installation and management scripts for the BharatRadar ADS-B/MLAT platform.

## Architecture

```
                    Cloudflare DNS → map.bharat-radar.vellur.in
                                          |
                                    AWS frps + nginx
                                          |
                              FRP HTTP tunnel (:8080)
                                          |
                        ┌─────────────────┴─────────────────┐
                        │       HUB (K3s server)            │
                        │                                   │
                        │  planes  api  mlat  hub  reapi    │
                        │  haproxy  redis  mlat-map         │
                        │  ingest (listens :30004)          │
                        └──────────────┬────────────────────┘
                                       │ LAN 30004
              ┌────────────────────────┤
              │                        │
     ┌────────┴───────┐        ┌───────┴────────┐
     │ Feeder: Pi     │        │ Feeder: Future │
     │ (ingest only)  │        │ (ingest only)  │
     │ → hub:30004    │        │ → hub:30004    │
     └────────────────┘        └────────────────┘
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

### Feeder Node (ingest only, forwards to hub)
```bash
sudo ./scripts/bharatradar-cluster create \
    --role feeder \
    --hub-ip 192.168.200.145
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
| `setup-frps.sh` | FRP server setup for AWS/cloud machines |
| `setup-frpc.sh` | Standalone FRP client setup |
| `setup-nginx-ssl.sh` | Nginx + Let's Encrypt SSL setup |

## Directory Structure

```
scripts/
├── bharatradar-setup              # Interactive wizard
├── bharatradar-cluster            # Core cluster management
├── setup-frps.sh                  # FRP server (AWS/Cloud)
├── setup-frpc.sh                  # FRP client
├── setup-nginx-ssl.sh             # Nginx + Let's Encrypt
└── helpers/
    └── functions.sh               # Shared utilities
```

## Hub vs Feeder Roles

| Feature | Hub | Feeder |
|---------|-----|--------|
| K3s type | Server | Server (independent) |
| Services | All (planes, api, mlat, etc.) | ingest only |
| FRP tunnel | Yes (web traffic) | No (uses LAN) |
| Listens on | :30004 (for feeder data) | - |
| Connects to | - | Hub :30004 |
| User-facing URL | map.domain.com | - |

## Requirements

- **Root/sudo** access
- **bash** shell
- **curl**, **wget**, **openssl**
- **systemd** for service management
- **Linux** (Debian/Ubuntu/Raspberry Pi OS)
- ARM64, AMD64 architectures

## Configuration

All scripts save configuration to `/etc/bharatradar/config.env`.
