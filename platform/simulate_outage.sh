#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENVS_DIR="$ROOT_DIR/envs"

ENV_ID=""
MODE=""

# Parse flags
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

# Safety guard — never simulate against infrastructure containers
PROTECTED_CONTAINERS=("sandbox-nginx" "sandbox-daemon" "sandbox-api" "sandbox-loki" "sandbox-grafana" "sandbox-prometheus")
CONTAINER_NAME="sandbox-$ENV_ID"

for protected in "${PROTECTED_CONTAINERS[@]}"; do
  if [[ "$CONTAINER_NAME" == "$protected" ]]; then
    echo "ERROR: Cannot simulate outage against protected infrastructure container: $CONTAINER_NAME"
    exit 1
  fi
done

# Verify env exists
STATE_FILE="$ENVS_DIR/$ENV_ID.json"
if [[ ! -f "$STATE_FILE" ]]; then
  echo "ERROR: Environment $ENV_ID not found"
  exit 1
fi

# Verify container is a sandbox env (must have sandbox.managed label)
LABEL_CHECK=$(docker inspect "$CONTAINER_NAME" --format '{{index .Config.Labels "sandbox.managed"}}' 2>/dev/null || echo "")
if [[ "$LABEL_CHECK" != "true" ]]; then
  echo "ERROR: Container $CONTAINER_NAME is not a managed sandbox env"
  exit 1
fi

TS="[$(date -u +"%Y-%m-%dT%H:%M:%SZ")]"

update_status() {
  local new_status="$1"
  python3 - <<PYEOF
import json
with open('$STATE_FILE') as f:
    d = json.load(f)
d['status'] = '$new_status'
with open('$STATE_FILE', 'w') as f:
    json.dump(d, f, indent=2)
PYEOF
}

case "$MODE" in
  crash)
    echo "$TS [SIMULATE] Crashing container $CONTAINER_NAME"
    docker kill "$CONTAINER_NAME"
    update_status "crashed"
    echo "$TS [SIMULATE] Container killed — health monitor should detect within 90s"
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
    CURRENT_STATUS=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('status',''))" 2>/dev/null)

    case "$CURRENT_STATUS" in
      paused)
        docker unpause "$CONTAINER_NAME"
        echo "$TS [SIMULATE] Container unpaused"
        ;;
      crashed)
        docker start "$CONTAINER_NAME" 2>/dev/null || \
          echo "$TS [SIMULATE] Container could not be restarted (may need re-create)"
        echo "$TS [SIMULATE] Container restarted"
        ;;
      network-isolated)
        docker network connect "sandbox-$ENV_ID" "$CONTAINER_NAME" 2>/dev/null || true
        echo "$TS [SIMULATE] Network restored"
        ;;
      *)
        echo "$TS [SIMULATE] No known outage to recover from (status=$CURRENT_STATUS)"
        ;;
    esac
    update_status "running"
    ;;

  stress)
    echo "$TS [SIMULATE] Running CPU stress on $CONTAINER_NAME (requires stress-ng in container)"
    docker exec "$CONTAINER_NAME" sh -c \
      "which stress-ng && stress-ng --cpu 2 --timeout 30s || \
       (yes > /dev/null & yes > /dev/null & sleep 30 && kill %1 %2)" &
    echo "$TS [SIMULATE] CPU stress started for 30s"
    ;;

  *)
    echo "ERROR: Unknown mode '$MODE'. Valid modes: crash, pause, network, recover, stress"
    exit 1
    ;;
esac
