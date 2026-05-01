# AGENTS.md - adsblol/infra

## Quick Verification
kustomize build manifests/default  # Build and preview final manifests

## Architecture
Data flow: user → ingest → hub → planes
              └→ mlat ↗

Services (manifests/default):
- haproxy/     Load balancer (3 replicas)
- ingest/     Public ADS-B ingest
- external/   External feeds (cnvr.io)
- hub/        Aggregation layer
- mlat/       MLAT server (disabled - needs archived image)
- reapi/      REST API
- planes/     Public map (disabled - needs rclone secret)
- mlat-map/   MLAT sync UI ✅
- api/        Main web API ✅
- history/    Historical data (archived - disabled)
- redis/      Cache
- resources.yaml  Namespace, Services, Ingresses, NetworkPolicies

## Conventions
- bases/     Reusable Kubernetes components
- */base/    Inherits from bases/
- */default/ Adds env vars, image overrides, patches
- namePrefix used for service isolation (e.g., ingest-readsb, hub-readsb)

## Deployment
- Flux watches this repo → manifests/default
- ExternalSecrets from Vault (identity, known_hosts, rclone.conf)
- GHCR images need authentication - add imagePullSecrets to deployments

## Owner
@adsblol/sre

## Notes
- Some adsblol repos are archived (history) - images not being built
- MLAT needs custom mlat-server image (not available publicly)
- Planes needs adsblol-rclone secret for cloud storage