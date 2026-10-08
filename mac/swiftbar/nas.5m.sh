#!/bin/bash
# <xbar.title>NAS</xbar.title>
# <xbar.desc>Точка входа к NAS: статус, SMB-папки, дашборд</xbar.desc>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
[ -f "$REPO_DIR/mac/.env" ] && . "$REPO_DIR/mac/.env"

LAN_HOST="${NAS_LAN_IP:-}"
TAIL_HOST="${NAS_TAILSCALE_IP:-}"
# Имена из /etc/hosts для монтирования: Finder подписывает сервер в сайдбаре адресом подключения.
# Доступность проверяется по IP, монтируется по имени (если задано).
LAN_ADDR="${NAS_LAN_NAME:-$LAN_HOST}"
TAIL_ADDR="${NAS_TAIL_NAME:-$TAIL_HOST}"
NAS_MAC="${NAS_LAN_MAC:-}"        # пусто — LAN засчитывается по подсети, без проверки MAC (менее надёжно)
SHARES="${SMB_SHARES:-}"
VPS_HOST="files.${BASE_DOMAIN:-}" # проверка VPS: TCP до Caddy, до NAS не доходит
VPS_PORT="${CADDY_PORT:-}"
DASH_URL="https://dash.${BASE_DOMAIN:-}"
FILES_FALLBACK="https://files.${BASE_DOMAIN:-}:${CADDY_PORT:-}"  # если SMB недоступен
STALE_STRIKES=2                   # фоновых проверок «Не дома» подряд до отключения LAN-папок
# ──────────────────────────────────────────────────────────────────────────

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
STATE="${TMPDIR:-/tmp}/swiftbar-nas.stale"
ROUTE_FILE="${TMPDIR:-/tmp}/swiftbar-nas.route"            # последняя проверка NAS: route|host|время
HOME_FILE="$HOME/Library/Caches/swiftbar-nas.home"          # MAC домашнего роутера (запоминается сам)
TS_CLI="/Applications/Tailscale.app/Contents/MacOS/Tailscale"

notify() { osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1; }

# ── Проверки ──────────────────────────────────────────────────────────────

# SMB-порт открыт → маршрут рабочий (только TCP-рукопожатие, без входа и чтения)
probe() { nc -z -G 1 -w 2 "$1" 445 >/dev/null 2>&1; }

check_vps() { nc -z -G 2 -w 3 "$VPS_HOST" "$VPS_PORT" >/dev/null 2>&1; }

# Проверка NAS (только по запросу). Выставляет LAN_OK, TAIL_OK, NAS, ROUTE и запоминает результат.
check_nas() {
  probe "$LAN_HOST" & p1=$!
  probe "$TAIL_HOST" & p2=$!
  if wait $p1; then LAN_OK=1; else LAN_OK=0; fi
  if wait $p2; then TAIL_OK=1; else TAIL_OK=0; fi
  [ $LAN_OK = 1 ] && ! our_nas_on_lan && LAN_OK=0   # ответил не наш NAS / не по локальной сети
  if   [ $LAN_OK = 1 ];  then NAS="$LAN_HOST";  MOUNT_HOST="$LAN_ADDR";  ROUTE=lan
  elif [ $TAIL_OK = 1 ]; then NAS="$TAIL_HOST"; MOUNT_HOST="$TAIL_ADDR"; ROUTE=tail
  else NAS="";  MOUNT_HOST="";  ROUTE=none
  fi
  echo "$ROUTE|$NAS|$(date +%H:%M)" > "$ROUTE_FILE"
  # Наш NAS ответил по LAN → мы дома: запоминаем роутер, чтобы потом узнавать дом без запросов к NAS
  if [ $LAN_OK = 1 ] && [ -n "$NAS_MAC" ]; then
    mac=$(router_mac) && [ -n "$mac" ] && mkdir -p "$(dirname "$HOME_FILE")" && echo "$mac" > "$HOME_FILE"
  fi
}

# MAC к виду aa:bb:0c:... (macOS в arp отбрасывает ведущие нули)
norm_mac() {
  tr 'A-F' 'a-f' | awk -F: 'NF==6{for(i=1;i<=6;i++){o=$i; if(length(o)==1)o="0"o; printf "%s%s",(i>1?":":""),o}; print ""}'
}
mac_of() { arp -n "$1" 2>/dev/null | awk '{print $4}' | norm_mac | grep .; }

# MAC роутера текущей сети (из ARP-кэша Мака, без трафика)
router_mac() {
  r=""
  for i in en0 en1; do r=$(ipconfig getoption "$i" router 2>/dev/null); [ -n "$r" ] && break; done
  [ -z "$r" ] && return 1
  mac_of "$r"
}

