#!/bin/bash
# Параллельная публикация в cluster/ не должна ронять друг друга: у каждого
# процесса свой временный файл (см. publish_stats в lib/publish.sh).
# Раньше все писали в общий «stats.tmp» — второй процесс уносил его mv'ом, и в
# error.log сыпалось «mv: cannot stat …/stats.tmp». Крон дёргает --online-sync
# раз в минуту и --cluster-sync раз в 5 — пересечения регулярны.
# Запуск: bash tests/test-publish-race.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export HY2M_DATA_DIR=$(mktemp -d)
export HY2M_WEBROOT="$HY2M_DATA_DIR/web"
mkdir -p "$HY2M_WEBROOT/cluster"
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT

source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/publish.sh"

# Заглушки окружения ноды: сеть, права и таблицы трафика тут не при чём.
sub_enabled()           { return 0; }
secure_web_files()      { :; }
api_get()               { echo '{"alice":1,"bob":0}'; }
get_user_traffic()      { echo "$1|100|200"; }
get_user_speed()        { echo "$1|10|20"; }
get_user_active()       { echo 1; }
get_user_active_since() { echo 1700000000; }
printf 'alice:pw1\nbob:pw2\n' > "$USERS_DB"

FAIL=0
ok()  { echo "  ✅ $1"; }
bad() { echo "  ❌ $1"; FAIL=1; }

echo "── 10 публикаций разом"
ERR="$HY2M_DATA_DIR/err"
for _ in $(seq 10); do
    # Каждая — в своём процессе: в одном шелле $$ совпал бы, а крон запускает
    # именно отдельные процессы.
    ( publish_stats ) 2>>"$ERR" &
done
wait

[ -s "$ERR" ] && bad "stderr не пуст: $(head -1 "$ERR")" || ok "ни одной ошибки mv"

lines=$(wc -l < "$WEBROOT/cluster/stats" 2>/dev/null || echo 0)
[ "$lines" = "2" ] && ok "stats цел: 2 строки" || bad "stats битый: строк $lines, ждали 2"

leftovers=$(find "$WEBROOT/cluster" -name 'stats.tmp*' | wc -l)
[ "$leftovers" = "0" ] && ok "временных файлов не осталось" || bad "осталось tmp: $leftovers"

echo ""
[ "$FAIL" = 0 ] && echo "✅ Все проверки пройдены" || echo "❌ Есть ошибки"
exit "$FAIL"
