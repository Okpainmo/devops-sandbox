#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENVS_DIR="$ROOT_DIR/envs"
LOGS_DIR="$ROOT_DIR/logs"
NGINX_CONFD_DIR="$ROOT_DIR/nginx/conf.d"

load_config() {
  if [[ -f "$ROOT_DIR/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$ROOT_DIR/.env"
    set +a
  fi

  SANDBOX_HOST="${SANDBOX_HOST:-localhost}"
  SANDBOX_HTTP_PORT="${SANDBOX_HTTP_PORT:-8080}"
  SANDBOX_API_PORT="${SANDBOX_API_PORT:-5000}"
  DEFAULT_TTL_SECONDS="${DEFAULT_TTL_SECONDS:-1800}"
  NGINX_CONTAINER="${NGINX_CONTAINER:-devops-sandbox-nginx}"
  PROXY_NETWORK="${PROXY_NETWORK:-devops-sandbox-proxy}"
  DEMO_IMAGE="${DEMO_IMAGE:-devops-sandbox-demo-app:latest}"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

ensure_dirs() {
  mkdir -p "$ENVS_DIR" "$LOGS_DIR" "$NGINX_CONFD_DIR" "$LOGS_DIR/archived"
}

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

parse_ttl_seconds() {
  local raw="${1:-$DEFAULT_TTL_SECONDS}"
  case "$raw" in
    *[!0-9smhd]*|"") echo "invalid TTL: $raw" >&2; exit 1 ;;
    *s) echo "${raw%s}" ;;
    *m) echo "$(( ${raw%m} * 60 ))" ;;
    *h) echo "$(( ${raw%h} * 3600 ))" ;;
    *d) echo "$(( ${raw%d} * 86400 ))" ;;
    *) echo "$raw" ;;
  esac
}

safe_name() {
  local value="$1"
  value="$(echo "$value" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9_.-' '-')"
  value="${value#-}"
  value="${value%-}"
  echo "${value:-app}"
}

validate_env_id() {
  local env_id="$1"
  if [[ ! "$env_id" =~ ^env-[a-f0-9]{12}$ ]]; then
    echo "invalid environment id: $env_id" >&2
    exit 1
  fi
}

env_state_file() {
  echo "$ENVS_DIR/$1.json"
}

env_log_dir() {
  echo "$LOGS_DIR/$1"
}

reload_nginx() {
  if docker ps --format '{{.Names}}' | grep -qx "$NGINX_CONTAINER"; then
    docker exec "$NGINX_CONTAINER" nginx -t >/dev/null 2>&1
    docker exec "$NGINX_CONTAINER" nginx -s reload >/dev/null
  fi
}

write_state_atomic() {
  local env_id="$1"
  local tmp
  tmp="$(mktemp "$ENVS_DIR/$env_id.XXXXXX.tmp")"
  cat >"$tmp"
  mv "$tmp" "$(env_state_file "$env_id")"
}

update_state_field() {
  local env_id="$1"
  local key="$2"
  local value="$3"
  local file tmp
  file="$(env_state_file "$env_id")"
  [[ -f "$file" ]] || return 0
  tmp="$(mktemp "$ENVS_DIR/$env_id.XXXXXX.tmp")"
  python3 - "$file" "$key" "$value" >"$tmp" <<'PY'
import json
import sys

path, key, value = sys.argv[1:4]
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)
if value.isdigit():
    data[key] = int(value)
else:
    data[key] = value
json.dump(data, sys.stdout, indent=2, sort_keys=True)
sys.stdout.write("\n")
PY
  mv "$tmp" "$file"
}
