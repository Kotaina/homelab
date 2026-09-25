#!/usr/bin/env bash
# Restrict the tinyproxy port to trusted sources only.
# WHY: tinyproxy exists solely to proxy n8n's outbound traffic through the
# VPS. It must never be reachable from the public internet — an open listener
# drew a Netcraft/NCSC abuse notice (CVE-2023-49606).
# Rules live in a dedicated chain that is flushed and rebuilt on every run, so
# a changed .env value (e.g. NAS_PUBLIC_IP after an ISP reassignment) replaces
# the stale rule instead of piling up behind the DROP. INPUT only holds a
# single jump into that chain. Docker/Tailscale rules are untouched.
set -euo pipefail

# Load config (VPS/NAS addresses, port) from the out-of-band .env
ENV_FILE="${ENV_FILE:-/opt/homelab/vps/.env}"
set -a; source "$ENV_FILE"; set +a

CHAIN=TINYPROXY

# Sources permitted to reach the proxy:
ALLOW=(
  "$NAS_PUBLIC_IP"       # NAS public IP — the path n8n actually uses
  "$NAS_TAILSCALE_IP"    # NAS tailnet IP — kept for parity (route unused today)
  127.0.0.1              # localhost
)

# Migration: drop legacy per-source ACCEPT/DROP rules on the proxy port that
# earlier versions of this script appended directly to INPUT. Leaves the jump
# into $CHAIN alone. No-op once migrated.
iptables -S INPUT \
  | grep -- "--dport $TINYPROXY_PORT " \
  | grep -v -- "-j $CHAIN\$" \
  | sed 's/^-A /-D /' \
  | while read -r rule; do
      # shellcheck disable=SC2086  #