#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# mc-proxy-fw.sh
#
# Manage iptables-based DNAT from Oracle (mc-proxy) → Synology over Tailscale.
#
# Commands:
#   help        - show usage
#   add         - enable IP forwarding + add DNAT/FORWARD/MASQUERADE rules
#   test-local  - test connectivity from mc-proxy to Synology (Tailscale IP)
#   test-public - test connectivity from the internet via mc1.demonsmp.win
#   persist     - install iptables-persistent (if needed) and save rules
#   show        - show relevant iptables rules
#
# Edit SYNO_TS_IP / PUBLIC_HOST / PORTS as needed.
# -----------------------------------------------------------------------------

SYNO_TS_IP="100.101.105.75"       # Tailscale IP of "cloud" (Synology DS720)
PUBLIC_HOST="mc1.demonsmp.win"    # Public DNS name of mc-proxy

# Core ports currently in use
PORTS_CORE=(6690 5001 32400)

# Optional ports (e.g. Synology Drive Web 6691) - may be closed on NAS.
PORTS_OPTIONAL=(6691)

# Merge into one list. Comment out PORTS_OPTIONAL if you don't care about them.
PORTS=("${PORTS_CORE[@]}" "${PORTS_OPTIONAL[@]}")

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "❌ This command must be run as root (sudo)." >&2
    exit 1
  fi
}

need_nc() {
  if ! command -v nc >/dev/null 2>&1; then
    echo "❌ nc (netcat) is required for tests. Install 'netcat-openbsd' or similar." >&2
    exit 1
  fi
}

enable_ip_forward() {
  echo "⚙️  Enabling IPv4 forwarding..."
  echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-forwarding.conf
  sysctl -p /etc/sysctl.d/99-forwarding.conf
}

add_fw_rules() {
  echo "🧱 Adding iptables rules for Synology @ ${SYNO_TS_IP}..."

  # 1. Allow established flows
  iptables -C FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null \
    || iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

  # 2. Allow new inbound to Synology ports over Tailscale
  for port in "${PORTS[@]}"; do
    iptables -C FORWARD -p tcp -d "${SYNO_TS_IP}" --dport "${port}" -j ACCEPT 2>/dev/null \
      || iptables -A FORWARD -p tcp -d "${SYNO_TS_IP}" --dport "${port}" -j ACCEPT
  done

  # 3. DNAT external → Synology via Tailscale
  for port in "${PORTS[@]}"; do
    iptables -t nat -C PREROUTING -p tcp --dport "${port}" \
      -j DNAT --to-destination "${SYNO_TS_IP}:${port}" 2>/dev/null \
      || iptables -t nat -A PREROUTING -p tcp --dport "${port}" \
         -j DNAT --to-destination "${SYNO_TS_IP}:${port}"
  done

  # 4. Masquerade outbound traffic so Synology replies via mc-proxy
  iptables -t nat -C POSTROUTING -d "${SYNO_TS_IP}" -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -d "${SYNO_TS_IP}" -j MASQUERADE

  echo "✅ Rules added (or already present)."
}

test_local() {
  need_nc
  echo "🔍 Testing connectivity from mc-proxy → Synology (${SYNO_TS_IP})..."

  for port in "${PORTS[@]}"; do
    echo -n "  - ${SYNO_TS_IP}:${port} ... "
    if nc -vz -w 3 "${SYNO_TS_IP}" "${port}" >/dev/null 2>&1; then
      echo "✅ open"
    else
      echo "⚠️ refused/closed"
    fi
  done

  echo
  echo "ℹ️  'refused/closed' usually means the NAS is reachable but there is no service"
  echo "    listening on that port (e.g. 6691 if Synology Drive Web is disabled)."
}

test_public() {
  need_nc
  echo "🌍 Testing connectivity from outside via ${PUBLIC_HOST}..."

  for port in "${PORTS[@]}"; do
    echo -n "  - ${PUBLIC_HOST}:${port} ... "
    if nc -vz -w 3 "${PUBLIC_HOST}" "${port}" >/dev/null 2>&1; then
      echo "✅ open"
    else
      echo "⚠️ refused/closed"
    fi
  done

  echo
  echo "ℹ️  If local tests succeed but public ones fail, check:"
  echo "    - Oracle security groups / firewall"
  echo "    - Host firewall rules"
}

persist_rules() {
  need_root
  echo "💾 Installing iptables-persistent (if needed) and saving rules..."
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent
  netfilter-persistent save
  echo "✅ iptables rules saved and will survive reboot."
}

show_rules() {
  echo "📋 Filter table (FORWARD-related):"
  iptables -S FORWARD | sed 's/^/- /'

  echo
  echo "📋 NAT table (PREROUTING/POSTROUTING):"
  iptables -t nat -S PREROUTING | sed 's/^/- /'
  echo
  iptables -t nat -S POSTROUTING | sed 's/^/- /'
}

show_help() {
  cat <<EOF
Usage: $0 <command>

Commands:
  help         Show this help.
  add          Enable IP forwarding and add iptables DNAT/FORWARD/MASQUERADE rules.
  test-local   Test mc-proxy → Synology (${SYNO_TS_IP}) connectivity on all ports.
  test-public  Test Internet → ${PUBLIC_HOST} connectivity on all ports.
  persist      Install iptables-persistent (if needed) and save current rules.
  show         Show relevant iptables rules.

Config:
  SYNO_TS_IP   = ${SYNO_TS_IP}
  PUBLIC_HOST  = ${PUBLIC_HOST}
  PORTS        = ${PORTS[*]}

Notes:
  - If a port like 6691 shows "refused/closed" even in test-local, the NAS is
    reachable but no service is bound there. Comment it out in PORTS if unused.
EOF
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
cmd="${1:-help}"

case "${cmd}" in
  help)
    show_help
    ;;
  add)
    need_root
    enable_ip_forward
    add_fw_rules
    ;;
  test-local)
    test_local
    ;;
  test-public)
    test_public
    ;;
  persist)
    persist_rules
    ;;
  show)
    show_rules
    ;;
  *)
    echo "❌ Unknown command: ${cmd}" >&2
    show_help
    exit 1
    ;;
esac