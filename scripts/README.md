# adsblol Infrastructure Scripts

Automated installation and management scripts for the adsblol ADS-B/MLAT platform.

## Directory Structure

```
scripts/
├── install/          # Main installation scripts
│   ├── infra-setup.sh          # All-in-one platform installer
│   └── setup-nginx-ssl.sh      # Nginx + Let's Encrypt setup
├── frp/              # FRP tunneling scripts
│   ├── setup-frps.sh           # FRP server setup (AWS/Cloud)
│   └── setup-frpc.sh           # FRP client setup (Raspberry Pi)
├── cluster/          # Kubernetes cluster management
│   └── manage-cluster.sh       # Create/join/deploy clusters
└── helpers/          # Shared utilities
    └── functions.sh            # Colors, validation, I/O helpers
```

## Quick Reference

| Script | Purpose | Run On |
|--------|---------|--------|
| `infra-setup.sh` | Full platform installation | Raspberry Pi |
| `setup-frps.sh` | FRP server + nginx + SSL | AWS/Cloud server |
| `setup-frpc.sh` | FRP client tunnel | Raspberry Pi |
| `manage-cluster.sh` | K3s cluster management | Any node |
| `setup-nginx-ssl.sh` | Nginx reverse proxy + Let's Encrypt | AWS/Cloud server |

## Usage

### Fresh Installation (Raspberry Pi)

```bash
sudo scripts/install/infra-setup.sh
```

### With FRP Tunnel

```bash
# 1. On AWS server:
sudo scripts/frp/setup-frps.sh

# 2. On Raspberry Pi:
sudo scripts/frp/setup-frpc.sh --server <AWS_IP> --token <TOKEN>
```

### Cluster Management

```bash
# Create new cluster
sudo scripts/cluster/manage-cluster.sh create

# Join existing cluster
sudo scripts/cluster/manage-cluster.sh join --server <IP> --token <TOKEN>

# Deploy infrastructure
sudo scripts/cluster/manage-cluster.sh deploy
```

## Requirements

- **Root/sudo** access
- **bash** shell
- **curl**, **wget** for downloads
- **systemd** for service management
- **openssl** for token generation

## Configuration

All scripts save configuration to `/etc/adsblol/`:
- `config.env` - Platform configuration
- `frps-config.env` - FRP server configuration

## Supported Platforms

- Raspberry Pi OS (64-bit)
- Ubuntu 22.04+
- Debian 12+
- ARM64, AMD64 architectures
