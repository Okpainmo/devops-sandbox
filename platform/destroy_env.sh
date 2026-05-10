#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

load_config
ensure_dirs
require_cmd docker
require_cmd python3

ENV_ID="${1:-}"
if [[ -z "$ENV_ID" ]]; then
  echo "usage: $0 <env-id>" >&2
  exit 1
fi
validate_env_id "$ENV_ID"

STATE_FILE="$(env_state_file "$ENV_ID")"
LOG_DIR="$(env_log_dir "$ENV_ID")"
# shellcheck disable=SC2153
ARCHIVE_DIR="$LOGS_DIR/archived/$ENV_ID"

mapfile -t CONTAINER_IDS < <(docker ps -aq --filter "label=sandbox.env=$ENV_ID" || true)
if [[ -d "$LOG_DIR" && -f "$LOG_DIR/log_shipper.pid" ]]; then
  LOG_PID="$(cat "$LOG_DIR/log_shipper.pid" || true)"
  if [[ -n "${LOG_PID:-}" ]] && kill -0 "$LOG_PID" 2>/dev/null; then
    kill "$LOG_PID" 2>/dev/null || true
    wait "$LOG_PID" 2>/dev/null || true
  fi
fi

if [[ "${#CONTAINER_IDS[@]}" -gt 0 ]]; then
  docker rm -f "${CONTAINER_IDS[@]}" >/dev/null 2>&1 || true
fi

NETWORK_NAME="sandbox-${ENV_ID}"
if [[ -f "$STATE_FILE" ]]; then
  NETWORK_NAME="$(python3 - "$STATE_FILE" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    print(json.load(fh).get("network", ""))
PY
)"
fi

if [[ -n "$NETWORK_NAME" ]]; then
  docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
fi

rm -f "$NGINX_CONFD_DIR/$ENV_ID.conf"
reload_nginx

if [[ -d "$LOG_DIR" ]]; then
  mkdir -p "$ARCHIVE_DIR"
  cp -a "$LOG_DIR"/. "$ARCHIVE_DIR"/ 2>/dev/null || true
  rm -rf "$LOG_DIR"
fi

rm -f "$STATE_FILE"
echo "destroyed: $ENV_ID"
