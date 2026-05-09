#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENVS_DIR="$ROOT_DIR/envs"
LOGS_DIR="$ROOT_DIR/logs"
NGINX_CONF_DIR="$ROOT_DIR/nginx/conf.d"

ENV_NAME="${1:-}"
TTL="${2:-1800}"  # default 30 minutes

if [[ -z "$ENV_NAME" ]]; then
  echo "Usage: $0 <name> [ttl_seconds]"
  exit 1
fi

# Generate unique env ID
ENV_ID="env-$(echo "$ENV_NAME" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//;s/-*$//')-$(date +%s | tail -c 6)"
CREATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
CREATED_TS=$(date +%s)
PORT=$(shuf -i 8100-8999 -n 1)

# Ensure dirs
mkdir -p "$ENVS_DIR" "$LOGS_DIR/$ENV_ID" "$NGINX_CONF_DIR"

echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Creating environment: $ENV_ID (name=$ENV_NAME, ttl=${TTL}s)"

# Create dedicated Docker network
docker network create "sandbox-$ENV_ID" \
  --label "sandbox.env=$ENV_ID" \
  --label "sandbox.managed=true" 2>/dev/null || true

# Connect nginx container to env network (if running)
if docker ps --format '{{.Names}}' | grep -q '^sandbox-nginx$'; then
  docker network connect "sandbox-$ENV_ID" sandbox-nginx 2>/dev/null || true
fi

# Start app container (using a simple demo app image)
APP_IMAGE="${SANDBOX_APP_IMAGE:-kennethreitz/httpbin}"
docker run -d \
  --name "sandbox-$ENV_ID" \
  --network "sandbox-$ENV_ID" \
  --label "sandbox.env=$ENV_ID" \
  --label "sandbox.name=$ENV_NAME" \
  --label "sandbox.managed=true" \
  -p "$PORT:80" \
  -e "ENV_ID=$ENV_ID" \
  -e "ENV_NAME=$ENV_NAME" \
  "$APP_IMAGE" > /dev/null

# Write state file
cat > "$ENVS_DIR/$ENV_ID.json" <<EOF
{
  "id": "$ENV_ID",
  "name": "$ENV_NAME",
  "created_at": "$CREATED_AT",
  "created_ts": $CREATED_TS,
  "ttl": $TTL,
  "port": $PORT,
  "status": "running",
  "container": "sandbox-$ENV_ID",
  "network": "sandbox-$ENV_ID"
}
EOF

# Write Nginx config
cat > "$NGINX_CONF_DIR/$ENV_ID.conf" <<EOF
upstream $ENV_ID {
    server sandbox-$ENV_ID:80;
}

location /env/$ENV_ID/ {
    proxy_pass http://$ENV_ID/;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Env-ID $ENV_ID;
    proxy_connect_timeout 5s;
    proxy_read_timeout 30s;
}
EOF

# Reload nginx if running
if docker ps --format '{{.Names}}' | grep -q '^sandbox-nginx$'; then
  docker exec sandbox-nginx nginx -s reload 2>/dev/null && \
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Nginx reloaded for $ENV_ID" || true
fi

# Start log shipping (Approach A)
mkdir -p "$LOGS_DIR/$ENV_ID"
nohup docker logs -f "sandbox-$ENV_ID" >> "$LOGS_DIR/$ENV_ID/app.log" 2>&1 &
echo $! > "$LOGS_DIR/$ENV_ID/log_shipper.pid"

EXPIRES_AT=$(date -u -d "@$((CREATED_TS + TTL))" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
             date -u -r "$((CREATED_TS + TTL))" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
             echo "N/A")

echo ""
echo "✓ Environment created successfully"
echo "  ID:      $ENV_ID"
echo "  Name:    $ENV_NAME"
echo "  URL:     http://localhost/env/$ENV_ID/"
echo "  Direct:  http://localhost:$PORT/"
echo "  TTL:     ${TTL}s (expires $EXPIRES_AT)"
echo ""
