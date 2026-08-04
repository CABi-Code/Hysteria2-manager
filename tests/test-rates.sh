#!/bin/bash
# Спидометр: collect_rates считает дельту кумулятива протоколов и пишет её в
# rates.dat, а сам кумулятив — в rates_prev.dat. Ловим P-43: mawk печатает %d
# 32-битным int, и кумулятив Xray больше 2 ГБ ложился в базу как 2147483647 —
# следующий тик считал дельту «настоящий кумулятив − 2147483647» и спидометр
# намертво вставал на сотни Мбит/с.
# Запуск: bash tests/test-rates.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export HY2M_DATA_DIR=$(mktemp -d)
export HY2M_WEBROOT="$HY2M_DATA_DIR/web"
mkdir -p "$HY2M_WEBROOT"
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT

source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/traffic.sh"

FAIL=0
ok()  { echo "  ✅ $1"; }
bad() { echo "  ❌ $1"; FAIL=1; }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1 (ждали «$3», получили «$2»)"; }

# Заглушки внешнего мира: Hysteria по нулям, весь кумулятив даёт Xray.
node_label() { echo "тест"; }
api_get() { echo '{"alice":{"tx":0,"rx":0}}'; }
XRAY_DOWN=0
proto_xray_split_lines() { printf 'alice|%s|0\n' "$XRAY_DOWN"; }

field() { grep "^alice|" "$1" 2>/dev/null | cut -d'|' -f"$2"; }

echo "── Кумулятив за 2 ГБ ──"
XRAY_DOWN=3000000000
collect_rates
is "база хранит кумулятив целиком, без обрезки до 2^31-1" "$(field "$RATES_PREV_FILE" 2)" "3000000000"

XRAY_DOWN=3000001000   # +1000 байт за тик (тики в одной секунде → el=1)
collect_rates
is "скорость = реальная дельта, а не «кумулятив − 2147483647»" "$(field "$RATES_FILE" 2)" "1000"
is "база обновилась новым кумулятивом" "$(field "$RATES_PREV_FILE" 2)" "3000001000"

echo
echo "── Счётчик движка обнулился (рестарт) ──"
XRAY_DOWN=500
collect_rates
is "весь текущий кумулятив и есть дельта" "$(field "$RATES_FILE" 2)" "500"

echo
[ "$FAIL" = 0 ] && echo "Все проверки пройдены." || echo "Есть падения."
exit "$FAIL"
