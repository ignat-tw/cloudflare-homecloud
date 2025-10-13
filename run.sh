#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# run.sh — Cloudflare Tunnel (Docker) + raw TCP tunnel for Synology Drive
# -----------------------------------------------------------------------------

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="$PROJECT_ROOT/docker"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
SERVICE_NAME="cloudflared"

CF_DIR="$PROJECT_ROOT/cf"
CF_CONFIG_FILE="$CF_DIR/config.yml"
CF_SECRETS_DIR="$PROJECT_ROOT/secrets"
ENV_FILE="$PROJECT_ROOT/.env"

# --- autossh-driven TCP (Drive) tunnel bookkeeping
TUN_DIR="$PROJECT_ROOT/.tunnels"
mkdir -p "$TUN_DIR"
DRIVE_PID_FILE="$TUN_DIR/drive.pid"
DRIVE_LOG_FILE="$TUN_DIR/drive.log"

# ---- DSM (cloud) over Oracle ----
CLOUD_PID_FILE="$TUN_DIR/cloud.pid"
CLOUD_LOG_FILE="$TUN_DIR/cloud.log"

# Defaults for first .env creation
DEFAULT_TUNNEL_NAME="homecloud"
DEFAULT_HOSTNAME="cloud.demonsmp.win"
DEFAULT_NAS_IP="192.168.2.10"
DEFAULT_DSM_PORT="5001"
DEFAULT_CF_LOGLEVEL="info"
DEFAULT_METRICS_PORT="49383"

# Defaults for Oracle jump host + Drive TCP
DEFAULT_SSH_KEY="$HOME/.ssh/mc-proxy.key"
DEFAULT_REMOTE_HOST="ubuntu@mc1.demonsmp.win"
DEFAULT_DRIVE_LOCAL_IP="$DEFAULT_NAS_IP"
DEFAULT_DRIVE_LOCAL_PORT="6690"     # Synology Drive Server (client)
DEFAULT_DRIVE_REMOTE_PORT="16690"   # port on Oracle reached via SSH -R
DEFAULT_DRIVE_PUBLIC_PORT="6690"    # public port on Oracle exposed by nginx stream
DEFAULT_DRIVE_REMOTE_BIND_ALL="false"  # set true to skip nginx & bind 0.0.0.0 (requires GatewayPorts)

# Defaults for DSM HTTPS raw TCP ("cloud")
DEFAULT_CLOUD_LOCAL_IP="$DEFAULT_NAS_IP"
DEFAULT_CLOUD_LOCAL_PORT="5001"
DEFAULT_CLOUD_REMOTE_PORT="15001"
DEFAULT_CLOUD_PUBLIC_PORT="5001"
DEFAULT_CLOUD_REMOTE_BIND_ALL="false"

