#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────
# Routing-слой VPS: Tailscale (на хосте) + Caddy (reverse proxy + TLS).
# Идемпотентен. tinyproxy добавляется отдельно, после сверки с рабочим конфигом.
# ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

# --- Секреты (out-of-band, не в git) ---
if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ОШИБКА: нет ${ENV_FILE}. Скопируй .env.example → .env и впиши значения." >&2
  exit 1
fi
set -a; source "${ENV_FILE}"; set +a

# --- Обязательные переменные (fail-fast) ---
: "${BASE_DOMAIN:?задай в .env}"
: "${ACME_EMAIL:?задай в .env}"
: "${NAS_TAILSCALE_IP:?задай в .env}"
: "${TS_AUTHKEY:?задай в .env}"

# --- Зависимости хоста ---
command -v docker   >/dev/null || { echo "нужен docker" >&2; exit 1; }
command -v envsubst >/dev/null || { echo "нужен gettext-base: apt install gettext-base" >&2; exit 1; }

# ── 1. Tailscale (на хосте, не в контейнере) ──
if ! command -v tailscale >/dev/null 2>&1; then
  echo "→ ставлю Tailscale…"
  curl -fsSL https://tailscale.com/install.sh | sh
fi
if tailscale status >/dev/null 2>&1; then
  echo "✓ Tailscale уже в сети"
else
  echo "→ поднимаю Tailscale…"
  tailscale up --authkey "${TS_AUTHKEY}" --hostname vps
fi

# ── 2. Генерация конфига из шаблона (декларативно: перезапись целиком) ──
echo "→ генерирую Caddyfile…"
envsubst '${BASE_DOMAIN} ${ACME_EMAIL} ${NAS_TAILSCALE_IP}' \
  < "${SCRIPT_DIR}/Caddyfile.template" \
  > "${SCRIPT_DIR}/Caddyfile"

# ── 3. Caddy ──
echo "→ поднимаю Caddy…"
docker compose -f "${SCRIPT_DIR}/docker-compose.yml" up -d

echo "✓ Готово. Проверь https://n8n.${BASE_DOMAIN}"