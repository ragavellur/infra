# AGENTS.md - bharatradar/infra

## Quick Verification
kustomize build manifests/default  # Build and preview final manifests

## Architecture
Data flow: user → ingest → hub → planes
              └→ mlat ↗

### Nodes
| Node | IP | Role | OS | Arch |
|------|----|------|----|------|
| Hub | 192.168.200.145 | K3s server | Ubuntu 24.04 (Core i7) | amd64 |
| br-aggrigator | 192.168.200.187 | K3s agent | Debian 12 (Raspberry Pi) | arm64 |
| Feeder Pi | 192.168.200.127 | RTL-SDR readsb + mlat-client (not K3s) | Raspberry Pi OS | arm64 |

Services (manifests/default):
- haproxy/     Load balancer (3 replicas)
- ingest/     Public ADS-B ingest (ghcr.io/bharatradar/readsb)
- external/   External feeds (cnvr.io)
- hub/        Aggregation layer
- mlat/       MLAT server ✅ running (ghcr.io/bharatradar/mlat-server)
- reapi/      REST API
- planes/     Public map ✅ running (ghcr.io/bharatradar/docker-tar1090-uuid)
- mlat-map/   MLAT sync UI ✅ running (nginx proxies /api/0/mlat-server/)
- api/        Main web API ✅ running (ghcr.io/bharatradar/api)
- history/    Historical data ✅ running (amd64 only, dummy rclone secret)
- redis/      Cache
- resources.yaml  Namespace, Services, Ingresses, NetworkPolicies

## Conventions
- bases/     Reusable Kubernetes components
- */base/    Inherits from bases/
- */default/ Adds env vars, image overrides, patches
- namePrefix used for service isolation (e.g., ingest-readsb, hub-readsb)
- build/     Custom Dockerfiles for multi-arch images

## Custom Images
All built with `--platform linux/amd64,linux/arm64` and pushed to `ghcr.io/bharatradar/`:
- `readsb` ← ghcr.io/wiedehopf/readsb
- `docker-tar1090-uuid` ← ghcr.io/sdr-enthusiasts/docker-tar1090 + uuid binaries
- `mlat-server` ← ghcr.io/adsblol/mlat-server
- `mlat-server-sync-map` ← ghcr.io/adsblol/mlat-server-sync-map + nginx proxy
- `api` ← ghcr.io/adsblol/api
- `history` ← ghcr.io/adsblol/history (amd64 only)

## Deployment
- Manual: `kustomize build manifests/default | kubectl apply -f -`
- Namespace: `bharatradar`
- GHCR pull secret: `ghcr-secret` in `bharatradar` namespace (required for all deployments)
- History has `nodeSelector: kubernetes.io/arch: amd64`

## Feeder
- Feeder Pi (192.168.200.127) connects directly to `feed.bharat-radar.vellur.in:30004`
- Uses `bharat-feeder` systemd service (readsb --net-only --net-connector)
- Uses `bharat-mlat` systemd service (mlat-client → feed.bharat-radar.vellur.in:31090)
- Not part of Kubernetes cluster

## FRP
- Server on AWS EC2 (13.48.249.103): frps
- Client on Hub (192.168.200.145): frpc
- Proxies: TCP 30004/30005/31090 + HTTP/HTTPS for web + mlat-map

## Owner
@bharatradar/sre

## Key Notes
- All images are multi-arch (amd64 + arm64) for Pi compatibility
- UUID tracking enabled via custom docker-tar1090-uuid image (rId in aircraft.json)
- MLAT map has nginx reverse proxy for `/api/0/mlat-server/` endpoints
- Peers: {} on MLAT map is normal with single feeder (requires multiple receivers)
