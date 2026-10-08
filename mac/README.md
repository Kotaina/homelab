# mac/ — клиентская часть на Маке

## SwiftBar-плагин `nas`

Точка входа к homelab из строки меню: «Дома / Не дома», статус VPS (Caddy, TG-прокси),
NAS по запросу (маршрут LAN → tailnet), дашборд, SMB-папки.

### Установка
1. `brew install --cask swiftbar`
2. `cp mac/.env.example mac/.env` и заполнить. `BASE_DOMAIN` и `NAS_TAILSCALE_IP` дублируются из vps/env.
3. SwiftBar → папка плагинов: `mac/swiftbar/` (только плагины — SwiftBar запускает всё, что в ней лежит).
