# devops-sandbox

A self-service platform for spinning up isolated temporary environments, deploying apps, simulating outages, and monitoring health — all on a single Linux VM. Think internal Heroku with a chaos engineering toggle.

## Quick Start

```bash
git clone https://github.com/nehecodes/devops-sandbox.git && cd devops-sandbox
cp .env.example .env          # edit as needed
make up                        # starts everything
make create                    # spin up your first env
make health                    # check env health
```

> **One-command spin-up**: `make up` starts Nginx, the Control API, the cleanup daemon, and the health monitor. Everything else flows from there.

## Architecture

```
                         ┌─────────────────────────────────────────┐
                         │              Linux VM                   │
                         │                                         │
  Browser / curl ──────► │  Nginx :80  (dynamic per-env routing)  │
                         │      │                                  │
                         │      ├─► /api/*  ──► Flask API :5050   │
                         │      │                   │              │
                         │      └─► /env/ID/ ──► sandbox-$ID:80   │
                         │                                         │
                         │  Cleanup Daemon (background, 60s loop)  │
                         │  Health Monitor (background, 30s poll)  │
                         └─────────────────────────────────────────┘
```

### Network Approach

Each environment gets its own Docker network (`sandbox-$ENV_ID`). The Nginx container is joined to every env network at creation time so it can proxy traffic. On destroy, the network is removed and Nginx is reloaded. All infrastructure containers share the `sandbox-core` bridge network.

## Repository Structure

```
devops-sandbox/
├── platform/
│   ├── create_env.sh        # lifecycle: create
│   ├── destroy_env.sh       # lifecycle: destroy
│   ├── cleanup_daemon.sh    # TTL expiry daemon
│   ├── simulate_outage.sh   # chaos engineering
│   ├── api.py               # Flask control API
│   └── requirements.txt
├── nginx/
│   ├── nginx.conf           # main config (includes conf.d/*.conf)
│   └── conf.d/              # auto-generated per-env configs (gitignored)
├── monitor/
│   ├── health_poller.py     # 30s health check poller
│   └── prometheus.yml       # optional Prometheus config
├── logs/                    # gitignored
│   ├── cleanup.log
│   ├── health_monitor.log
│   ├── <env-id>/
│   │   ├── app.log
│   │   └── health.log
│   └── archived/            # logs moved here on destroy
├── envs/                    # runtime state files (gitignored)
├── docker-compose.yml
├── Dockerfile.api
├── Makefile
└── README.md
```

## Make Targets

| Target | Description |
|--------|-------------|
| `make up` | Start Nginx, API, cleanup daemon, health monitor |
| `make down` | Stop everything, destroy all active envs |
| `make create` | Interactive prompt to create a new env |
| `make destroy ENV=<id>` | Destroy a specific environment |
| `make logs ENV=<id>` | Tail app logs for an env |
| `make health` | Show health status of all active envs |
| `make simulate ENV=<id> MODE=<mode>` | Run outage simulation |
| `make clean` | Wipe all state, logs, archives |
| `make status` | Show platform component status |
| `make monitoring` | Start optional Prometheus + Grafana |

## Environment Lifecycle

### Creating

```bash
bash platform/create_env.sh my-app 3600   # name, TTL in seconds
# or interactively:
make create
```

Creates:
- Unique env ID (`env-<name>-<timestamp>`)
- Docker network `sandbox-<env-id>`
- App container `sandbox-<env-id>` with `sandbox.env=<id>` label
- State file `envs/<env-id>.json`
- Nginx config `nginx/conf.d/<env-id>.conf`
- Log shipper subprocess
- Reloads Nginx

### Destroying

```bash
bash platform/destroy_env.sh env-my-app-123456
# or:
make destroy ENV=env-my-app-123456
```

Stops log shipper → removes containers → removes network → removes Nginx config → archives logs → deletes state file.

### Auto Cleanup

