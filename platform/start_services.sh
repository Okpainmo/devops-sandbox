#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

load_config
ensure_dirs

start_service() {
  local name="$1"
  shift
  local pid_file="$LOGS_DIR/$name.pid"
  local log_file="$LOGS_DIR/$name.log"

  if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
    echo "$name already running"
    return 0
  fi

  rm -f "$pid_file"
  nohup "$@" >>"$log_file" 2>&1 </dev/null &
  echo "$!" >"$pid_file"
  sleep 0.5

  if ! kill -0 "$(cat "$pid_file")" 2>/dev/null; then
    echo "$name failed to start; last log lines:" >&2
    tail -n 40 "$log_file" >&2 || true
    exit 1
  fi

  echo "$name started"
}

PYTHON="$ROOT_DIR/.venv/bin/python"
start_service cleanup_daemon "$SCRIPT_DIR/cleanup_daemon.sh"
start_service health_poller "$PYTHON" "$ROOT_DIR/monitor/health_poller.py"
start_service api "$PYTHON" -m uvicorn api:app --app-dir "$ROOT_DIR/platform" --host 0.0.0.0 --port "$SANDBOX_API_PORT"
