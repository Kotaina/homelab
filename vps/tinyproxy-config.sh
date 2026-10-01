#!/usr/bin/env bash
# Собирает /etc/tinyproxy/tinyproxy.conf из vps/tinyproxy.conf.template и vps/.env.
# Идемпотентно: если итоговый конфиг не изменился — ничего не трогает.
# При изменении кладёт резервную копию старого рядом (*.bak.<дата>) и перезапускает tinyproxy.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$DIR/.env}"   # как в tinyproxy-firewall.sh: можно переопределить
TEMPLATE="$DIR/tinyproxy.conf.template"
TARGET="/etc/tinyproxy/tinyproxy.conf"
VARS='${TINYPROXY_PORT} ${VPS_PUBLIC_IP} ${NAS_PUBLIC_CIDR} ${NAS_TAILSCALE_IP}'

set -a; . "$ENV_FILE"; set +a
: "${TINYPROXY_PORT:?нет TINYPROXY_PORT в .env}"
: "${VPS_PUBLIC_IP:?нет VPS_PUBLIC_IP в .env}"
: "${NAS_PUBLIC_CIDR:?нет NAS_PUBLIC_CIDR в .env}"
: "${NAS_TAILSCALE_IP:?нет NAS_TAILSCALE_IP в .env}"

# зависимости (на новом сервере)
command -v tinyproxy >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq tinyproxy; }
command -v envsubst  >/dev/null 2>&1 || apt-get install -y -qq gettext-base

TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
envsubst "$VARS" < "$TEMPLATE" > "$TMP"

if cmp -s "$TMP" "$TARGET"; then
  echo "tinyproxy: конфиг без изменений"
else
  [ -f "$TARGET" ] && cp -p "$TARGET" "$TARGET.bak.$(date +%Y%m%d-%H%M%S)"
  install -m 644 "$TMP" "$TARGET"
  systemctl restart tinyproxy
  echo "tinyproxy: конфиг обновлён, сервис перезапущен"
fi

systemctl is-active --quiet tinyproxy || { echo "tinyproxy: сервис не запущен!" >&2; exit 1; }
