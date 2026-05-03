# bharatradar/infra

BharatRadar ADS-B/MLAT aggregator platform. Aggregates [ADS-B](https://github.com/wiedehopf/readsb) & [MLAT](https://github.com/wiedehopf/mlat-server) data from multiple feeders and serves a public map interface.

## Why?

Community-driven ADS-B aggregation, built as a fork of [adsblol/infra](https://github.com/adsblol/infra). All upstream images are mirrored to `ghcr.io/bharatradar/` with multi-arch support (amd64 + arm64) for Raspberry Pi compatibility.

## Architecture

```
Feeder Pi (RTL-SDR) ──→ feed.bharat-radar.vellur.in:30004 (AWS EC2 FRP) ──→ Hub ingest
                                                                                    │
                                                                                     v
   ┌───────────────────────────┐         ┌───────────────────────────┐
   │  Hub (K3s server, MASTER)  │←VIP→│  HA Server (K3s, BACKUP) │
   │  192.168.200.145 (i7)      │         │  192.168.200.155 (i5)     │
   │  planes api mlat hub       │         │  same PostgreSQL datastore │
   │  haproxy redis mlat-map    │         │                            │
   └─────────────┬─────────────┘         └─────────────┬─────────────┘
                 │ shared PostgreSQL                   │
                 v                                     v
   ┌─────────────────────────────────────────────────────────────┐
   │  Shared Services (Pi)                                        │
   │  192.168.200.127  ← PostgreSQL + Redis + InfluxDB           │
   └─────────────────────────────────────────────────────────────┘
                 ▲
                 │ (optional DB Standby replica)
```

### Data Flow

```
Feeder Pi (readsb + mlat-client)
    │
    ├── beast_reduce_plus_out ──→ feed.bharat-radar.vellur.in:30004 (AWS FRP server)
    │                                                          │
    │                                                          └── TCP tunnel ──→ Hub ingest-readsb:30004
    │
    └── mlat-client ──→ feed.bharat-radar.vellur.in:31090 (AWS FRP server)
                                                         │
                                                         └── TCP tunnel ──→ Hub mlat-mlat-server:31090

Hub Cluster:
  user ──→ Cloudflare ──→ AWS FRP ──→ HAProxy ──→ planes-readsb (tar1090 map)
                                                         └──← hub-readsb ──← ingest-readsb
```

### Nodes

| Node | IP | OS | Role | Arch |
|------|----|----|------|------|
| **Hub** | 192.168.200.145 | Ubuntu 24.04 (Core i7) | K3s server, PRIMARY keepalived | amd64 |
| **HA Server** | 192.168.200.155 | macOS/Core i5 | K3s server, BACKUP keepalived | amd64 |
| **br-aggrigator** | 192.168.200.187 | Debian 12 (Raspberry Pi) | K3s agent (optional) | arm64 |
| **Shared Services** | 192.168.200.127 | Raspberry Pi OS | PostgreSQL + Redis + InfluxDB | arm64 |
| **Feeder Pi** | 192.168.200.127 | Raspberry Pi OS | RTL-SDR + readsb + mlat-client (not K3s) | arm64 |

### Services

| Component | Image | Namespace | Ports | Notes |
|-----------|-------|-----------|-------|-------|
| **ingest-readsb** | `ghcr.io/bharatradar/readsb` | bharatradar | 30004, 30005 | Receives feeder data via FRP |
| **hub-readsb** | `ghcr.io/bharatradar/readsb` | bharatradar | 30004, 30005 | Aggregates ingest data |
| **planes-readsb** | `ghcr.io/bharatradar/docker-tar1090-uuid` | bharatradar | 80, 30152 | Public tar1090 map with UUID tracking |
| **mlat-mlat-server** | `ghcr.io/bharatradar/mlat-server` | bharatradar | 31090, 30104 | MLAT processing |
| **mlat-map** | `ghcr.io/bharatradar/mlat-server-sync-map` | bharatradar | 80 | MLAT coverage map (nginx proxies API) |
| **reapi-readsb** | `ghcr.io/bharatradar/readsb` | bharatradar | 30006 | REST API data feed |
| **external-readsb** | `ghcr.io/bharatradar/readsb` | bharatradar | 30004 | External feeds (cnvr.io) |
| **api** | `ghcr.io/bharatradar/api` | bharatradar | 8080 | Main web API |
| **history** | `ghcr.io/bharatradar/history` | bharatradar | 8080, 80 | Historical data (amd64 only) |
| **haproxy** | `haproxy:2.7` | bharatradar | 80, 443 | Load balancer (3 replicas) |
| **redis** | `redis:alpine` | bharatradar | 6379 | Cache |
| **PostgreSQL** | `postgresql` (apt) | shared-services | 5432 | K3s external datastore |
| **Redis** | `redis-server` (apt) | shared-services | 6379 | API cache |
| **InfluxDB** | `influxdb2` | shared-services | 8086 | Metrics storage |

### Custom Images

All images are built with `--platform linux/amd64,linux/arm64` and pushed to `ghcr.io/bharatradar/`.

| Image | Source | Purpose |
|-------|--------|---------|
| `ghcr.io/bharatradar/readsb` | `ghcr.io/wiedehopf/readsb` | Base readsb image |
| `ghcr.io/bharatradar/docker-tar1090-uuid` | `ghcr.io/sdr-enthusiasts/docker-tar1090` + uuids | tar1090 with UUID tracking (`rId` in aircraft.json) |
| `ghcr.io/bharatradar/mlat-server` | `ghcr.io/adsblol/mlat-server` | MLAT processing server |
| `ghcr.io/bharatradar/mlat-server-sync-map` | `ghcr.io/adsblol/mlat-server-sync-map` + nginx proxy | MLAT coverage map with `/api/0/mlat-server/` reverse proxy |
| `ghcr.io/bharatradar/api` | `ghcr.io/adsblol/api` | REST API service |
| `ghcr.io/bharatradar/history` | `ghcr.io/adsblol/history` | Historical data (amd64 only) |

### Subdomains

| Subdomain | Service | Notes |
|-----------|---------|-------|
| `map.bharat-radar.vellur.in` | planes-readsb | tar1090 map interface |
| `my.bharat-radar.vellur.in` | api | Personalized feeder map (IP-based lookup) |
| `mlat.bharat-radar.vellur.in` | mlat-map | MLAT coverage visualization |
| `history.bharat-radar.vellur.in` | history | Historical flight data |
| `api.bharat-radar.vellur.in` | api | Main web API |
| `bharat-radar.vellur.in` | website | Homepage / documentation |
| `feed.bharat-radar.vellur.in` | AWS FRP server | Feeder endpoint (ports 30004, 31090) |
| `map.bharat-radar.vellur.in/re-api` | planes-readsb | readsb HTTP API for feeders |

## Known Limitations

**FRP & Feeder IP Tracking:** All feeder connections currently route through FRP (AWS EC2 tunnel), which means readsb records the internal tunnel IP (`10.42.0.1`) instead of the feeder's real public IP. This causes the `my.bharat-radar.vellur.in` IP-based feeder lookup to fall back to single-feeder mode while FRP is active. Once FRP is removed and feeders connect directly to the cluster, IP matching will work automatically for all feeders.

## How?

### Quick Deploy (Recommended)

One-liner install on each machine — follow the wizard:

```bash
curl -Ls https://raw.githubusercontent.com/ragavellur/infra/main/scripts/bharatradar-install | sudo bash
```

Or non-interactive:

> **Note:** The `--` after `bash -s` is required. It tells bash to stop parsing options and pass everything after to the script. Without it, arguments like `--conf-file` will be rejected as invalid bash options.

```bash
# 1. Shared services (PostgreSQL + Redis + InfluxDB)
curl -Ls https://raw.githubusercontent.com/ragavellur/infra/main/scripts/bharatradar-install | sudo bash -s -- shared-services

# 2. Primary Hub (first K3s server, use DB connection string from step 1)
curl -Ls https://raw.githubusercontent.com/ragavellur/infra/main/scripts/bharatradar-install | sudo bash -s -- hub

# 2b. Primary Hub with Keepalived VIP (prepares for HA failover)
curl -Ls https://raw.githubusercontent.com/ragavellur/infra/main/scripts/bharatradar-install | sudo bash -s -- --conf-file /tmp/hub.env hub
#   # In /tmp/hub.env: KEEPALIVED_ENABLED=true  KEEPALIVED_VIP=192.168.200.150

# 3a. HA Server (second K3s server, joins same DB)
curl -Ls https://raw.githubusercontent.com/ragavellur/infra/main/scripts/bharatradar-install | sudo bash -s -- ha-server

# 3b. Worker Node (K3s agent, joins via Hub)
curl -Ls https://raw.githubusercontent.com/ragavellur/infra/main/scripts/bharatradar-install | sudo bash -s -- worker

# Feeder Pi (RTL-SDR, standalone)
curl -Ls https://raw.githubusercontent.com/ragavellur/infra/main/scripts/bharatradar-install | sudo bash -s -- feeder
```

> **Automatic Resume:** If the installer is interrupted (network error, package failure, etc.), simply re-run the same command. It will detect saved progress and resume from the last completed phase.
>
> **Silent Install:** Pass a config file to skip all prompts: `--conf-file /path/to/config.env`. See [install.md](install.md) for full details including checkpoint phases and the complete configuration reference.

### Manual Deploy (kustomize)

```bash
# Preview manifests
kustomize build manifests/default

# Deploy to cluster
kustomize build manifests/default | kubectl apply -f -

# Verify
kubectl get pods -n bharatradar
```

Full installer docs: [scripts/README.md](scripts/README.md)

## Where?

- **GitHub:** https://github.com/ragavellur/infra
- **Images:** https://github.com/orgs/bharatradar/packages
- **Original Project:** https://github.com/adsblol/infra
