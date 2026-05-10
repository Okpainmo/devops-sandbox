SHELL := /usr/bin/env bash

ROOT := $(CURDIR)
ENV_FILE := $(ROOT)/.env
PY := $(ROOT)/.venv/bin/python
DEPS_STAMP := $(ROOT)/.venv/.deps.stamp

-include .env

SANDBOX_API_PORT ?= 5000
SANDBOX_HTTP_PORT ?= 8080

.PHONY: up down create destroy logs health simulate clean deps chmod

$(DEPS_STAMP): requirements.txt Makefile
	@test -f .env || cp .env.example .env
	@python3 -m venv --clear .venv
	@$(PY) -m ensurepip --upgrade >/dev/null
	@$(PY) -m pip install -q --upgrade pip
	@$(PY) -m pip install -q -r requirements.txt
	@touch "$(DEPS_STAMP)"

deps: $(DEPS_STAMP)

chmod:
	@chmod +x platform/*.sh monitor/health_poller.py monitor/health_status.py platform/api.py

up: deps chmod
	@mkdir -p logs envs nginx/conf.d logs/archived
	@docker compose up -d nginx
	@platform/start_services.sh
	@echo "nginx: http://localhost:$(SANDBOX_HTTP_PORT)"
	@echo "api:   http://localhost:$(SANDBOX_API_PORT)"

down: chmod
	@platform/stop_services.sh
	@for f in envs/*.json; do [[ -e "$$f" ]] && platform/destroy_env.sh "$$(basename "$$f" .json)" || true; done
	@docker compose down

create: chmod
	@read -rp "Environment name: " name; read -rp "TTL (default 30m): " ttl; platform/create_env.sh "$$name" "$${ttl:-30m}"

destroy: chmod
	@test -n "$(ENV)" || (echo "usage: make destroy ENV=env-..." >&2; exit 1)
	@platform/destroy_env.sh "$(ENV)"

logs:
	@test -n "$(ENV)" || (echo "usage: make logs ENV=env-..." >&2; exit 1)
	@if [[ -f "logs/$(ENV)/app.log" ]]; then tail -f "logs/$(ENV)/app.log"; elif [[ -f "logs/archived/$(ENV)/app.log" ]]; then tail -n 100 "logs/archived/$(ENV)/app.log"; else echo "no logs for $(ENV)"; fi

health: deps chmod
	@$(PY) monitor/health_status.py

simulate: chmod
	@test -n "$(ENV)" || (echo "usage: make simulate ENV=env-... MODE=crash|pause|network|recover|stress" >&2; exit 1)
	@test -n "$(MODE)" || (echo "usage: make simulate ENV=env-... MODE=crash|pause|network|recover|stress" >&2; exit 1)
	@platform/simulate_outage.sh --env "$(ENV)" --mode "$(MODE)"

clean: down
	@rm -rf logs/* envs/* nginx/conf.d/*
	@touch logs/.gitkeep envs/.gitkeep nginx/conf.d/.gitkeep
