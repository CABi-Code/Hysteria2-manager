#!/bin/bash
# Применение Caddyfile не роняет работающий Caddy (P-176): неудачное
# перечитывание — откат файла без перезапуска; лежащий Caddy с новым конфигом
# не поднялся — откат и запуск на прежнем. Раньше здесь стоял
# «reload || restart», и отказ нового конфига становился простоем всех сайтов.
# Запуск: bash tests/test-caddy-apply.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export HY2M_DATA_DIR=$(mktemp -d)
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/caddy.sh"
CADDYFILE="$HY2M_DATA_DIR/Caddyfile"
CALLS="$HY2M_DATA_DIR/calls"

FAIL=0
ok()  { echo "  ✅ $1"; }
bad() { echo "  ❌ $1"; FAIL=1; }
sleep() { :; }

# Заглушка systemd: состояние — в файле, reload/start удаются или нет по флагам.
STATE="$HY2M_DATA_DIR/state"
systemctl() {
    echo "$*" >> "$CALLS"
    case "$1" in
        is-active) [ "$(cat "$STATE")" = active ] ;;
        reload)    [ "${RELOAD_OK:-1}" = 1 ] ;;
        start)     if grep -q NEW "$CADDYFILE" && [ "${NEW_STARTS:-1}" = 0 ]; then echo failed > "$STATE"; return 1; fi
                   echo active > "$STATE" ;;
        restart)   echo failed > "$STATE"; return 1 ;;   # именно так и выглядел простой
        *)         return 0 ;;
    esac
}
prep() { echo OLD > "$HY2M_DATA_DIR/bak"; echo NEW > "$CADDYFILE"; : > "$CALLS"; echo "$1" > "$STATE"; }

echo "── работающий Caddy, перечитывание удалось"
prep active; RELOAD_OK=1 _caddy_apply "$HY2M_DATA_DIR/bak" && ok "успех" || bad "ждали успех"
grep -q NEW "$CADDYFILE" && ok "новый конфиг остался" || bad "новый конфиг пропал"

echo "── работающий Caddy, новый конфиг не принят"
prep active; RELOAD_OK=0 _caddy_apply "$HY2M_DATA_DIR/bak" && bad "отказ не замечен" || ok "отказ замечен"
grep -qE '^(restart|stop)' "$CALLS" && bad "работающий Caddy перезапускали: $(paste -sd' ' "$CALLS")" || ok "процесс не трогали"
[ "$(cat "$STATE")" = active ] && ok "Caddy продолжает отвечать" || bad "Caddy лёг"
grep -q OLD "$CADDYFILE" && ok "файл вернулся к прежнему — следующий старт поднимется" || bad "в файле остался непринятый конфиг"

echo "── Caddy лежал, новый конфиг не поднимается"
prep failed; NEW_STARTS=0 _caddy_apply "$HY2M_DATA_DIR/bak" && bad "отказ не замечен" || ok "отказ замечен"
grep -q OLD "$CADDYFILE" && ok "откат на прежний" || bad "отката нет"
[ "$(cat "$STATE")" = active ] && ok "поднят на прежнем конфиге" || bad "Caddy так и лежит"

[ "$FAIL" = 0 ] && echo "✅ test-caddy-apply: перечитывание не роняет Caddy" || { echo "❌ test-caddy-apply"; exit 1; }