# Хост в напрямую подключённой подсети Wi-Fi/Ethernet (таблица маршрутов, без трафика)
on_link() {
  out=$(route -n get "$1" 2>/dev/null) || return 1
  printf '%s\n' "$out" | grep -q 'gateway:' && return 1
  printf '%s\n' "$out" | grep -qE 'interface: en[0-9]'   # не через utun (Tailscale/VPN)
}

# LAN-адрес отвечает именно нашим NAS в локальной сети: совпал MAC (без NAS_MAC — хотя бы в подсети Wi-Fi/Ethernet)
our_nas_on_lan() {
  if [ -n "$NAS_MAC" ]; then
    [ "$(mac_of "$LAN_HOST")" = "$(echo "$NAS_MAC" | norm_mac)" ]
  else
    on_link "$LAN_HOST"
  fi
}

# Дома = роутер совпадает с запомненным; пока не запомнен — NAS-подсеть подключена напрямую
at_home() {
  if [ -s "$HOME_FILE" ]; then
    mac=$(router_mac) || return 1
    [ "$mac" = "$(cat "$HOME_FILE")" ]
  else
    on_link "$LAN_HOST"
  fi
}

tailscale_up() {
  if [ -x "$TS_CLI" ]; then
    "$TS_CLI" status >/dev/null 2>&1
  else
    ifconfig 2>/dev/null | awk '/^[a-z]/{u=($1 ~ /^utun/)} u && /inet 100\./{f=1} END{exit !f}'
  fi
}

# ── SMB ───────────────────────────────────────────────────────────────────

host_ok() {
  case "$1" in
    "$LAN_HOST")  [ "$LAN_OK" = 1 ] ;;
    "$TAIL_HOST") [ "$TAIL_OK" = 1 ] ;;
    *) return 0 ;;
  esac
}

# Смонтированные папки NAS: host|share|mountpoint (host приводится к IP, даже если монтировали по имени)
smb_mounts() {
  mount | sed -nE 's#^//([^@]*@)?([^/]+)/([^ ]+) on (.+) \(smbfs.*#\2|\3|\4#p' |
    awk -F'|' -v OFS='|' -v a="$LAN_HOST" -v b="$TAIL_HOST" -v an="$LAN_ADDR" -v bn="$TAIL_ADDR" '
      { h = tolower($1) }
      h == tolower(an) { $1 = a }
      h == tolower(bn) { $1 = b }
      $1 == a || $1 == b'
}

mount_of() { smb_mounts | awk -F'|' -v s="$1" 'tolower($2)==tolower(s){print; exit}'; }

do_mount() {
  share="$1"
  check_nas
  line=$(mount_of "$share")
  if [ -n "$line" ]; then
    h="${line%%|*}"; mp="${line##*|}"
    if host_ok "$h"; then open "$mp"; return; fi
    diskutil unmount force "$mp" >/dev/null 2>&1   # смонтирована по пропавшему маршруту
  fi
  if [ -z "$NAS" ]; then
    notify "NAS: SMB недоступен" "Нет ни LAN, ни tailnet — открываю файлы в браузере"
    open "$FILES_FALLBACK"
    return
  fi
  # Тихое монтирование с кредами из Keychain (без диалога Finder)
  if ! osascript -e "mount volume \"smb://$MOUNT_HOST/$share\"" >/dev/null 2>&1; then
    notify "NAS: не удалось подключить $share" "smb://$MOUNT_HOST/$share"
    return
  fi
  line=$(mount_of "$share")
  open "${line##*|}"
}

do_check() {
  check_nas
  case "$ROUTE" in
    lan)  notify "NAS доступен" "Домашняя сеть, $LAN_HOST" ;;
    tail) notify "NAS доступен" "Через tailnet, $TAIL_HOST" ;;
    none) notify "NAS не доступен" "Ни $LAN_HOST, ни $TAIL_HOST" ;;
  esac
}

do_unmount_all() {
  smb_mounts | while IFS='|' read -r h s mp; do
    diskutil unmount force "$mp" >/dev/null 2>&1
  done
  : > "$STATE"
}

# LAN-папка, когда мы не дома STALE_STRIKES проверок подряд, отключается сама —
# иначе Finder виснет на мёртвом smb://. Папки через tailnet сами не отключаются.
cleanup_stale() {
  STALE_N=0
  new_state=""
  mounts=$(smb_mounts)
  while IFS='|' read -r h s mp; do
    [ -z "$mp" ] && continue
    [ "$h" = "$LAN_HOST" ] || continue
    [ "$HOME_NOW" = 1 ] && continue
    n=$(awk -F'|' -v m="$mp" '$1==m{print $2}' "$STATE" 2>/dev/null)
    n=$(( ${n:-0} + 1 ))
    if [ "$n" -ge "$STALE_STRIKES" ]; then
      diskutil unmount force "$mp" >/dev/null 2>&1 &
      notify "NAS: отключил папку $s" "Домашняя сеть больше недоступна"
    else
      new_state="${new_state}${mp}|${n}
"
      STALE_N=$((STALE_N + 1))
    fi
  done <<EOF
$mounts
EOF
  printf '%s' "$new_state" > "$STATE"
}

