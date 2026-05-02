# bharatradar/infra

BharatRadar ADS-B/MLAT aggregator platform. Aggregates [ADS-B](https://github.com/wiedehopf/readsb) & [MLAT](https://github.com/wiedehopf/mlat-server) data from multiple feeders and serves a public map interface.

## Why?

Community-driven ADS-B aggregation, built as a fork of [adsblol/infra](https://github.com/adsblol/infra). All upstream images are mirrored to `ghcr.io/bharatradar/` with multi-arch support (amd64 + arm64) for Raspberry Pi compatibility.

## Architecture

```
Feeder Pi (RTL-SDR) ──→ feed.bharat-radar.vellur.in:30004 (AWS EC2 FRP) ──→ Hub ingest
                                                                                   │
                                                                                    v
              Hub (Ubuntu i7, K3s server) ←─── br-aggrigator (Pi, K3s agent)
               /    |    |    |    |    \                   (failover node)
         ingest  hub  planes  api  mlat  mlat-map
           |      |     |      |     |
        external  reapi  redis  haproxy(3x)
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
| **Hub** | 192.168.200.145 | Ubuntu 24.04 (Core i7) | K3s server, runs all services | amd64 |
| **br-aggrigator** | 192.168.200.187 | Debian 12 (Raspberry Pi) | K3s agent, failover node | arm64 |
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
| `mlat.bharat-radar.vellur.in` | mlat-map | MLAT coverage visualization |
| `history.bharat-radar.vellur.in` | history | Historical flight data |
| `bharat-radar.vellur.in` | api | Main web API / homepage |
| `feed.bharat-radar.vellur.in` | AWS FRP server | Feeder endpoint (ports 30004, 31090) |

## How?

```bash
# Preview manifests
kustomize build manifests/default

# Deploy to cluster
kustomize build manifests/default | kubectl apply -f -

# Verify
kubectl get pods -n bharatradar
```

## Where?

- **GitHub:** https://github.com/ragavellur/infra
- **Images:** https://github.com/orgs/bharatradar/packages
- **Original Project:** https://github.com/adsblol/infra