# Prefer "docker compose", fall back to docker-compose
dc() {
  if docker compose version >/dev/null 2>&1; then
    (cd "$COMPOSE_DIR" && docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@")
  else
    (cd "$COMPOSE_DIR" && docker-compose -f "$COMPOSE_FILE" "$@")
  fi
}

# dockerized cloudflared CLI (persists creds in ./secrets)
CFLARE=(docker run --rm -it
  -v "$CF_SECRETS_DIR":/home/nonroot/.cloudflared
  -v "$CF_SECRETS_DIR":/etc/cloudflared
  cloudflare/cloudflared:latest)

show_help() {
  cat <<EOF
Usage: $(basename "$0") <command>

Cloudflared (Docker):
  start              🟢 compose up -d (requires cf/config.yml)
  stop               🔴 compose down
  logs               📜 compose logs -f cloudflared
  status             📊 compose ps
  open               🔗 Open https://\$HOSTNAME

Cloudflare tunnel (CLI in Docker):
  bootstrap          🔧 Login, create tunnel, DNS route \$HOSTNAME
  tunnel-login       🔐 cloudflared tunnel login
  tunnel-create      🏗  cloudflared tunnel create "\$TUNNEL_NAME"
  tunnel-list        📋 List tunnels
  tunnel-dns [host]  🌐 Route DNS to this tunnel (default: \$HOSTNAME)
  tunnel-delete      🗑  Delete tunnel "\$TUNNEL_NAME"
  tunnel-id          🆔 Print detected tunnel ID
  tunnel-creds-path  📂 Show expected creds JSON path

Synology Drive TCP tunnel (autossh → Oracle):
  drive-tunnel-start     🔌 Start reverse SSH tunnel & record PID
  drive-tunnel-stop      ❌ Stop it via PID
  drive-tunnel-status    📈 Check status
  drive-tunnel-recreate  🔁 Restart cleanly

Synology Cloud Drive TCP tunnel (autossh → Oracle):
  cloud-tunnel-start     🔌 Start reverse SSH tunnel & record PID
  cloud-tunnel-stop      ❌ Stop it via PID
  cloud-tunnel-status    📈 Check status
  cloud-tunnel-recreate  🔁 Restart cleanly

EOF
}

ensure_layout() {
  mkdir -p "$COMPOSE_DIR" "$CF_DIR" "$CF_SECRETS_DIR"
  if [[ ! -f "$COMPOSE_FILE" ]]; then
cat > "$COMPOSE_FILE" <<'YML'
services:
  cloudflared:
    image: cloudflare/cloudflared:latest
    platform: linux/arm64
    restart: unless-stopped
    env_file:
      - ../.env
    command: >
      tunnel --config /etc/cloudflared/config.yml run
      --loglevel ${CF_LOGLEVEL}
      --metrics 0.0.0.0:${METRICS_PORT}
    volumes:
      - ../cf/config.yml:/etc/cloudflared/config.yml:ro
      - ../secrets:/etc/cloudflared:ro
    ports:
      - "127.0.0.1:${METRICS_PORT}:${METRICS_PORT}"   # metrics only on localhost
YML
    echo "🧩 Wrote ${COMPOSE_FILE}"
  fi
}

ensure_env() {
  if [[ ! -f "$ENV_FILE" ]]; then
cat > "$ENV_FILE" <<EOF
# ---- Cloudflare Tunnel basics ----
TUNNEL_NAME=${DEFAULT_TUNNEL_NAME}
HOSTNAME=${DEFAULT_HOSTNAME}

# ---- NAS origin ----
NAS_IP=${DEFAULT_NAS_IP}
DSM_PORT=${DEFAULT_DSM_PORT}

# ---- Cloudflared runtime ----
CF_LOGLEVEL=${DEFAULT_CF_LOGLEVEL}
METRICS_PORT=${DEFAULT_METRICS_PORT}

# ---- Oracle jump host for raw TCP (Synology Drive) ----
SSH_KEY_PATH=${DEFAULT_SSH_KEY}
JUMP_HOST=${DEFAULT_REMOTE_HOST}

# Where the tunnel should connect to on your LAN
DRIVE_LOCAL_IP=${DEFAULT_DRIVE_LOCAL_IP}
DRIVE_LOCAL_PORT=${DEFAULT_DRIVE_LOCAL_PORT}

# Where the SSH -R exposes the socket *on the Oracle box*
DRIVE_REMOTE_PORT=${DEFAULT_DRIVE_REMOTE_PORT}

# Public port on Oracle reached by clients (nginx stream listens here)
DRIVE_PUBLIC_PORT=${DEFAULT_DRIVE_PUBLIC_PORT}

# If set to "true", bind 0.0.0.0:\$DRIVE_PUBLIC_PORT directly from SSH and SKIP nginx.
# Requires sshd_config: GatewayPorts clientspecified
DRIVE_REMOTE_BIND_ALL=${DEFAULT_DRIVE_REMOTE_BIND_ALL}

# ---- DSM HTTPS raw TCP (via Oracle) ----
CLOUD_LOCAL_IP=${DEFAULT_CLOUD_LOCAL_IP}
CLOUD_LOCAL_PORT=${DEFAULT_CLOUD_LOCAL_PORT}
CLOUD_REMOTE_PORT=${DEFAULT_CLOUD_REMOTE_PORT}
CLOUD_PUBLIC_PORT=${DEFAULT_CLOUD_PUBLIC_PORT}
CLOUD_REMOTE_BIND_ALL=${DEFAULT_CLOUD_REMOTE_BIND_ALL}

EOF
    echo "🧩 Wrote ${ENV_FILE}"
  fi
  set -a; source "$ENV_FILE"; set +a
}

preflight() {
  [[ -f "$CF_CONFIG_FILE" ]] || { echo "❌ Missing ${CF_CONFIG_FILE} — create & commit it first."; exit 1; }
  if grep -qE 'tunnel:\s*\$\{' "$CF_CONFIG_FILE"; then
    echo "⚠️  ${CF_CONFIG_FILE} uses env placeholders for 'tunnel:'. Use a LITERAL UUID." >&2
  fi
  chmod 644 "$CF_CONFIG_FILE" || true
  find "$CF_SECRETS_DIR" -name '*.json' -exec chmod 644 {} \; || true
}

get_tunnel_id() {
  local id
  id="$("${CFLARE[@]}" tunnel list 2>/dev/null | awk -v n="$TUNNEL_NAME" '$0 ~ n {print $1; exit}')"
  if [[ -z "${id:-}" ]]; then
    id="$(ls "$CF_SECRETS_DIR"/*.json 2>/dev/null | sed -E 's#.*/##; s#\.json$##' | head -n1 || true)"
  fi
  [[ -n "${id:-}" ]] && echo "$id" || return 1
}

tunnel_creds_path() {
  local tid; tid="$(get_tunnel_id 2>/dev/null || true)"
  [[ -n "${tid:-}" ]] && echo "$CF_SECRETS_DIR/$tid.json" || echo "$CF_SECRETS_DIR/<TUNNEL_UUID>.json"
}

# ----- Drive raw TCP tunnel helpers (autossh) -----

need_autossh() {
  command -v autossh >/dev/null 2>&1 || {
    echo "❌ autossh not found. Install it (brew install autossh) and retry."
    exit 1
  }
}

drive_bind_host() {
  local all="${DRIVE_REMOTE_BIND_ALL:-false}"
  case "$all" in
    true|TRUE|1|yes|on) echo "0.0.0.0" ;;
    *)                   echo "127.0.0.1" ;;
  esac
}

