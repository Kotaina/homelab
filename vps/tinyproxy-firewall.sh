#!/usr/bin/env bash
# Restrict the tinyproxy port to trusted sources only.
# WHY: tinyproxy exists solely to proxy n8n's outbound traffic through the
# VPS. It must never be reachable from the public internet — an open listener
# drew a Netcraft/NCSC abuse notice (CVE-2023-49606).
# Idempotent: -C tests each rule, -A adds it only when missing. Touches only
# the proxy port — Docker/Tailscale rules are untouched.
set -euo pipefail

# Load config (VPS/NAS addresses, port) from the out-of-band .env
ENV_FILE="${ENV_FILE:-/opt/homelab/vps/.env}"
set -a; source "$ENV_FILE"; set +a

# Sources permitted to reach the proxy:
ALLOW=(
  "$NAS_PUBLIC_IP"       # NAS public IP — the path n8n actually uses
  "$NAS_TAILSCALE_IP"    # NAS tailnet IP — kept for parity (route unused today)
  127.0.0.1              # localhost
)

for src in "${ALLOW[@]}"; do
  iptables -C INPUT -p tcp --dport "$TINYPROXY_PORT" -s "$src" -j ACCEPT 2>/dev/null \
    || iptables -A INPUT -p tcp --dport "$TINYPROXY_PORT" -s "$src" -j ACCEPT
done

# Everything else to the proxy port is dropped. Appended last so it sits after
# the ACCEPTs (iptables matches top-to-bottom).
iptables -C INPUT -p tcp --dport "$TINYPROXY_PORT" -j DROP 2>/dev/null \
  || iptables -A INPUT -p tcp --dport "$TINYPROXY_PORT" -j DROP