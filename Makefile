.PHONY: up down create destroy logs health simulate clean help

SHELL := /bin/bash
ROOT_DIR := $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))
PLATFORM := $(ROOT_DIR)/platform
ENVS_DIR := $(ROOT_DIR)/envs
LOGS_DIR := $(ROOT_DIR)/logs

# Load .env if present
-include $(ROOT_DIR)/.env
export

# ─── Colours ─────────────────────────────────────────────────────────────────
GREEN  := \033[0;32m
YELLOW := \033[0;33m
RED    := \033[0;31m
CYAN   := \033[0;36m
RESET  := \033[0m

## up: Start Nginx, API, and cleanup daemon
up:
	@echo -e "$(CYAN)Starting sandbox platform...$(RESET)"
	@mkdir -p $(ENVS_DIR) $(LOGS_DIR) $(ROOT_DIR)/nginx/conf.d $(LOGS_DIR)/archived
	@docker compose up -d nginx api
	@echo -e "$(GREEN)✓ Nginx and API started$(RESET)"
	@echo -e "$(CYAN)Starting cleanup daemon in background...$(RESET)"
	@nohup bash $(PLATFORM)/cleanup_daemon.sh > $(LOGS_DIR)/cleanup.log 2>&1 & \
		echo $$! > $(ROOT_DIR)/.daemon.pid && \
		echo -e "$(GREEN)✓ Cleanup daemon started (PID $$(cat $(ROOT_DIR)/.daemon.pid))$(RESET)"
	@echo -e "$(CYAN)Starting health monitor in background...$(RESET)"
	@nohup python3 $(ROOT_DIR)/monitor/health_poller.py > $(LOGS_DIR)/health_monitor.log 2>&1 & \
		echo $$! > $(ROOT_DIR)/.monitor.pid && \
		echo -e "$(GREEN)✓ Health monitor started (PID $$(cat $(ROOT_DIR)/.monitor.pid))$(RESET)"
	@echo ""
	@echo -e "$(GREEN)Platform is up!$(RESET)"
	@echo -e "  API:   http://localhost:5050"
	@echo -e "  Proxy: http://localhost:80"

## down: Stop everything and destroy all envs
down:
	@echo -e "$(YELLOW)Shutting down sandbox platform...$(RESET)"
	@if [ -f $(ROOT_DIR)/.daemon.pid ]; then \
		kill $$(cat $(ROOT_DIR)/.daemon.pid) 2>/dev/null || true; \
		rm -f $(ROOT_DIR)/.daemon.pid; \
		echo -e "$(GREEN)✓ Cleanup daemon stopped$(RESET)"; \
	fi
	@if [ -f $(ROOT_DIR)/.monitor.pid ]; then \
		kill $$(cat $(ROOT_DIR)/.monitor.pid) 2>/dev/null || true; \
		rm -f $(ROOT_DIR)/.monitor.pid; \
		echo -e "$(GREEN)✓ Health monitor stopped$(RESET)"; \
	fi
	@echo -e "$(YELLOW)Destroying all active environments...$(RESET)"
	@for f in $(ENVS_DIR)/*.json 2>/dev/null; do \
		[ -f "$$f" ] || continue; \
		ENV_ID=$$(basename $$f .json); \
		echo "  Destroying $$ENV_ID..."; \
		bash $(PLATFORM)/destroy_env.sh "$$ENV_ID" 2>/dev/null || true; \
	done
	@docker compose down 2>/dev/null || true
	@echo -e "$(GREEN)✓ Platform stopped$(RESET)"

## create: Create a new environment (prompts for name and TTL)
create:
	@read -p "Environment name: " name; \
	read -p "TTL in seconds [1800]: " ttl; \
	ttl=$${ttl:-1800}; \
	bash $(PLATFORM)/create_env.sh "$$name" "$$ttl"

## destroy: Destroy a specific environment (requires ENV=<id>)
destroy:
ifndef ENV
	$(error ENV is required. Usage: make destroy ENV=env-abc123)
endif
	@echo -e "$(YELLOW)Destroying environment: $(ENV)$(RESET)"
	@bash $(PLATFORM)/destroy_env.sh "$(ENV)"
	@echo -e "$(GREEN)✓ Done$(RESET)"

## logs: Tail logs for a specific environment (requires ENV=<id>)
logs:
ifndef ENV
	$(error ENV is required. Usage: make logs ENV=env-abc123)
endif
	@LOG_FILE=$(LOGS_DIR)/$(ENV)/app.log; \
	ARCHIVE=$(LOGS_DIR)/archived/$(ENV)/app.log; \
	if [ -f "$$LOG_FILE" ]; then \
		echo -e "$(CYAN)Tailing $(ENV) logs (Ctrl+C to stop)...$(RESET)"; \
		tail -f "$$LOG_FILE"; \
	elif [ -f "$$ARCHIVE" ]; then \
		echo -e "$(YELLOW)Environment is archived — showing last 50 lines$(RESET)"; \
		tail -n 50 "$$ARCHIVE"; \
	else \
		echo -e "$(RED)No logs found for $(ENV)$(RESET)"; \
		exit 1; \
	fi

## health: Show health status of all active environments
health:
	@echo -e "$(CYAN)Environment Health Status$(RESET)"
	@echo -e "$(CYAN)─────────────────────────$(RESET)"
	@COUNT=0; \
	for f in $(ENVS_DIR)/*.json 2>/dev/null; do \
		[ -f "$$f" ] || continue; \
		COUNT=$$((COUNT+1)); \
		ENV_ID=$$(basename $$f .json); \
		STATUS=$$(python3 -c "import json; d=json.load(open('$$f')); print(d.get('status','?'))"); \
		TTL=$$(python3 -c "import json,time; d=json.load(open('$$f')); print(max(0, d['created_ts']+d['ttl']-int(time.time())))"); \
		case "$$STATUS" in \
			running)   COLOR="$(GREEN)" ;; \
			degraded)  COLOR="$(YELLOW)" ;; \
			crashed)   COLOR="$(RED)" ;; \
			*)         COLOR="$(RESET)" ;; \
		esac; \
		echo -e "  $$COLOR$$ENV_ID$(RESET) — status=$$STATUS ttl_remaining=$${TTL}s"; \
		HEALTH_LOG=$(LOGS_DIR)/$$ENV_ID/health.log; \
		if [ -f "$$HEALTH_LOG" ]; then \
			tail -n 1 "$$HEALTH_LOG" | python3 -c \
				"import json,sys; d=json.loads(sys.stdin.read()); print(f'    last_check: HTTP {d.get(\"http_status\",\"?\")} {d.get(\"latency_ms\",\"?\")}ms ({d.get(\"timestamp\",\"?\")})')"; \
		fi; \
	done; \
	if [ $$COUNT -eq 0 ]; then \
		echo -e "  $(YELLOW)No active environments$(RESET)"; \
	fi

## simulate: Run outage simulation (requires ENV=<id> and MODE=<mode>)
simulate:
ifndef ENV
	$(error ENV is required. Usage: make simulate ENV=env-abc123 MODE=crash)
endif
ifndef MODE
	$(error MODE is required. Usage: make simulate ENV=env-abc123 MODE=crash)
endif
	@echo -e "$(YELLOW)Simulating $(MODE) on $(ENV)...$(RESET)"
	@bash $(PLATFORM)/simulate_outage.sh --env "$(ENV)" --mode "$(MODE)"

## clean: Wipe all state, logs, and archives (keeps platform scripts)
clean:
	@echo -e "$(RED)WARNING: This will delete all state, logs, and archives$(RESET)"
	@read -p "Are you sure? [y/N] " confirm; \
	if [ "$$confirm" = "y" ] || [ "$$confirm" = "Y" ]; then \
		rm -rf $(ENVS_DIR)/*.json $(LOGS_DIR)/*.log $(LOGS_DIR)/archived; \
		find $(ROOT_DIR)/nginx/conf.d -name "env-*.conf" -delete; \
		echo -e "$(GREEN)✓ State and logs wiped$(RESET)"; \
	else \
		echo "Aborted."; \
	fi

## monitoring: Start optional Prometheus + Grafana stack
monitoring:
	@docker compose --profile monitoring up -d
	@echo -e "$(GREEN)✓ Prometheus: http://localhost:9090$(RESET)"
	@echo -e "$(GREEN)✓ Grafana:    http://localhost:3000 (admin/sandbox123)$(RESET)"

## status: Show platform component status
status:
	@echo -e "$(CYAN)Platform Status$(RESET)"
	@echo -e "$(CYAN)───────────────$(RESET)"
	@docker ps --filter "label=sandbox.managed=true" \
		--format "  {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || true
	@echo ""
	@DAEMON_PID=""; MONITOR_PID=""; \
	[ -f $(ROOT_DIR)/.daemon.pid ] && DAEMON_PID=$$(cat $(ROOT_DIR)/.daemon.pid); \
	[ -f $(ROOT_DIR)/.monitor.pid ] && MONITOR_PID=$$(cat $(ROOT_DIR)/.monitor.pid); \
	[ -n "$$DAEMON_PID" ] && kill -0 $$DAEMON_PID 2>/dev/null && \
		echo -e "  $(GREEN)✓ Cleanup daemon running (PID $$DAEMON_PID)$(RESET)" || \
		echo -e "  $(RED)✗ Cleanup daemon not running$(RESET)"; \
	[ -n "$$MONITOR_PID" ] && kill -0 $$MONITOR_PID 2>/dev/null && \
		echo -e "  $(GREEN)✓ Health monitor running (PID $$MONITOR_PID)$(RESET)" || \
		echo -e "  $(RED)✗ Health monitor not running$(RESET)"

## help: Show this help
help:
	@echo -e "$(CYAN)DevOps Sandbox Platform$(RESET)"
	@echo -e "$(CYAN)═══════════════════════$(RESET)"
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/## //' | \
		awk 'BEGIN{FS=":"} {printf "  $(GREEN)%-20s$(RESET) %s\n", $$1, $$2}'

.DEFAULT_GOAL := help