drive_tunnel_start() {
  need_autossh
  local bind_host; bind_host="$(drive_bind_host)"

  local R_SYNC="${bind_host}:${DRIVE_REMOTE_PORT}:${DRIVE_LOCAL_IP}:${DRIVE_LOCAL_PORT}"
  local R_WEB="${bind_host}:${DRIVE_WEB_REMOTE_PORT}:${DRIVE_LOCAL_IP}:${DRIVE_WEB_LOCAL_PORT}"

  if [[ -f "$DRIVE_PID_FILE" ]] && ps -p "$(cat "$DRIVE_PID_FILE")" >/dev/null 2>&1; then
    echo "⚠️  Drive tunnel already running (PID: $(cat "$DRIVE_PID_FILE"))."
    return
  fi

  echo "🔌 Starting reverse SSH (Drive 6690 + 6691) to ${JUMP_HOST} ..."
  nohup autossh -f -M 0 -N \
    -i "$SSH_KEY_PATH" \
    -o StrictHostKeyChecking=no \
    -o ExitOnForwardFailure=yes \
    -o IdentitiesOnly=yes \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -R "$R_SYNC" \
    -R "$R_WEB" \
    "$JUMP_HOST" > "$DRIVE_LOG_FILE" 2>&1 &

  sleep 1
  local REAL_PID
  REAL_PID="$(pgrep -f "autossh.*${R_SYNC//./\\.}.*$JUMP_HOST" | head -n1 || true)"
  [[ -n "${REAL_PID:-}" ]] && echo "$REAL_PID" > "$DRIVE_PID_FILE" && echo "🚀 Drive tunnel started (PID: $REAL_PID)" || { echo "❌ Could not find tunnel PID. See $DRIVE_LOG_FILE"; exit 1; }
}

drive_tunnel_stop() {
  if [[ -f "$DRIVE_PID_FILE" ]]; then
    local PID; PID="$(cat "$DRIVE_PID_FILE")"
    echo "🧹 Stopping Drive tunnel (PID: $PID) ..."
    if kill "$PID" >/dev/null 2>&1; then
      rm -f "$DRIVE_PID_FILE"
      echo "✅ Stopped."
    else
      echo "⚠️ Not running. Cleaning up PID file."
      rm -f "$DRIVE_PID_FILE"
    fi
  else
    echo "⚠️ No Drive tunnel PID recorded."
  fi
}

drive_tunnel_status() {
  if [[ -f "$DRIVE_PID_FILE" ]] && ps -p "$(cat "$DRIVE_PID_FILE")" >/dev/null 2>&1; then
    echo "📈 Drive tunnel is running (PID: $(cat "$DRIVE_PID_FILE"))."
  else
    echo "❌ Drive tunnel is not running."
  fi
}

cloud_tunnel_start() {
  need_autossh
  local bind_host; bind_host="$(cloud_bind_host)"
  local R_HTTPS="${bind_host}:${CLOUD_REMOTE_PORT:-15001}:${CLOUD_LOCAL_IP:-$NAS_IP}:${CLOUD_LOCAL_PORT:-5001}"
  local R_HTTP="${bind_host}:${CLOUD_REMOTE_HTTP_PORT:-15080}:${CLOUD_LOCAL_IP:-$NAS_IP}:80"

  if [[ -f "$TUN_DIR/cloud.pid" ]] && ps -p "$(cat "$TUN_DIR/cloud.pid")" >/dev/null 2>&1; then
    echo "⚠️  Cloud tunnel already running (PID: $(cat "$TUN_DIR/cloud.pid"))."; return
  fi

  echo "🔌 Starting reverse SSH (cloud HTTPS/HTTP) to ${JUMP_HOST} ..."
  nohup autossh -f -M 0 -N \
    -i "${SSH_KEY_PATH}" \
    -o StrictHostKeyChecking=no \
    -o ExitOnForwardFailure=yes \
    -o IdentitiesOnly=yes \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -R "$R_HTTPS" \
    -R "$R_HTTP" \
    "$JUMP_HOST" > "$TUN_DIR/cloud.log" 2>&1 &

  sleep 1
  local REAL_PID; REAL_PID="$(pgrep -f "autossh.*${R_HTTPS//./\\.}.*$JUMP_HOST" | head -n1 || true)"
  [[ -n "$REAL_PID" ]] && echo "$REAL_PID" > "$TUN_DIR/cloud.pid" && echo "🚀 Cloud tunnel started (PID: $REAL_PID)" || { echo "❌ Could not find cloud tunnel PID. See $TUN_DIR/cloud.log"; exit 1; }
}

cloud_bind_host() {
  local all="${CLOUD_REMOTE_BIND_ALL:-false}"
  case "$all" in
    true|TRUE|1|yes|on) echo "0.0.0.0" ;;
    *)                   echo "127.0.0.1" ;;
  esac
}

