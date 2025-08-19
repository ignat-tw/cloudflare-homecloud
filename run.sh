#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# run.sh — Cloudflare Tunnel (Docker) for cloud.demonsmp.win
# Uses versioned cf/config.yml (not generated), plus .env via env_file.
# -----------------------------------------------------------------------------

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="$PROJECT_ROOT/docker"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
SERVICE_NAME="cloudflared"

CF_DIR="$PROJECT_ROOT/cf"
CF_CONFIG_FILE="$CF_DIR/config.yml"          # <-- versioned; you maintain this
CF_SECRETS_DIR="$PROJECT_ROOT/secrets"       # holds <TUNNEL_ID>.json (keep out of git)
ENV_FILE="$PROJECT_ROOT/.env"

# Defaults written once to .env (edit later)
DEFAULT_TUNNEL_NAME="homecloud"
DEFAULT_HOSTNAME="cloud.demonsmp.win"
DEFAULT_NAS_IP="192.168.2.10"
DEFAULT_DSM_PORT="5001"
DEFAULT_CF_LOGLEVEL="info"
DEFAULT_METRICS_PORT="38383"

# dockerized cloudflared CLI (persists creds in ./secrets)
CFLARE=(docker run --rm -it \
  -v "$CF_SECRETS_DIR":/home/nonroot/.cloudflared \
  -v "$CF_SECRETS_DIR":/etc/cloudflared \
  cloudflare/cloudflared:latest)

show_help() {
  cat <<EOF
Usage: $(basename "$0") <command>

Cloudflared (Docker):
  start              🟢 docker-compose up -d (requires cf/config.yml)
  stop               🔴 docker-compose down
  logs               📜 docker logs -f $SERVICE_NAME
  status             📊 docker-compose ps
  open               🔗 Open https://\$HOSTNAME

Tunnel (Cloudflare CLI via docker run):
  bootstrap          🔧 Login, create tunnel, DNS route \$HOSTNAME (does NOT write config)
  tunnel-login       🔐 cloudflared tunnel login (browser auth)
  tunnel-create      🏗  cloudflared tunnel create "\$TUNNEL_NAME"
  tunnel-list        📋 List tunnels
  tunnel-dns [host]  🌐 Route DNS (default: \$HOSTNAME) to this tunnel
  tunnel-delete      🗑  Delete tunnel "\$TUNNEL_NAME"
  tunnel-id          🆔 Print detected tunnel ID (from list or secrets)
  tunnel-creds-path  📂 Show expected creds JSON path

Files:
  - $ENV_FILE                  (.env loaded by compose)
  - $COMPOSE_FILE              (written once; uses env_file + mounted cf/config.yml)
  - $CF_CONFIG_FILE            (versioned by you; must include tunnel + credentials-file)
  - $CF_SECRETS_DIR/<id>.json  (created by login/create; mount into container)

Tip:
  In $CF_CONFIG_FILE set, for example:
    tunnel: <TUNNEL_UUID>
    credentials-file: /etc/cloudflared/<TUNNEL_UUID>.json
    ingress:
      - hostname: \${HOSTNAME}
        service: https://\${NAS_IP}:\${DSM_PORT}
        originRequest:
          noTLSVerify: true  # set false after installing Cloudflare Origin Cert on DSM
      - service: http_status:404
EOF
}

ensure_layout() {
  mkdir -p "$COMPOSE_DIR" "$CF_DIR" "$CF_SECRETS_DIR"
  if [[ ! -f "$COMPOSE_FILE" ]]; then
cat > "$COMPOSE_FILE" <<YML
version: "3.9"
services:
  $SERVICE_NAME:
    image: cloudflare/cloudflared:latest
    platform: linux/arm64          # fine on Apple Silicon/Colima
    restart: unless-stopped
    env_file:
      - ../.env
    command: >
      tunnel --config /etc/cloudflared/config.yml run
      --loglevel \${CF_LOGLEVEL}
      --metrics 0.0.0.0:\${METRICS_PORT}
    volumes:
      - ../cf/config.yml:/etc/cloudflared/config.yml:ro
      - ../secrets:/etc/cloudflared:ro
    ports:
      - "\${METRICS_PORT}:\${METRICS_PORT}"   # optional metrics
YML
    echo "🧩 Wrote $COMPOSE_FILE"
  fi
}

ensure_env() {
  if [[ ! -f "$ENV_FILE" ]]; then
cat > "$ENV_FILE" <<EOF
# ---- Cloudflare Tunnel basics ----
TUNNEL_NAME=$DEFAULT_TUNNEL_NAME
HOSTNAME=$DEFAULT_HOSTNAME
# TUNNEL_ID is not required here; reference it directly in cf/config.yml

# ---- NAS origin ----
NAS_IP=$DEFAULT_NAS_IP
DSM_PORT=$DEFAULT_DSM_PORT

# ---- Cloudflared runtime ----
CF_LOGLEVEL=$DEFAULT_CF_LOGLEVEL
METRICS_PORT=$DEFAULT_METRICS_PORT
EOF
    echo "🧩 Wrote $ENV_FILE"
  fi
  # shellcheck disable=SC2046
  set -a; source "$ENV_FILE"; set +a
}

