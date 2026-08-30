#!/bin/bash
# Блокировка TUIC при превышении лимита (lib/protocols.sh).
#
# Закрыть потоки через clash API мало: креды остаются валидными, клиент
# открывает новые сразу же. Поэтому адрес нарушителя дропается на порту TUIC.
# Настоящий nft здесь не зовём — подменяем заглушкой и проверяем, ЧТО именно
# ему сказали бы: правила файрвола на боевой ноде тест трогать не должен.
# Запуск: bash tests/test-tuic-block.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export HY2M_DATA_DIR=$(mktemp -d)
NFT_LOG="$HY2M_DATA_DIR/nft.log"
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT

source "$SCRIPT_DIR/lib/config.sh"

FAIL=0
ok()    { echo "  ✅ $1"; }
bad()   { echo "  ❌ $1"; FAIL=1; }
check() { [ "$2" = "$3" ] && ok "$1" || bad "$1: ждали «$3», получили «$2»"; }

source "$SCRIPT_DIR/lib/protocols.sh"

# Заглушка nft: пишет вызовы в лог, «показывает» ту таблицу, что ей задали.
TABLE_SHOWS=""
nft() {
    printf '%s\n' "$*" >> "$NFT_LOG"
    case "$1 ${2:-}" in
        "list table") printf '%s\n' "$TABLE_SHOWS"; [ -n "$TABLE_SHOWS" ] ;;
        "-f -")       cat > "$HY2M_DATA_DIR/table.nft" ;;
        *)            return 0 ;;
    esac
}
command() { [ "${2:-}" = "nft" ] && return 0; builtin command "$@"; }
proto_tuic_port() { echo 2053; }

echo "── таблицы нет: создаём под текущий порт"
: > "$NFT_LOG"; TABLE_SHOWS=""
_proto_tuic_block_ensure && ok "успех" || bad "не удалось создать"
grep -q "udp dport 2053 ip saddr @tuic4" "$HY2M_DATA_DIR/table.nft" \
    && ok "правило IPv4 на нужном порту" || bad "нет правила IPv4"
grep -q "udp dport 2053 ip6 saddr @tuic6" "$HY2M_DATA_DIR/table.nft" \
    && ok "правило IPv6 на нужном порту" || bad "нет правила IPv6"
grep -q "flags timeout" "$HY2M_DATA_DIR/table.nft" \
    && ok "сеты с таймаутом — блокировка снимается сама" \
    || bad "сет без таймаута: клиент запрётся навсегда"

echo "── таблица уже под этот порт: не трогаем"
: > "$NFT_LOG"; TABLE_SHOWS="udp dport 2053 ip saddr @tuic4 drop"
_proto_tuic_block_ensure
grep -q '^-f -$' "$NFT_LOG" && bad "таблицу пересобрали зря" || ok "пересборки не было"

echo "── порт сменили: пересобираем"
# Иначе правило осталось бы на старом порту и дропало не то и не тех.
: > "$NFT_LOG"; TABLE_SHOWS="udp dport 9999 ip saddr @tuic4 drop"
_proto_tuic_block_ensure
grep -q '^-f -$' "$NFT_LOG" && ok "таблица пересобрана" || bad "старый порт остался"

echo "── адрес попадает в сет своей версии"
: > "$NFT_LOG"; TUIC_BLOCK_SEC=300
_proto_tuic_block_ip 203.0.113.7
_proto_tuic_block_ip 2001:db8::5
grep -q "add element inet hy2block tuic4 { 203.0.113.7 timeout 300s }" "$NFT_LOG" \
    && ok "IPv4 → tuic4" || bad "IPv4 попал не туда"
grep -q "add element inet hy2block tuic6 { 2001:db8::5 timeout 300s }" "$NFT_LOG" \
    && ok "IPv6 → tuic6" || bad "IPv6 попал не туда"
: > "$NFT_LOG"
_proto_tuic_block_ip "" && bad "пустой адрес приняли" || ok "пустой адрес отвергнут"
check "лишних вызовов нет" "$(wc -l < "$NFT_LOG" | tr -d ' ')" "0"

[ "$FAIL" = 0 ] && echo "✅ test-tuic-block: ok" || echo "❌ test-tuic-block: есть ошибки"
exit "$FAIL"
