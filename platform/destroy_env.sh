#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENVS_DIR="$ROOT_DIR/envs"
LOGS_DIR="$ROOT_DIR/logs"
NGINX_CONF_DIR="$ROOT_DIR/nginx/conf.d"

ENV_ID="${1:-}"

if [[ -z "$ENV_ID" ]]; then
  echo "Usage: $0 <env-id>"
  exit 1
fi

STATE_FILE="$ENVS_DIR/$ENV_ID.json"

if [[ ! -f "$STATE_FILE" ]]; then
  echo "[WARN] State file not found for $ENV_ID — attempting cleanup anyway"
fi

echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Destroying environment: $ENV_ID"

# Stop log shipper
PID_FILE="$LOGS_DIR/$ENV_ID/log_shipper.pid"
if [[ -f "$PID_FILE" ]]; then
  LOG_PID=$(cat "$PID_FILE")
  kill "$LOG_PID" 2>/dev/null && echo "  Stopped log shipper (PID $LOG_PID)" || true
  rm -f "$PID_FILE"
fi

# Stop and remove all labeled containers
echo "  Removing containers..."
docker ps -a --filter "label=sandbox.env=$ENV_ID" --format "{{.ID}}" | \
  xargs -r docker rm -f 2>/dev/null || true

# Remove Docker network
echo "  Removing network..."
docker network rm "sandbox-$ENV_ID" 2>/dev/null || true

# Remove Nginx config and reload
NGINX_CONF="$NGINX_CONF_DIR/$ENV_ID.conf"
if [[ -f "$NGINX_CONF" ]]; then
  rm -f "$NGINX_CONF"
  echo "  Removed Nginx config"
fi

if docker ps --format '{{.Names}}' | grep -q '^sandbox-nginx$'; then
  docker exec sandbox-nginx nginx -s reload 2>/dev/null && \
    echo "  Nginx reloaded" || true
fi

# Archive logs
ARCHIVE_DIR="$LOGS_DIR/archived/$ENV_ID"
mkdir -p "$ARCHIVE_DIR"
if [[ -d "$LOGS_DIR/$ENV_ID" ]]; then
  cp -r "$LOGS_DIR/$ENV_ID/." "$ARCHIVE_DIR/" 2>/dev/null || true
  # Add destroy timestamp
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Environment destroyed" >> "$ARCHIVE_DIR/lifecycle.log"
  rm -rf "$LOGS_DIR/$ENV_ID"
  echo "  Logs archived to $ARCHIVE_DIR"
fi

# Delete state file
if [[ -f "$STATE_FILE" ]]; then
  rm -f "$STATE_FILE"
fi

echo "✓ Environment $ENV_ID destroyed"