The cleanup daemon (`platform/cleanup_daemon.sh`) runs every 60 seconds. It checks every state file and calls `destroy_env.sh` when `now > created_at + ttl`. All actions are timestamped in `logs/cleanup.log`.

## Control API

Base URL: `http://localhost:5050`

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/envs` | Create environment |
| `GET` | `/envs` | List active envs + TTL remaining |
| `DELETE` | `/envs/:id` | Destroy environment |
| `GET` | `/envs/:id/logs` | Last 100 lines of app.log |
| `GET` | `/envs/:id/health` | Last 10 health check results |
| `POST` | `/envs/:id/outage` | Trigger outage simulation |

**Examples:**

```bash
# Create
curl -X POST http://localhost:5050/envs \
  -H "Content-Type: application/json" \
  -d '{"name": "my-app", "ttl": 1800}'

# List
curl http://localhost:5050/envs

# Destroy
curl -X DELETE http://localhost:5050/envs/env-my-app-123456

# Logs
curl http://localhost:5050/envs/env-my-app-123456/logs

# Health
curl http://localhost:5050/envs/env-my-app-123456/health

# Simulate crash
curl -X POST http://localhost:5050/envs/env-my-app-123456/outage \
  -H "Content-Type: application/json" \
  -d '{"mode": "crash"}'
```

## Outage Simulation

```bash
make simulate ENV=env-my-app-123456 MODE=crash
# or
bash platform/simulate_outage.sh --env env-my-app-123456 --mode pause
```

| Mode | Behaviour | Recovery |
|------|-----------|---------|
| `crash` | `docker kill` the container | `recover` mode or health monitor |
| `pause` | `docker pause` (freezes all processes) | `--mode recover` |
| `network` | `docker network disconnect` from env network | `--mode recover` |
| `recover` | Restore whatever was broken | — |
| `stress` | CPU spike via `stress-ng` (30s) | Auto-recovers |

**Safety guard**: The script checks labels and refuses to run against any infrastructure container (`sandbox-nginx`, `sandbox-api`, `sandbox-daemon`, etc.).

## Health Monitoring

The health poller (`monitor/health_poller.py`) hits `GET /health` on each active env every 30 seconds and writes a JSON record to `logs/<env-id>/health.log`:

```json
{"timestamp": "2025-01-01T12:00:00+00:00", "env_id": "env-foo-123", "http_status": 200, "latency_ms": 12.3, "healthy": true}
```

After **3 consecutive failures**, the env status is set to `degraded` and a warning is printed. The status auto-recovers if a subsequent poll succeeds.

## Log Shipping

Uses **Approach A** (simple): `docker logs -f $CONTAINER >> logs/$ENV_ID/app.log &`. The subprocess PID is stored in `logs/$ENV_ID/log_shipper.pid` and killed on destroy.

Query logs by env ID:
```bash
make logs ENV=env-my-app-123456
# or
curl http://localhost:5050/envs/env-my-app-123456/logs
```

## Nginx Dynamic Routing

Each created env gets a config file at `nginx/conf.d/<env-id>.conf`:

```nginx
upstream env-my-app-123456 {
    server sandbox-env-my-app-123456:80;
}
location /env/env-my-app-123456/ {
    proxy_pass http://env-my-app-123456/;
    ...
}
```

On every create/destroy, `nginx -s reload` is sent to the Nginx container. The main `nginx.conf` uses `include /etc/nginx/conf.d/*.conf;` as its final directive.

## Optional: Prometheus + Grafana

```bash
make monitoring
# Prometheus: http://localhost:9090
# Grafana:    http://localhost:3000 (admin / sandbox123)
```

## Custom App Images

Set `SANDBOX_APP_IMAGE` in `.env` to any image that:
- Exposes port **80**
- Responds to `GET /health` with HTTP 2xx

```bash
SANDBOX_APP_IMAGE=my-org/my-app:latest make create
```

## Secrets

All secrets go in `.env` (gitignored). Never commit `.env`. Use `.env.example` as a template.
