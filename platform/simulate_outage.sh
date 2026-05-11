#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENVS_DIR="$ROOT_DIR/envs"

ENV_ID=""
MODE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENV_ID="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

if [[ -z "$ENV_ID" || -z "$MODE" ]]; then
  echo "Usage: $0 --env <env-id> --mode <crash|pause|network|recover|stress>"
  exit 1
fi

PROTECTED_CONTAINERS=("sandbox-nginx" "sandbox-daemon" "sandbox-api" "sandbox-loki" "sandbox-grafana" "sandbox-prometheus")
CONTAINER_NAME="sandbox-$ENV_ID"

for protected in "${PROTECTED_CONTAINERS[@]}"; do
  if [[ "$CONTAINER_NAME" == "$protected" ]]; then
    echo "ERROR: Cannot simulate outage against protected infrastructure container: $CONTAINER_NAME"
    exit 1
  fi
done

STATE_FILE="$ENVS_DIR/$ENV_ID.json"
if [[ ! -f "$STATE_FILE" ]]; then
  echo "ERROR: Environment $ENV_ID not found"
  exit 1
fi

LABEL_CHECK=$(docker inspect "$CONTAINER_NAME" --format '{{index .Config.Labels "sandbox.managed"}}' 2>/dev/null || echo "")
if [[ "$LABEL_CHECK" != "true" ]]; then
  echo "ERROR: Container $CONTAINER_NAME is not a managed sandbox env"
  exit 1
fi

TS="[$(date -u +"%Y-%m-%dT%H:%M:%SZ")]"

update_status() {
  local new_status="$1"
  # Fix ownership first if needed
  chown "$(whoami)" "$STATE_FILE" 2>/dev/null || sudo chown "$(whoami)" "$STATE_FILE" 2>/dev/null || true
  python3 -c "
import json
with open('$STATE_FILE') as f:
    d = json.load(f)
d['status'] = '$new_status'
with open('$STATE_FILE', 'w') as f:
    json.dump(d, f, indent=2)
print('  Status -> $new_status')
" 2>/dev/null || echo "  WARNING: could not write status (continuing)"
}

case "$MODE" in
  crash)
    echo "$TS [SIMULATE] Crashing container $CONTAINER_NAME"
    docker kill "$CONTAINER_NAME"
    update_status "crashed"
    echo "$TS [SIMULATE] Container killed"
    ;;

  pause)
    echo "$TS [SIMULATE] Pausing container $CONTAINER_NAME"
    docker pause "$CONTAINER_NAME"
    update_status "paused"
    echo "$TS [SIMULATE] Container paused — use --mode recover to unpause"
    ;;

  network)
    echo "$TS [SIMULATE] Disconnecting $CONTAINER_NAME from network sandbox-$ENV_ID"
    docker network disconnect "sandbox-$ENV_ID" "$CONTAINER_NAME" 2>/dev/null || true
    update_status "network-isolated"
    echo "$TS [SIMULATE] Network disconnected — use --mode recover to restore"
    ;;

  recover)
    echo "$TS [SIMULATE] Recovering $CONTAINER_NAME"

    CURRENT_STATUS=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('status','unknown'))" 2>/dev/null || echo "unknown")
    DOCKER_STATUS=$(docker inspect "$CONTAINER_NAME" --format '{{.State.Status}}' 2>/dev/null || echo "unknown")
    echo "$TS [SIMULATE] Docker=$DOCKER_STATUS  recorded=$CURRENT_STATUS"

    if [[ "$DOCKER_STATUS" == "paused" ]]; then
      docker unpause "$CONTAINER_NAME"
      echo "$TS [SIMULATE] Container unpaused"
    fi

    if [[ "$DOCKER_STATUS" == "exited" || "$DOCKER_STATUS" == "dead" ]]; then
      docker start "$CONTAINER_NAME" 2>/dev/null || true
      echo "$TS [SIMULATE] Container restarted"
    fi

    docker network connect "sandbox-$ENV_ID" "$CONTAINER_NAME" 2>/dev/null || true

    update_status "running"
    echo "$TS [SIMULATE] Recovery complete"
    ;;

  stress)
    echo "$TS [SIMULATE] CPU stress on $CONTAINER_NAME (30s)"
    docker exec "$CONTAINER_NAME" sh -c \
      "which stress-ng && stress-ng --cpu 2 --timeout 30s || \
       (yes > /dev/null & yes > /dev/null & sleep 30 && kill %1 %2 2>/dev/null)" &
    echo "$TS [SIMULATE] CPU stress started for 30s"
    ;;

  *)
    echo "ERROR: Unknown mode '$MODE'. Valid modes: crash, pause, network, recover, stress"
    exit 1
    ;;
esac
