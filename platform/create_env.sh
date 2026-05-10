#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

load_config
ensure_dirs
require_cmd docker
require_cmd python3

NAME="${1:-}"
TTL_RAW="${2:-$DEFAULT_TTL_SECONDS}"

if [[ -z "$NAME" ]]; then
  echo "usage: $0 <name> [ttl: seconds|30m|2h|1d]" >&2
  exit 1
fi

TTL_SECONDS="$(parse_ttl_seconds "$TTL_RAW")"
CREATED_AT="$(date -u +%s)"
ENV_ID="env-$(python3 -c 'import uuid; print(uuid.uuid4().hex[:12])')"
ENV_NAME="$(safe_name "$NAME")"
CONTAINER_NAME="sandbox-${ENV_ID}"
NETWORK_NAME="sandbox-${ENV_ID}"
LOG_DIR="$(env_log_dir "$ENV_ID")"
APP_LOG="$LOG_DIR/app.log"
URL="http://${SANDBOX_HOST}:${SANDBOX_HTTP_PORT}/env/${ENV_ID}/"
CREATED_CONTAINER=""
CREATED_NETWORK=""
CREATED_LOG_PID=""

cleanup_failed_create() {
  local rc=$?
  if [[ "$rc" -ne 0 ]]; then
    if [[ -n "$CREATED_CONTAINER" ]]; then
      docker rm -f "$CREATED_CONTAINER" >/dev/null 2>&1 || true
    fi
    if [[ -n "$CREATED_NETWORK" ]]; then
      docker network rm "$CREATED_NETWORK" >/dev/null 2>&1 || true
    fi
    if [[ -n "$CREATED_LOG_PID" ]]; then
      kill "$CREATED_LOG_PID" >/dev/null 2>&1 || true
    fi
    rm -f "$NGINX_CONFD_DIR/$ENV_ID.conf"
    rm -rf "$LOG_DIR"
    reload_nginx || true
  fi
  exit "$rc"
}
trap cleanup_failed_create EXIT

mkdir -p "$LOG_DIR"

docker network inspect "$PROXY_NETWORK" >/dev/null 2>&1 || docker network create "$PROXY_NETWORK" >/dev/null
docker network create --label "sandbox.env=$ENV_ID" "$NETWORK_NAME" >/dev/null
CREATED_NETWORK="$NETWORK_NAME"

docker build -q -t "$DEMO_IMAGE" "$ROOT_DIR/demo-app" >/dev/null

CONTAINER_ID="$(
  docker run -d \
    --name "$CONTAINER_NAME" \
    --network "$NETWORK_NAME" \
    --label "sandbox.env=$ENV_ID" \
    --label "sandbox.role=app" \
    --env "ENV_ID=$ENV_ID" \
    --env "ENV_NAME=$ENV_NAME" \
    "$DEMO_IMAGE"
)"
CREATED_CONTAINER="$CONTAINER_ID"
docker network connect "$PROXY_NETWORK" "$CONTAINER_ID"

TMP_NGINX_CONF="$(mktemp "$NGINX_CONFD_DIR/$ENV_ID.XXXXXX.tmp")"
cat >"$TMP_NGINX_CONF" <<EOF_CONF
location /env/$ENV_ID/ {
    resolver 127.0.0.11 valid=10s ipv6=off;
    set \$sandbox_upstream http://$CONTAINER_NAME:8000;
    proxy_pass \$sandbox_upstream/;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
}
EOF_CONF
mv "$TMP_NGINX_CONF" "$NGINX_CONFD_DIR/$ENV_ID.conf"

reload_nginx

nohup docker logs -f "$CONTAINER_ID" >>"$APP_LOG" 2>&1 </dev/null &
LOG_PID="$!"
CREATED_LOG_PID="$LOG_PID"
echo "$LOG_PID" >"$LOG_DIR/log_shipper.pid"

write_state_atomic "$ENV_ID" <<EOF_JSON
{
  "id": "$ENV_ID",
  "name": "$ENV_NAME",
  "created_at": $CREATED_AT,
  "ttl": $TTL_SECONDS,
  "status": "running",
  "url": "$URL",
  "container_id": "$CONTAINER_ID",
  "container_name": "$CONTAINER_NAME",
  "network": "$NETWORK_NAME",
  "log_pid": $LOG_PID,
  "outage_mode": "none"
}
EOF_JSON

echo "environment: $ENV_ID"
echo "url: $URL"
echo "ttl_seconds: $TTL_SECONDS"
trap - EXIT
