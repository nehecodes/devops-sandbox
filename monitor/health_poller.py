#!/usr/bin/env python3
"""Health monitor — polls /health on all active envs every 30s."""

import json
import time
import urllib.request
import urllib.error
from pathlib import Path
from datetime import datetime, timezone

ROOT_DIR = Path(__file__).parent.parent
ENVS_DIR = ROOT_DIR / "envs"
LOGS_DIR = ROOT_DIR / "logs"

POLL_INTERVAL = 30
FAILURE_THRESHOLD = 3

# Track consecutive failures per env
failure_counts: dict[str, int] = {}


def log_health(env_id: str, record: dict) -> None:
    log_dir = LOGS_DIR / env_id
    log_dir.mkdir(parents=True, exist_ok=True)
    with open(log_dir / "health.log", "a") as f:
        f.write(json.dumps(record) + "\n")


def update_status(state_file: Path, new_status: str) -> None:
    try:
        with open(state_file) as f:
            d = json.load(f)
        d["status"] = new_status
        with open(state_file, "w") as f:
            json.dump(d, f, indent=2)
    except Exception as e:
        print(f"[WARN] Could not update status in {state_file}: {e}")


def poll_env(env_id: str, state: dict) -> None:
    port = state.get("port")
    status = state.get("status", "running")

    if status in ("crashed", "destroyed"):
        return

    if not port:
        return

    # Try /health first, fall back to / — httpbin and many images lack /health
    health_path = "/health"
    url = f"http://localhost:{port}{health_path}"
    ts = datetime.now(timezone.utc).isoformat()
    start = time.monotonic()
    http_status = None
    error = None

    try:
        req = urllib.request.Request(
            url, headers={"User-Agent": "sandbox-health-monitor/1.0"}
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            http_status = resp.status
            latency_ms = round((time.monotonic() - start) * 1000, 1)
    except urllib.error.HTTPError as e:
        http_status = e.code
        latency_ms = round((time.monotonic() - start) * 1000, 1)
    except Exception as e:
        latency_ms = round((time.monotonic() - start) * 1000, 1)
        error = str(e)

    is_healthy = http_status is not None and http_status < 500

    record = {
        "timestamp": ts,
        "env_id": env_id,
        "http_status": http_status,
        "latency_ms": latency_ms,
        "healthy": is_healthy,
    }
    if error:
        record["error"] = error

    log_health(env_id, record)

    if is_healthy:
        failure_counts[env_id] = 0
        if status == "degraded":
            # Auto-recover status
            state_file = ENVS_DIR / f"{env_id}.json"
            update_status(state_file, "running")
            print(f"[{ts}] {env_id} recovered (HTTP {http_status}, {latency_ms}ms)")
    else:
        failure_counts[env_id] = failure_counts.get(env_id, 0) + 1
        count = failure_counts[env_id]
        print(
            f"[{ts}] {env_id} UNHEALTHY ({error or f'HTTP {http_status}'}) [{count}/{FAILURE_THRESHOLD}]"
        )

        if count >= FAILURE_THRESHOLD and status not in (
            "degraded",
            "crashed",
            "paused",
            "network-isolated",
        ):
            state_file = ENVS_DIR / f"{env_id}.json"
            update_status(state_file, "degraded")
            print(
                f"[{ts}] ⚠️  WARNING: {env_id} marked as DEGRADED after {count} consecutive failures"
            )


def run_poll_cycle() -> None:
    if not ENVS_DIR.exists():
        return

    for state_file in ENVS_DIR.glob("*.json"):
        env_id = state_file.stem
        try:
            with open(state_file) as f:
                state = json.load(f)
            poll_env(env_id, state)
        except Exception as e:
            print(f"[ERROR] Failed to poll {env_id}: {e}")


def main() -> None:
    print(
        f"[{datetime.now(timezone.utc).isoformat()}] Health monitor started (interval={POLL_INTERVAL}s, threshold={FAILURE_THRESHOLD})"
    )

    while True:
        run_poll_cycle()
        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
