# AGENTS.md - bharatradar/infra

> **Versions:** Installer v5.3.1 | Docs v3.3.0 | API Image v5.0.0

## Quick Verification
kustomize build manifests/default  # Build and preview final manifests

## Architecture
Data flow: user → ingest → hub → planes
              └→ mlat ↗

### Nodes
| Node | IP | Role | OS | Arch |
|------|----|------|----|------|
| Hub | 192.168.200.145 | K3s server (MASTER) | Ubuntu 24.04 (Core i7) | amd64 |
| HA Server | 192.168.200.186 | K3s server (BACKUP) | Ubuntu 24.04 | amd64 |
| br-aggrigator | 192.168.200.187 | K3s agent + Shared Services (PostgreSQL, Redis, InfluxDB, MinIO) | Debian 12 (Raspberry Pi) | arm64 |
| Feeder Pi | 192.168.200.127 | RTL-SDR readsb + mlat-client (not K3s) | Raspberry Pi OS | arm64 |

Services (manifests/default):
- ingest/     Public ADS-B ingest via LoadBalancer (ghcr.io/bharatradar/readsb)
- external/   External feeds (cnvr.io)
- hub/        Aggregation layer
- mlat/       MLAT server ✅ running (ghcr.io/bharatradar/mlat-server)
- reapi/      REST API backend (readsb with --net-api-port=30152)
- planes/     Public map ✅ running (ghcr.io/bharatradar/docker-tar1090-uuid)
- mlat-map/   MLAT sync UI ✅ running (nginx proxies /api/0/mlat-server/)
- api/        Main web API ✅ running v5.0.0 (ghcr.io/bharatradar/api:5.0.0)
- history/    Historical data ✅ running (amd64 only, dummy rclone secret)
- website/    Homepage
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
- `api` ← ghcr.io/adsblol/api + patches (v2 routes, MY_DOMAIN, Redis, nginx routes)
- `history` ← ghcr.io/adsblol/history (amd64 only)

## Deployment
- Manual: `kustomize build manifests/default | kubectl apply -f -`
- Namespace: `bharatradar`
- GHCR pull secret: `ghcr-secret` in `bharatradar` namespace (required for all deployments)
- History has `nodeSelector: kubernetes.io/arch: amd64`

## API (v5.0.0)
- Image: `ghcr.io/bharatradar/api:5.0.0`
- OpenAPI schema: 18 paths (4 v0 + 14 v2)
- v2 endpoints: /v2/pia, /v2/mil, /v2/ladd, /v2/squawk/{squawk}, /v2/sqk/{squawk}, /v2/type/{aircraft_type}, /v2/reg/{registration}, /v2/registration/{registration}, /v2/hex/{icao_hex}, /v2/icao/{icao_hex}, /v2/callsign/{callsign}, /v2/point/{lat}/{lon}/{radius}, /v2/lat/{lat}/lon/{lon}/dist/{radius}, /v2/closest/{lat}/{lon}/{radius}
- Path parameters work in Swagger UI "Try it out" mode
- ReAPI backend: `reapi-readsb.bharatradar.svc.cluster.local:30152`
- Requires `--net-api-port=30152` on reapi-readsb deployment

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
- `my.bharat-radar.vellur.in/` redirects to `map.bharat-radar.vellur.in/?filter_uuid=<uuid>` based on IP lookup from Redis `beast:clients`
- API image built from `build/api/` which patches upstream `ghcr.io/adsblol/api` at runtime
- v2 route registration bug fixed in v5.0.0 by removing broken decorator pattern
- ReAPI port (--net-api-port=30152) required for v2 endpoints to fetch aircraft data

## TODO / Future Enhancements
- **Remove FRP tunnel**: Move feeder connections to direct cluster IPs or use a proper load balancer. This will fix IP-based feeder identification on `my.bharat-radar.vellur.in`. The FRP tunnel obscures real client IPs, causing the API to see internal Traefik pod IPs instead of feeder public IPs.
- **Feeder self-registration script**: A bash script for feeders to register their UUID without DNS access:
  1. Script runs on feeder Pi
  2. Calls `/api/0/my` to get UUIDs of all feeders
  3. Matches local MAC or hostname to UUID
  4. Prints personalized map URL (`map.bharat-radar.vellur.in/?filter_uuid=<uuid>`)
  5. Useful if FRP stays long-term or for feeders behind CGNAT/proxies
- **Shared Storage for PVCs**: Use Longhorn, NFS, or Ceph to replace local-path provisioner. This will allow `planes-readsb` and `mlat-mlat-server` to fail over to the HA Server during Primary Hub failures.
- **DaemonSet for Beast/MLAT**: Run ingest-readsb and mlat-mlat-server as DaemonSets on both Hub nodes. Eliminates 30-60s pod reschedule window during failover. See install.md v3.3.0 for details.
- **Traefik IP Forwarding**: Investigate Traefik `ForwardedHeaders` or `trustForwardHeader` to preserve `X-Real-IP` from the AWS nginx proxy. Currently the API sees Traefik pod IPs, breaking IP-based lookups even for direct connections.
- **Automated API Image Rebuild**: The `api:5.0.0` image relies on runtime patches (`build/api/patch.py`) to replace hardcoded `adsb.lol` references. A proper CI/CD pipeline should build a patched image at build time rather than runtime.
- **Version Pinning**: K3s installer currently downloads latest stable. Pin to a specific version (e.g., v1.35.4+k3s1) for reproducible deployments.
