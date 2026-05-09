#!/usr/bin/env python3
"""DevOps Sandbox Control API — Flask-based wrapper around platform scripts."""

import json
import os
import subprocess
import time
from pathlib import Path
from datetime import datetime, timezone

from flask import Flask, jsonify, request, abort

app = Flask(__name__)

ROOT_DIR = Path(__file__).parent.parent
ENVS_DIR = ROOT_DIR / "envs"
LOGS_DIR = ROOT_DIR / "logs"
PLATFORM_DIR = ROOT_DIR / "platform"

ENVS_DIR.mkdir(exist_ok=True)
LOGS_DIR.mkdir(exist_ok=True)


def load_env(env_id: str) -> dict:
    state_file = ENVS_DIR / f"{env_id}.json"
    if not state_file.exists():
        abort(404, description=f"Environment '{env_id}' not found")
    with open(state_file) as f:
        return json.load(f)


def list_envs() -> list[dict]:
    envs = []
    now = int(time.time())
    for f in ENVS_DIR.glob("*.json"):
        try:
            with open(f) as fh:
                d = json.load(fh)
            d["ttl_remaining"] = max(0, d["created_ts"] + d["ttl"] - now)
            envs.append(d)
        except Exception:
            pass
    return sorted(envs, key=lambda x: x.get("created_ts", 0), reverse=True)


def run_script(script: str, *args, timeout: int = 60) -> tuple[bool, str]:
    """Run a platform script, returning (success, output)."""
    cmd = ["bash", str(PLATFORM_DIR / script)] + list(args)
    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout
        )
        output = result.stdout + result.stderr
        return result.returncode == 0, output
    except subprocess.TimeoutExpired:
        return False, "Script timed out"
    except Exception as e:
        return False, str(e)


# ─── Endpoints ───────────────────────────────────────────────────────────────

@app.route("/envs", methods=["POST"])
def create_env():
    """POST /envs — Create a new environment."""
    data = request.get_json(silent=True) or {}
    name = data.get("name", "").strip()
    ttl = int(data.get("ttl", 1800))

    if not name:
        abort(400, description="Field 'name' is required")
    if not 60 <= ttl <= 86400:
        abort(400, description="TTL must be between 60 and 86400 seconds")

    ok, output = run_script("create_env.sh", name, str(ttl), timeout=60)
    if not ok:
        return jsonify({"error": "Failed to create environment", "detail": output}), 500

    # Extract env ID from output
    env_id = None
    for line in output.splitlines():
        if "ID:" in line:
            env_id = line.split("ID:")[1].strip()
            break

    if env_id:
        try:
            env = load_env(env_id)
            env["output"] = output
            return jsonify(env), 201
        except Exception:
            pass

    return jsonify({"created": True, "output": output}), 201


@app.route("/envs", methods=["GET"])
def list_environments():
    """GET /envs — List all active environments with TTL remaining."""
    envs = list_envs()
    return jsonify({"environments": envs, "count": len(envs)})


@app.route("/envs/<env_id>", methods=["DELETE"])
def destroy_env(env_id: str):
    """DELETE /envs/:id — Destroy a specific environment."""
    load_env(env_id)  # validates existence
    ok, output = run_script("destroy_env.sh", env_id, timeout=30)
    if not ok:
        return jsonify({"error": "Destroy failed", "detail": output}), 500
    return jsonify({"destroyed": True, "env_id": env_id, "detail": output})


@app.route("/envs/<env_id>/logs", methods=["GET"])
def get_logs(env_id: str):
    """GET /envs/:id/logs — Last 100 lines of app.log."""
    load_env(env_id)
    log_file = LOGS_DIR / env_id / "app.log"
    archived_log = LOGS_DIR / "archived" / env_id / "app.log"

    target = log_file if log_file.exists() else archived_log
    if not target.exists():
        return jsonify({"env_id": env_id, "lines": [], "note": "No logs yet"})

    try:
        result = subprocess.run(
            ["tail", "-n", "100", str(target)],
            capture_output=True, text=True
        )
        lines = result.stdout.splitlines()
    except Exception as e:
        return jsonify({"error": str(e)}), 500

    return jsonify({"env_id": env_id, "lines": lines, "count": len(lines)})


@app.route("/envs/<env_id>/health", methods=["GET"])
def get_health(env_id: str):
    """GET /envs/:id/health — Last 10 health check results."""
    load_env(env_id)
    health_file = LOGS_DIR / env_id / "health.log"
    archived = LOGS_DIR / "archived" / env_id / "health.log"

    target = health_file if health_file.exists() else archived
    if not target.exists():
        return jsonify({"env_id": env_id, "checks": [], "note": "No health data yet"})

    try:
        result = subprocess.run(
            ["tail", "-n", "10", str(target)],
            capture_output=True, text=True
        )
        raw_lines = result.stdout.strip().splitlines()
        checks = []
        for line in raw_lines:
            try:
                checks.append(json.loads(line))
            except Exception:
                checks.append({"raw": line})
    except Exception as e:
        return jsonify({"error": str(e)}), 500

    return jsonify({"env_id": env_id, "checks": checks, "count": len(checks)})


@app.route("/envs/<env_id>/outage", methods=["POST"])
def trigger_outage(env_id: str):
    """POST /envs/:id/outage — Trigger an outage simulation."""
    load_env(env_id)
    data = request.get_json(silent=True) or {}
    mode = data.get("mode", "").strip()

    valid_modes = ["crash", "pause", "network", "recover", "stress"]
    if mode not in valid_modes:
        abort(400, description=f"mode must be one of: {', '.join(valid_modes)}")

    ok, output = run_script("simulate_outage.sh", "--env", env_id, "--mode", mode, timeout=30)
    if not ok:
        return jsonify({"error": "Simulation failed", "detail": output}), 500

    return jsonify({"env_id": env_id, "mode": mode, "triggered": True, "detail": output})


@app.route("/health", methods=["GET"])
def api_health():
    """API self-health check."""
    envs = list_envs()
    return jsonify({
        "status": "ok",
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "active_environments": len(envs),
    })


@app.errorhandler(400)
@app.errorhandler(404)
@app.errorhandler(500)
def handle_error(e):
    return jsonify({"error": str(e.description)}), e.code


if __name__ == "__main__":
    port = int(os.environ.get("API_PORT", 5050))
    debug = os.environ.get("FLASK_DEBUG", "false").lower() == "true"
    print(f"Starting DevOps Sandbox API on port {port}")
    app.run(host="0.0.0.0", port=port, debug=debug)