cloud_tunnel_stop()   { [[ -f "$TUN_DIR/cloud.pid" ]] && kill "$(cat "$TUN_DIR/cloud.pid")" 2>/dev/null && rm -f "$TUN_DIR/cloud.pid" && echo "✅ Cloud tunnel stopped." || echo "⚠️ No cloud PID."; }
cloud_tunnel_status() { [[ -f "$TUN_DIR/cloud.pid" ]] && ps -p "$(cat "$TUN_DIR/cloud.pid")" >/dev/null && echo "📈 Cloud tunnel running (PID: $(cat "$TUN_DIR/cloud.pid"))." || echo "❌ Cloud tunnel not running."; }

delayed-restart() {
  local delay="${1:-5}"
  # run detached, capture logs for post-check
  nohup bash -c '
    set -euo pipefail
    PROJECT_ROOT="'"$PROJECT_ROOT"'"
    COMPOSE_DIR="'"$COMPOSE_DIR"'"
    ENV_FILE="'"$ENV_FILE"'"
    LOG="/tmp/cf-restart.log"

    {
      echo "[detached] will restart in '"$delay"'s..."
      sleep '"$delay"'
      cd "$PROJECT_ROOT"

      # Stop/start via your own script to keep behavior consistent
      ./run.sh stop
      sleep 2
      ./run.sh start

      # Load env to get METRICS_PORT etc.
      set -a; [ -f "$ENV_FILE" ] && . "$ENV_FILE"; set +a

      # Find container ID of the compose service
      cid="$(cd "'"$COMPOSE_DIR"'" && docker compose ps -q cloudflared || true)"
      echo "[detached] container: ${cid:-<none>}"

      # Wait up to 60s for cloudflared to be alive and connected
      for i in $(seq 1 60); do
        # metrics reachable means process is up
        if curl -fsS "http://127.0.0.1:${METRICS_PORT:-49383}/metrics" >/dev/null 2>&1; then
          # logs line usually shows once tunnel is connected
          if [ -n "$cid" ] && docker logs "$cid" 2>&1 | grep -E -q "Connected to|Connection established|Registered tunnel"; then
            echo "[detached] tunnel looks UP ✅"
            exit 0
          fi
        fi
        sleep 1
      done
      echo "[detached] timeout waiting for tunnel ❌"
      exit 1
    } >>"$LOG" 2>&1
  ' >/dev/null 2>&1 &

  echo "⏱️  Restart scheduled in ${delay}s. After reconnect:"
  echo "    tail -n +1 /tmp/cf-restart.log"
}

