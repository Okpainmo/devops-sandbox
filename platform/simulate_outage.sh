#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

load_config
require_cmd docker
require_cmd python3

ENV_ID=""
MODE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENV_ID="${2:-}"; shift 2 ;;
    --mode) MODE="${2:-}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$ENV_ID" || -z "$MODE" ]]; then
  echo "usage: $0 --env <env-id> --mode crash|pause|network|recover|stress" >&2
  exit 1
fi
validate_env_id "$ENV_ID"

STATE_FILE="$(env_state_file "$ENV_ID")"
[[ -f "$STATE_FILE" ]] || { echo "unknown environment: $ENV_ID" >&2; exit 1; }

read -r CONTAINER_ID CONTAINER_NAME OUTAGE_MODE < <(python3 - "$STATE_FILE" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
print(data.get("container_id", ""), data.get("container_name", ""), data.get("outage_mode", "none"))
PY
)

if [[ "$CONTAINER_NAME" == "$NGINX_CONTAINER" || "$CONTAINER_NAME" == *daemon* || "$CONTAINER_NAME" == *nginx* ]]; then
  echo "refusing to simulate outage against protected platform container: $CONTAINER_NAME" >&2
  exit 1
fi

restart_log_shipper() {
  local log_dir app_log log_pid
  log_dir="$(env_log_dir "$ENV_ID")"
  app_log="$log_dir/app.log"
  mkdir -p "$log_dir"
  if [[ -f "$log_dir/log_shipper.pid" ]]; then
    log_pid="$(cat "$log_dir/log_shipper.pid" || true)"
    if [[ -n "${log_pid:-}" ]] && kill -0 "$log_pid" 2>/dev/null; then
      return 0
    fi
  fi
  nohup docker logs -f "$CONTAINER_ID" >>"$app_log" 2>&1 </dev/null &
  echo "$!" >"$log_dir/log_shipper.pid"
  update_state_field "$ENV_ID" log_pid "$!"
}

case "$MODE" in
  crash)
    docker kill "$CONTAINER_ID" >/dev/null
    update_state_field "$ENV_ID" outage_mode crash
    ;;
  pause)
    docker pause "$CONTAINER_ID" >/dev/null
    update_state_field "$ENV_ID" outage_mode pause
    ;;
  network)
    docker network disconnect "$PROXY_NETWORK" "$CONTAINER_ID" >/dev/null 2>&1 || true
    update_state_field "$ENV_ID" outage_mode network
    ;;
  recover)
    if [[ "$OUTAGE_MODE" == "pause" ]]; then
      docker unpause "$CONTAINER_ID" >/dev/null 2>&1 || true
    elif [[ "$OUTAGE_MODE" == "network" ]]; then
      docker network connect "$PROXY_NETWORK" "$CONTAINER_ID" >/dev/null 2>&1 || true
    elif [[ "$OUTAGE_MODE" == "crash" ]]; then
      docker start "$CONTAINER_ID" >/dev/null
      restart_log_shipper
    elif [[ "$OUTAGE_MODE" == "stress" ]]; then
      docker exec "$CONTAINER_ID" sh -c 'if [ -f /tmp/sandbox_stress.pid ]; then kill "$(cat /tmp/sandbox_stress.pid)" 2>/dev/null || true; rm -f /tmp/sandbox_stress.pid; fi' >/dev/null 2>&1 || true
    fi
    update_state_field "$ENV_ID" outage_mode none
    update_state_field "$ENV_ID" status running
    ;;
  stress)
    docker exec "$CONTAINER_ID" sh -c 'if [ ! -f /tmp/sandbox_stress.pid ] || ! kill -0 "$(cat /tmp/sandbox_stress.pid)" 2>/dev/null; then (while :; do :; done) & echo $! > /tmp/sandbox_stress.pid; fi' >/dev/null
    update_state_field "$ENV_ID" outage_mode stress
    ;;
  *)
    echo "unsupported mode: $MODE" >&2
    exit 1
    ;;
esac

echo "outage mode applied: env=$ENV_ID mode=$MODE"
