FROM ghcr.io/adsblol/mlat-server-sync-map:latest

RUN cat > /usr/share/nginx/html/index.html << 'HTMLEOF'
<!DOCTYPE html>
<html>
<head><meta http-equiv="refresh" content="0; url=/syncmap/"></head>
<body><a href="/syncmap/">MLAT Coverage Map</a></body>
</html>
HTMLEOF

RUN cat > /etc/nginx/conf.d/default.conf << 'NGINXEOF'
server {
    listen 80;
    server_name localhost;

    location /api/0/mlat-server/ {
        rewrite ^/api/0/mlat-server/[^/]+/(.*)$ /$1 break;
        proxy_pass http://mlat-mlat-server.bharatradar.svc.cluster.local:150;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }

    location / {
        root /usr/share/nginx/html;
        index index.html index.htm;
    }
}
NGINXEOF
