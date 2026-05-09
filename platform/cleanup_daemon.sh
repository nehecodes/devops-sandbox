#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENVS_DIR="$ROOT_DIR/envs"
LOGS_DIR="$ROOT_DIR/logs"
DESTROY_SCRIPT="$SCRIPT_DIR/destroy_env.sh"
CLEANUP_LOG="$LOGS_DIR/cleanup.log"

mkdir -p "$LOGS_DIR"

log() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" | tee -a "$CLEANUP_LOG"
}

log "Cleanup daemon started (PID $$)"

while true; do
  NOW=$(date +%s)

  if [[ -d "$ENVS_DIR" ]]; then
    for STATE_FILE in "$ENVS_DIR"/*.json 2>/dev/null; do
      [[ -f "$STATE_FILE" ]] || continue

      ENV_ID=$(basename "$STATE_FILE" .json)

      # Parse state file
      CREATED_TS=$(python3 -c "import json,sys; d=json.load(open('$STATE_FILE')); print(d.get('created_ts', 0))" 2>/dev/null || echo 0)
      TTL=$(python3 -c "import json,sys; d=json.load(open('$STATE_FILE')); print(d.get('ttl', 1800))" 2>/dev/null || echo 1800)
      STATUS=$(python3 -c "import json,sys; d=json.load(open('$STATE_FILE')); print(d.get('status','running'))" 2>/dev/null || echo "running")

      EXPIRES_AT=$((CREATED_TS + TTL))
      REMAINING=$((EXPIRES_AT - NOW))

      if [[ $NOW -gt $EXPIRES_AT ]]; then
        log "TTL expired for $ENV_ID (expired ${REMAINING#-}s ago) — destroying"
        bash "$DESTROY_SCRIPT" "$ENV_ID" >> "$CLEANUP_LOG" 2>&1 && \
          log "Successfully destroyed $ENV_ID" || \
          log "ERROR: Failed to destroy $ENV_ID"
      else
        log "  $ENV_ID: ${REMAINING}s remaining (status=$STATUS)"
      fi
    done
  fi

  log "Cleanup cycle complete — sleeping 60s"
  sleep 60
done