get_tunnel_id() {
  # Prefer list; fallback to first *.json filename in secrets
  local id
  id="$("${CFLARE[@]}" tunnel list 2>/dev/null | awk -v n="$TUNNEL_NAME" '$0 ~ n {print $1; exit}')"
  if [[ -z "${id:-}" ]]; then
    id="$(ls "$CF_SECRETS_DIR"/*.json 2>/dev/null | sed -E 's#.*/##; s#\.json$##' | head -n1 || true)"
  fi
  [[ -n "${id:-}" ]] && echo "$id" || return 1
}

tunnel_creds_path() {
  local tid; tid="$(get_tunnel_id 2>/dev/null || true)"
  if [[ -n "${tid:-}" ]]; then
    echo "$CF_SECRETS_DIR/$tid.json"
  else
    echo "$CF_SECRETS_DIR/<TUNNEL_UUID>.json"
  fi
}

bootstrap() {
  ensure_layout
  ensure_env

  echo "🔐 Login to Cloudflare (accept in browser)…"
  "${CFLARE[@]}" tunnel login

  echo "🏗  Create (or reuse) tunnel: $TUNNEL_NAME"
  "${CFLARE[@]}" tunnel create "$TUNNEL_NAME" || true

  local tid
  tid="$(get_tunnel_id)" || { echo "❌ Could not determine tunnel ID"; exit 1; }

  echo "🆔 Tunnel ID: $tid"
  echo "📂 Credentials JSON: $CF_SECRETS_DIR/$tid.json"
  [[ -f "$CF_SECRETS_DIR/$tid.json" ]] || echo "⚠️  Creds file not found yet. If you ran host cloudflared elsewhere, copy it here."

  echo "🌐 Route DNS: $HOSTNAME → $TUNNEL_NAME"
  "${CFLARE[@]}" tunnel route dns "$TUNNEL_NAME" "$HOSTNAME" || true

  echo "📄 Config is NOT written by this script."
  echo "   Ensure $CF_CONFIG_FILE contains:"
  cat <<SNIP
------------------------------------------------------------
tunnel: $tid
credentials-file: /etc/cloudflared/$tid.json
ingress:
  - hostname: $HOSTNAME
    service: https://$NAS_IP:$DSM_PORT
    originRequest:
      noTLSVerify: true
  - service: http_status:404
------------------------------------------------------------
SNIP
  echo "✅ Bootstrap complete. Now run: $0 start"
}

# ---- main ---------------------------------------------------------------
cmd="${1:-help}"; shift || true

case "$cmd" in
  start)
    ensure_layout; ensure_env
    [[ -f "$CF_CONFIG_FILE" ]] || { echo "❌ Missing $CF_CONFIG_FILE — create & commit it first."; exit 1; }
    echo "🟢 Starting $SERVICE_NAME…"
    (cd "$COMPOSE_DIR" && docker-compose up -d)
    ;;

  stop)
    echo "🔴 Stopping $SERVICE_NAME…"
    (cd "$COMPOSE_DIR" && docker-compose down)
    ;;

  logs)
    docker logs -f "$SERVICE_NAME"
    ;;

  status)
    (cd "$COMPOSE_DIR" && docker-compose ps)
    ;;

  open)
    ensure_env
    if command -v open >/dev/null 2>&1; then open "https://$HOSTNAME"; else echo "🔗 https://$HOSTNAME"; fi
    ;;

  bootstrap)
    bootstrap
    ;;

  tunnel-login)
    "${CFLARE[@]}" tunnel login
    ;;

  tunnel-create)
    ensure_env
    "${CFLARE[@]}" tunnel create "$TUNNEL_NAME" || true
    ;;

  tunnel-list)
    "${CFLARE[@]}" tunnel list || true
    ;;

  tunnel-dns)
    ensure_env
    host="${1:-$HOSTNAME}"
    [[ -n "$host" ]] || { echo "Usage: $0 tunnel-dns <hostname>"; exit 1; }
    "${CFLARE[@]}" tunnel route dns "$TUNNEL_NAME" "$host"
    ;;

  tunnel-delete)
    ensure_env
    "${CFLARE[@]}" tunnel delete "$TUNNEL_NAME"
    ;;

  tunnel-id)
    get_tunnel_id || { echo "❌ No tunnel ID found (create/login first)."; exit 1; }
    ;;

  tunnel-creds-path)
    tunnel_creds_path
    ;;

  help|*)
    show_help
    ;;
esac