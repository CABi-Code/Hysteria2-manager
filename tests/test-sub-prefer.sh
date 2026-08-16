#!/bin/bash
# Предпочитаемый ключ подписки (P-76): sub_prefer_sort поднимает выбранный
# «host/протокол» наверх, остальной порядок не трогает; хранение переживает
# правку соседних полей и кластерную синхронизацию.
# Запуск: bash tests/test-sub-prefer.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export HY2M_DATA_DIR=$(mktemp -d)
export HY2M_WEBROOT="$HY2M_DATA_DIR/web"
mkdir -p "$HY2M_WEBROOT/cluster" "$HY2M_DATA_DIR/peers"
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT

source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/limits.sh"
source "$SCRIPT_DIR/lib/sub_links.sh"

FAIL=0
ok() { echo "  ✅ $1"; }
no() { echo "  ❌ $1"; FAIL=1; }
is() { [ "$2" = "$3" ] && ok "$1" || { no "$1"; echo "     ждали: $3"; echo "     вышло: $2"; }; }

# Подписка как её собирает regen_user_subscription: своя нода первой, пиры следом.
LINKS='hysteria2://ann:pw@fin.example:443/?obfs=salamander#fin
vless://uuid@fin.example:443?type=tcp#fin
hysteria2://ann:pw@de.example:443/?obfs=salamander#de
vless://uuid@de.example:443?type=tcp#de
tuic://uuid:pw@de.example:2443?alpn=h3#de'

echo "── Без предпочтения порядок не меняется ──"
out=$(printf '%s\n' "$LINKS" | sub_prefer_sort ann)
is "список как был" "$out" "$LINKS"

echo "── Выбранный ключ уходит наверх ──"
set_user_prefer ann "de.example/vless"
is "поле сохранено" "$(get_user_prefer ann)" "de.example/vless"
out=$(printf '%s\n' "$LINKS" | sub_prefer_sort ann)
is "первым — VLESS выбранной ноды" "$(head -1 <<< "$out")" "vless://uuid@de.example:443?type=tcp#de"
is "строки не потерялись" "$(wc -l <<< "$out")" "$(wc -l <<< "$LINKS")"
is "остальные в прежнем порядке" "$(tail -n +2 <<< "$out")" "$(grep -vF 'vless://uuid@de.example' <<< "$LINKS")"

echo "── Протокол различает ключи одной ноды ──"
set_user_prefer ann "de.example/hysteria2"
is "первым — Hysteria2 той же ноды" "$(printf '%s\n' "$LINKS" | sub_prefer_sort ann | head -1)" \
   "hysteria2://ann:pw@de.example:443/?obfs=salamander#de"

echo "── Исчезнувший ключ не ломает подписку ──"
set_user_prefer ann "gone.example/vless"
out=$(printf '%s\n' "$LINKS" | sub_prefer_sort ann)
is "список как был" "$out" "$LINKS"

echo "── Мусор в поле не сохраняется ──"
set_user_prefer ann "de.example|vless"      # разделитель файла внутри значения
is "значение отвергнуто" "$(get_user_prefer ann)" ""

echo "── Соседние поля не стирают выбор ──"
set_user_prefer ann "de.example/tuic"
set_user_devices ann 5
set_user_rate ann 100
is "выбор на месте" "$(get_user_prefer ann)" "de.example/tuic"
is "устройства на месте" "$(get_user_devices ann)" "5"
is "скорость на месте" "$(get_user_rate ann)" "100"

echo "── Запись строки: prefer это 5-е поле ──"
is "строка файла" "$(grep '^ann|' "$USERLIMITS_FILE")" "ann|5|0|100|de.example/tuic"

[ "$FAIL" = 0 ] && echo "ВСЁ ЗЕЛЁНОЕ" || echo "ЕСТЬ ПАДЕНИЯ"
exit "$FAIL"
