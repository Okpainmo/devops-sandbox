#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

load_config
ensure_dirs
require_cmd python3

LOG_FILE="$LOGS_DIR/cleanup.log"
echo "$(timestamp) cleanup daemon started" >>"$LOG_FILE"

while true; do
  shopt -s nullglob
  for state in "$ENVS_DIR"/*.json; do
    ENV_ID="$(basename "$state" .json)"
    read -r CREATED_AT TTL STATUS < <(python3 - "$state" <<'PY' || echo "0 0 unknown"
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
print(data.get("created_at", 0), data.get("ttl", 0), data.get("status", "unknown"))
PY
)
    NOW="$(date -u +%s)"
    if [[ "$CREATED_AT" =~ ^[0-9]+$ && "$TTL" =~ ^[0-9]+$ && "$((CREATED_AT + TTL))" -le "$NOW" ]]; then
      echo "$(timestamp) ttl expired env=$ENV_ID status=$STATUS action=destroy" >>"$LOG_FILE"
      "$SCRIPT_DIR/destroy_env.sh" "$ENV_ID" >>"$LOG_FILE" 2>&1 || echo "$(timestamp) destroy failed env=$ENV_ID" >>"$LOG_FILE"
    fi
  done
  sleep 60
done
