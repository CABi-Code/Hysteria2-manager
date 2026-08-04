#!/bin/bash
# P-XX (100% CPU на ноде): чтение конфигов и urlencode переписаны без форков.
# Тест сторожит РЕЗУЛЬТАТ (значения обязаны совпадать со старой реализацией на
# grep|head|cut и $(printf) посимвольно) и САМ ФАКТ отсутствия форков.
# Запуск: bash tests/test-forkdiet.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export HY2M_DATA_DIR=$(mktemp -d)
export HY2M_WEBROOT="$HY2M_DATA_DIR/web"
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT

source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/node.sh"
source "$SCRIPT_DIR/lib/protocols.sh"

fail() { echo "❌ $1"; exit 1; }

# --- node_get/proto_get: те же значения, что у grep|head|cut ---------------
old_get() { [ -f "$2" ] && grep "^${1}=" "$2" 2>/dev/null | head -1 | cut -d= -f2-; }

cat > "$NODE_CONF" <<'EOF'
NODE_NAME=fin2
SUB_TAG_TMPL={label} | {protocol} | онлайн {online}
NODE_LABEL=🇫🇮 Фин-2
EMPTY=
WITH_EQ=a=b=c
NODE_NAME=второй-дубль
EOF
printf 'NO_TRAILING_NEWLINE=yes' >> "$NODE_CONF"

for k in NODE_NAME SUB_TAG_TMPL NODE_LABEL EMPTY WITH_EQ NO_TRAILING_NEWLINE MISSING; do
    [ "$(node_get "$k")" = "$(old_get "$k" "$NODE_CONF")" ] \
        || fail "node_get $k разошёлся со старой реализацией"
done
# Дубль ключа: берём ПЕРВЫЙ, как делал head -1.
[ "$(node_get NODE_NAME)" = "fin2" ] || fail "node_get взял не первое значение дубля"

printf 'PROTO_VLESS_ENABLED=1\nPROTO_SS_METHOD=2022-blake3-aes-128-gcm\n' > "$PROTO_CONF"
for k in PROTO_VLESS_ENABLED PROTO_SS_METHOD MISSING; do
    [ "$(proto_get "$k")" = "$(old_get "$k" "$PROTO_CONF")" ] \
        || fail "proto_get $k разошёлся со старой реализацией"
done

# --- row_by_key/fld_by_key: то же, что grep "^ключ|" | head -1 (+ cut) -----
old_row() { grep "^${2}|" "$1" 2>/dev/null | head -1; }
old_fld() { grep "^${2}|" "$1" 2>/dev/null | head -1 | cut -d'|' -f"$3"; }
rows="$HY2M_DATA_DIR/rows.dat"
cat > "$rows" <<'EOF'
alice|2|1|50
bob|0|0|
alice|9|9|9
короткая
EOF
printf 'zeta|7|1|10' >> "$rows"          # последняя строка без перевода
for k in alice bob zeta нет короткая; do
    [ "$(row_by_key "$rows" "$k")" = "$(old_row "$rows" "$k")" ] || fail "row_by_key $k разошёлся"
    for n in 1 2 3 4 9; do
        [ "$(fld_by_key "$rows" "$k" "$n")" = "$(old_fld "$rows" "$k" "$n")" ] \
            || fail "fld_by_key $k поле $n разошлось"
    done
done
[ "$(row_by_key "$rows" alice)" = "alice|2|1|50" ] || fail "row_by_key взял не первую строку дубля"
[ "$(row_by_key "$HY2M_DATA_DIR/нет-файла" alice)" = "" ] || fail "row_by_key на несуществующем файле"

# --- _proto_urlenc: байт в байт как посимвольный $(printf) -----------------
old_urlenc() {
    local s="$1" out="" c i
    local LC_ALL=C LC_CTYPE=C
    for (( i=0; i<${#s}; i++ )); do
        c="${s:$i:1}"
        case "$c" in [a-zA-Z0-9._~-]) out+="$c" ;; *) out+=$(printf '%%%02X' "'$c") ;; esac
    done
    printf '%s' "$out"
}
while IFS= read -r t; do
    [ "$(_proto_urlenc "$t")" = "$(old_urlenc "$t")" ] || fail "_proto_urlenc разошёлся на [$t]"
done <<'EOF'
🇫🇮 Фин-2 | HY2 | онлайн 3
a b&c#d/e?x=1
Ω=+%
plain-ascii_only.~
EOF

# --- форков быть не должно -------------------------------------------------
# Дельта «processes» из /proc/stat: 200 вызовов каждой функции обязаны уложиться
# в бюджет, недостижимый для реализации с пайпом (там было бы >600 форков).
forks() { local p; while IFS= read -r p; do case "$p" in processes*) echo "${p#processes }"; return ;; esac; done < /proc/stat; }
a=$(forks)
for _ in $(seq 200); do node_get NODE_LABEL >/dev/null; proto_get PROTO_SS_METHOD >/dev/null; done
_proto_urlenc "🇫🇮 Фин-2 | HY2 | онлайн 3" >/dev/null
b=$(forks)
# 400 вызовов в $( ) — это 400 подоболочек, они форки. Сторожим ВНУТРЕННИЕ:
# бюджет 450 ловит и pipe в геттерах (было бы +1200), и посимвольный printf.
[ $((b-a)) -lt 450 ] || fail "форков $((b-a)) на 400 чтений — реализация опять форкает"

echo "✅ node_get/proto_get/_proto_urlenc: значения прежние, форков нет ($((b-a)) на 400 чтений)"
