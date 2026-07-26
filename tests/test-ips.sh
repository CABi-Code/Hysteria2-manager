#!/bin/bash
# Сбор IP (lib/ip_tracking.sh): разбор журнала, слияние истории одним awk и
# чистка записей старше IPS_RETENTION_DAYS. Раньше на каждую строку журнала шли
# grep + sed -i (полная перезапись файла), а старые записи не выбрасывались.
# Запуск: bash tests/test-ips.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export HY2M_DATA_DIR=$(mktemp -d)
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT

source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/ip_tracking.sh"

FAIL=0
ok()    { echo "  ✅ $1"; }
bad()   { echo "  ❌ $1"; FAIL=1; }
check() { [ "$2" = "$3" ] && ok "$1" || bad "$1: ждали «$3», получили «$2»"; }

NOW=$(date +%s)
OLD=$(( NOW - 40 * 86400 ))

echo "── слияние истории"
: > "$IPS_FILE"
printf 'alice\t1.1.1.1\nalice\t1.1.1.1\nbob\t2.2.2.2\n' | _ips_merge "$IPS_FILE" "$NOW"
check "две записи на двух юзеров" "$(wc -l < "$IPS_FILE")" "2"
check "повтор увеличил счётчик" "$(grep '^alice|' "$IPS_FILE" | cut -d'|' -f5)" "2"

printf 'alice\t1.1.1.1\n' | _ips_merge "$IPS_FILE" "$(( NOW + 60 ))"
check "first_seen сохранён" "$(grep '^alice|' "$IPS_FILE" | cut -d'|' -f3)" "$NOW"
check "last_seen обновлён" "$(grep '^alice|' "$IPS_FILE" | cut -d'|' -f4)" "$(( NOW + 60 ))"
check "счётчик дошёл до 3" "$(grep '^alice|' "$IPS_FILE" | cut -d'|' -f5)" "3"

echo "── чистка протухших"
printf 'old|9.9.9.9|%s|%s|5\nfresh|8.8.8.8|%s|%s|1\n' "$OLD" "$OLD" "$NOW" "$NOW" > "$IPS_FILE"
printf '' | _ips_merge "$IPS_FILE" "$NOW"
grep -q '^old|' "$IPS_FILE" && bad "запись старше 30 дней должна уйти" || ok "запись 40-дневной давности выброшена"
grep -q '^fresh|' "$IPS_FILE" && ok "свежая запись на месте" || bad "свежую запись потеряли"

echo "── разбор журнала Hysteria"
journalctl() {
    cat <<'EOF'
{"level":"info","msg":"client connected","addr":"203.0.113.7:51820","id":"alice"}
{"level":"info","msg":"client connected", "remote" : "198.51.100.3:1234" , "username" : "bob" }
{"level":"info","msg":"client connected","addr":"127.0.0.1:9999","id":"local"}
{"level":"info","msg":"client disconnected","addr":"203.0.113.9:1","id":"carol"}
{"level":"info","msg":"client connected","addr":"203.0.113.7:40000","id":"alice"}
EOF
}
: > "$IPS_FILE"; : > "$LAST_LOG_TS"
collect_ips
check "собрали две пары (127.0.0.1 и disconnect мимо)" "$(wc -l < "$IPS_FILE")" "2"
check "alice → её адрес" "$(grep -c '^alice|203.0.113.7|' "$IPS_FILE")" "1"
check "два коннекта alice слились в count=2" "$(grep '^alice|' "$IPS_FILE" | cut -d'|' -f5)" "2"
check "bob разобран при пробелах вокруг «:»" "$(grep -c '^bob|198.51.100.3|' "$IPS_FILE")" "1"

echo "── разбор access-лога Caddy (токены подписки)"
if command -v jq >/dev/null 2>&1; then
    journalctl() {
        cat <<'EOF'
{"request":{"remote_ip":"203.0.113.20","uri":"/sub/abc123"}}
{"request":{"remote_addr":"198.51.100.5:44100","uri":"/sub/abc123?v=2"}}
{"request":{"remote_ip":"127.0.0.1","uri":"/sub/abc123"}}
{"request":{"remote_ip":"203.0.113.21","uri":"/sub/bad token"}}
EOF
    }
    : > "$SUBIPS_FILE"; : > "$SUBLOG_TS"
    collect_sub_ips
    check "два IP по токену abc123" "$(grep -c '^abc123|' "$SUBIPS_FILE")" "2"
    check "?query отрезан от токена" "$(grep -c '^abc123|198.51.100.5|' "$SUBIPS_FILE")" "1"
    check "локалхост и мусорный токен мимо" "$(wc -l < "$SUBIPS_FILE")" "2"
else
    echo "  ⏭  jq не установлен — пропуск"
fi

echo ""
[ "$FAIL" = 0 ] && echo "✅ Все проверки пройдены" || echo "❌ Есть ошибки"
exit "$FAIL"