restart-now() {
  # immediate bounce (SSH will drop)
  echo "♻️  Restarting now (SSH will drop)..."
  ./run.sh stop
  sleep 2
  ./run.sh start
}

# ---- main ---------------------------------------------------------------
cmd="${1:-help}"; shift || true

case "$cmd" in
  start)    ensure_layout; ensure_env; preflight; echo "🟢 Starting ${SERVICE_NAME}..."; dc up -d --force-recreate ;;
  stop)     echo "🔴 Stopping ${SERVICE_NAME}..."; dc down ;;
  logs)     dc logs -f cloudflared ;;
  status)   dc ps ;;
  open)     ensure_env; command -v open >/dev/null 2>&1 && open "https://${HOSTNAME}" || echo "🔗 https://${HOSTNAME}" ;;
  bootstrap) ensure_layout; ensure_env; echo "🔐 Login…"; "${CFLARE[@]}" tunnel login; echo "🏗  Create/reuse ${TUNNEL_NAME}"; "${CFLARE[@]}" tunnel create "${TUNNEL_NAME}" || true; tid="$(get_tunnel_id)" || { echo "❌ No tunnel id"; exit 1; }; echo "🆔 $tid"; "${CFLARE[@]}" tunnel route dns "${TUNNEL_NAME}" "${HOSTNAME}" || true ;;
  tunnel-login)  "${CFLARE[@]}" tunnel login ;;
  tunnel-create) ensure_env; "${CFLARE[@]}" tunnel create "${TUNNEL_NAME}" || true ;;
  tunnel-list)   "${CFLARE[@]}" tunnel list || true ;;
  tunnel-dns)    ensure_env; host="${1:-$HOSTNAME}"; [[ -n "$host" ]] || { echo "Usage: $0 tunnel-dns <hostname>"; exit 1; }; "${CFLARE[@]}" tunnel route dns "${TUNNEL_NAME}" "${host}" ;;
  tunnel-delete) ensure_env; "${CFLARE[@]}" tunnel delete "${TUNNEL_NAME}" ;;
  tunnel-id)     get_tunnel_id || { echo "❌ No tunnel ID found."; exit 1; } ;;
  tunnel-creds-path) tunnel_creds_path ;;
  delayed-restart) delayed-restart "${1:-5}" ;;
  restart-now)     restart-now ;;

  # Drive TCP tunnel
  drive-tunnel-start) ensure_env; drive_tunnel_start ;;
  drive-tunnel-stop)  ensure_env; drive_tunnel_stop ;;
  drive-tunnel-status) ensure_env; drive_tunnel_status ;;
  drive-tunnel-recreate) ensure_env; drive_tunnel_stop || true; sleep 1; drive_tunnel_start ;;

  # DSM (cloud) TCP tunnel
  cloud-tunnel-start)   ensure_env; cloud_tunnel_start ;;
  cloud-tunnel-stop)    ensure_env; cloud_tunnel_stop ;;
  cloud-tunnel-status)  ensure_env; cloud_tunnel_status ;;
  cloud-tunnel-recreate) ensure_env; cloud_tunnel_stop || true; sleep 1; cloud_tunnel_start ;;

  help|*) show_help ;;
esac