# ── Меню ──────────────────────────────────────────────────────────────────

render_menu() {
  # fail-fast: без конфига показываем, чего не хватает, вместо кривого меню
  missing=""
  for v in NAS_LAN_IP NAS_TAILSCALE_IP BASE_DOMAIN CADDY_PORT TG_PROXY_PORT SMB_SHARES; do
    eval "val=\"\${$v:-}\""
    # пусто или заглушка из .env.example
    case "$val" in ""|*example.com*|*x.x*|xxxx) missing="$missing $v" ;; esac
  done
  if [ -n "$missing" ]; then
    echo "NAS | sfimage=exclamationmark.triangle.fill"
    echo "---"
    echo "Не заданы в mac/.env:$missing"
    echo "Открыть папку mac/ (шаблон .env.example) | bash=/usr/bin/open param1=\"$REPO_DIR/mac\" terminal=false"
    return
  fi
  if at_home; then HOME_NOW=1; else HOME_NOW=0; fi
  if check_vps; then VPS_OK=1; else VPS_OK=0; fi
  if nc -z -G 2 -w 3 "$VPS_HOST" "$TG_PROXY_PORT" >/dev/null 2>&1; then TG_OK=1; else TG_OK=0; fi
  NOW=$(date +%H:%M)
  cleanup_stale
  L_ROUTE=""; L_HOST=""; L_TIME=""
  [ -f "$ROUTE_FILE" ] && IFS='|' read -r L_ROUTE L_HOST L_TIME < "$ROUTE_FILE"

  # Трей: где я
  if [ "$HOME_NOW" = 1 ]; then echo "Дома | sfimage=house.fill"
  else                         echo "Не дома | sfimage=figure.walk"
  fi
  echo "---"

  # Tailscale
  if tailscale_up; then
    echo "Tailscale: On | bash=/usr/bin/open param1=-a param2=Tailscale terminal=false sfimage=checkmark.circle"
  else
    echo "Tailscale: Off — открыть | bash=/usr/bin/open param1=-a param2=Tailscale terminal=false sfimage=power"
  fi

  # VPS
  if [ "$VPS_OK" = 1 ]; then
    echo "VPS: Доступен | sfimage=checkmark.circle"
    echo "--Caddy :$VPS_PORT — OK | sfimage=checkmark.circle"
  else
    echo "VPS: Не доступен | sfimage=xmark.circle"
    echo "--Caddy :$VPS_PORT — не отвечает | sfimage=xmark.circle"
  fi
  if [ "$TG_OK" = 1 ]; then echo "--TG-прокси :$TG_PROXY_PORT — OK | sfimage=checkmark.circle"
  else                      echo "--TG-прокси :$TG_PROXY_PORT — не отвечает | sfimage=xmark.circle"
  fi
  echo "--Проверено $NOW | sfimage=clock"
  echo "--Обновить | refresh=true sfimage=arrow.clockwise"

  # Дашборд
  echo "Открыть дашборд | href=$DASH_URL sfimage=arrow.up.right.square"

  echo "---"
  case "$L_ROUTE" in
    lan|tail) echo "NAS: Доступен ($L_TIME) | sfimage=checkmark.circle" ;;
    none)     echo "NAS: Не доступен ($L_TIME) | sfimage=xmark.circle" ;;
    *)        echo "NAS: Неизвестно | sfimage=questionmark.circle" ;;
  esac
  case "$L_ROUTE" in
    lan)  echo "Маршрут: LAN $L_HOST | sfimage=house" ;;
    tail) echo "Маршрут: Tailscale $L_HOST | sfimage=network" ;;
    none) echo "Маршрут: нет | sfimage=xmark.circle" ;;
    *)    echo "Маршрут: не проверялся | sfimage=questionmark.circle" ;;
  esac
  echo "Проверить NAS | bash=\"$SELF\" param1=check terminal=false refresh=true sfimage=arrow.triangle.2.circlepath"

  # SMB
  echo "---"
  echo "Папки (SMB)"
  for s in $SHARES; do
    extra=""
    [ -n "$(mount_of "$s")" ] && extra=" checked=true"
    echo "$s | bash=\"$SELF\" param1=mount param2=$s terminal=false refresh=true sfimage=folder$extra"
  done
  [ "$STALE_N" -gt 0 ] && echo "Не дома — LAN-папки скоро отключу | sfimage=exclamationmark.triangle"
  echo "Отключить папки NAS | bash=\"$SELF\" param1=unmount terminal=false refresh=true sfimage=eject"
  echo "---"
  echo "Обновить | refresh=true sfimage=arrow.clockwise"
}

case "$1" in
  mount)   do_mount "$2" ;;
  check)   do_check ;;
  unmount) do_unmount_all ;;
  *)       render_menu ;;
esac
