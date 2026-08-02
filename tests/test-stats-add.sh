#!/bin/bash
# Общий счётчик трафика (stats.dat) обновляется через _stats_add: один проход awk
# под flock. Раньше каждый сборщик делал grep + sed -i на юзера, и пересечение
# сборщиков (TUI зовёт сбор на каждой перерисовке, крон — по расписанию) теряло
# дельту целиком — P-21. Здесь: арифметика доклада и параллельные докладчики.
# Запуск: bash tests/test-stats-add.sh
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

echo "── Арифметика доклада ──"
printf 'alice|100|200\nbob|5|5\n' > "$STATS_FILE"
printf 'alice|10|20\ncarol|7|8\n' | _stats_add
is "дельта прибавилась к старому значению" "$(get_user_traffic alice)" "alice|110|220"
is "нетронутый юзер сохранился"            "$(get_user_traffic bob)"   "bob|5|5"
is "новый юзер появился"                   "$(get_user_traffic carol)" "carol|7|8"

# Байты нод давно за пределами 32 бит; mawk без %.0f печатает такое научной
# нотацией, и счётчик превращается в «1.4e+09».
printf 'alice|9000000000|1\n' | _stats_add
is "большие числа не уезжают в экспоненту" "$(get_user_traffic alice)" "alice|9000000110|221"

echo
echo "── 20 докладчиков разом ──"
# Каждый — отдельным процессом (в одном шелле flock на общем fd не проверил бы
# ничего): 20 × по 3 байта каждому из двух юзеров.
printf 'alice|0|0\n' > "$STATS_FILE"
for _ in $(seq 20); do
    ( printf 'alice|3|3\nbob|3|3\n' | _stats_add ) &
done
wait
is "ни одна дельта не потерялась (alice)" "$(get_user_traffic alice)" "alice|60|60"
is "ни одна дельта не потерялась (bob)"   "$(get_user_traffic bob)"   "bob|60|60"
is "строк ровно по числу юзеров"          "$(grep -c '^' "$STATS_FILE")" "2"
ls "$DATA_DIR"/stats.dat.tmp.* >/dev/null 2>&1 \
    && bad "временные файлы остались" || ok "временные файлы убраны"

# Пустой доклад (TUIC обычно не резолвит ничего, а зовётся раз в минуту) не
# должен даже переписывать файл: иначе mtime врёт про свежесть данных.
before=$(stat -c %Y "$STATS_FILE")
sleep 1
printf '' | _stats_add
is "пустой доклад не трогает файл" "$(stat -c %Y "$STATS_FILE")" "$before"

echo
[ "$FAIL" = 0 ] && echo "✅ Все проверки прошли" || echo "❌ Есть падения"
exit "$FAIL"
