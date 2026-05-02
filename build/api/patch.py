import re

# Patch settings.py to add MY_DOMAIN env var
with open('/app/src/adsb_api/utils/settings.py', 'r') as f:
    settings_content = f.read()
if 'MY_DOMAIN' not in settings_content:
    settings_content = settings_content.replace(
        'INSECURE = os.getenv',
        'MY_DOMAIN = os.environ.get("MY_DOMAIN", "my.bharat-radar.vellur.in")\nINSECURE = os.getenv'
    )
    with open('/app/src/adsb_api/utils/settings.py', 'w') as f:
        f.write(settings_content)

# Patch provider.py
with open('/app/src/adsb_api/utils/provider.py', 'r') as f:
    content = f.read()

# Add MY_DOMAIN to settings import
if 'MY_DOMAIN' not in content:
    content = content.replace(
        'from adsb_api.utils.settings import (INGEST_DNS',
        'from adsb_api.utils.settings import (MY_DOMAIN, INGEST_DNS'
    )

# Replace hardcoded my.adsb.lol in _dedupe with MY_DOMAIN
content = content.replace(
    '"adsblol_my_url": f"https://{_humanhash(c[0][:18], SALT_MY)}.my.adsb.lol"',
    '"adsblol_my_url": f"https://{_humanhash(c[0][:18], SALT_MY)}.{MY_DOMAIN}"'
)

# Fix IP extraction: host:port field is like "  10.42.0.1 port 25639"
# split()[0] gives the IP, split()[1] wrongly gave "port"
content = content.replace(
    '"ip": c[1].split()[1]',
    '"ip": c[1].split()[0]'
)

with open('/app/src/adsb_api/utils/provider.py', 'w') as f:
    f.write(content)

# Patch app.py
with open('/app/src/adsb_api/app.py', 'r') as f:
    content = f.read()

# Add MY_DOMAIN to settings import
if 'MY_DOMAIN,' not in content:
    content = content.replace(
        'from adsb_api.utils.settings import (INSECURE,',
        'from adsb_api.utils.settings import (INSECURE, MY_DOMAIN,'
    )

old_my = '''@app.get("/0/my", tags=["v0"], summary="My Map redirect based on IP")
@app.get("/api/0/my", tags=["v0"], summary="My Map redirect based on IP", include_in_schema=False)
async def api_my(request: Request):
    client_ip = request.client.host
    my_beast_clients = await provider.get_clients_per_client_ip(client_ip)
    uids = []
    if len(my_beast_clients) == 0:
        return RedirectResponse(
            url="https://adsb.lol#sorry-but-i-could-not-find-your-receiver?"
        )
    for client in my_beast_clients:
        uids.append(client["adsblol_my_url"].split("https://")[1].split(".")[0])
    # redirect to
    # uid1_uid2.my.adsb.lol
    host = "https://" + "_".join(uids) + ".my.adsb.lol"
    return RedirectResponse(url=host)'''

new_my = '''def _get_client_ip(request: Request) -> str:
    """Get real client IP, respecting X-Real-IP from nginx sidecar."""
    x_real_ip = request.headers.get("X-Real-IP")
    if x_real_ip:
        return x_real_ip.split(",")[0].strip()
    x_forwarded_for = request.headers.get("X-Forwarded-For")
    if x_forwarded_for:
        return x_forwarded_for.split(",")[0].strip()
    return request.client.host


@app.get("/", include_in_schema=False)
async def my_root(request: Request):
    """Root redirect: IP lookup \u2192 personal map or public map.

    Behavior:
    - 1 feeder matches visitor IP \u2192 map.bharat-radar.vellur.in/?filter_uuid=<uuid>
    - 0 feeders match \u2192 map.bharat-radar.vellur.in (public map)
    - >1 feeders match same IP \u2192 map.bharat-radar.vellur.in/#sorry-but-i-could-not-find-your-receiver?

    Note: IP matching requires feeders to connect directly to the cluster.
    Feeders behind proxies/FRP will not match until the infrastructure changes.
    """
    client_ip = _get_client_ip(request)
    all_clients = await provider._json_get("beast:clients") or []
    my_clients = [c for c in all_clients if c.get("ip") == client_ip]

    if len(my_clients) == 1:
        uuid = my_clients[0]["_uuid"][:18]
        return RedirectResponse(url=f"https://map.bharat-radar.vellur.in/?filter_uuid={uuid}")

    if len(my_clients) > 1:
        return RedirectResponse(
            url=f"https://map.bharat-radar.vellur.in/#sorry-but-i-could-not-find-your-receiver?"
        )

    # No match: fall back to all clients (for CGNAT / proxy scenarios)
    if len(all_clients) == 1:
        uuid = all_clients[0]["_uuid"][:18]
        return RedirectResponse(url=f"https://map.bharat-radar.vellur.in/?filter_uuid={uuid}")
    if len(all_clients) > 1:
        return RedirectResponse(
            url=f"https://map.bharat-radar.vellur.in/#sorry-but-i-could-not-find-your-receiver?"
        )

    return RedirectResponse(url="https://map.bharat-radar.vellur.in")


@app.get("/0/my", tags=["v0"], summary="My Map redirect based on IP")
@app.get("/api/0/my", tags=["v0"], summary="My Map redirect based on IP", include_in_schema=False)
async def api_my(request: Request):
    """Legacy endpoint - redirects to /."""
    return RedirectResponse(url=f"https://{MY_DOMAIN}/")'''

content = content.replace(old_my, new_my)

with open('/app/src/adsb_api/app.py', 'w') as f:
    f.write(content)

print("Patches applied successfully")
