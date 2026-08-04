#!/bin/bash
# Правка каталога снаружи (webapi/dispatch.sh: tariff-set/del/move, pricing-set).
# Проверяем то, ради чего ручки заводились: upsert НЕ теряет позицию тарифа в
# витрине, опции снимаются явно, а «|» в названии не расщепляет строку файла.
# См. docs/guide/API.md и docs/design/SALES/README.md.
# Запуск: bash tests/test-tariff-api.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export HY2M_DATA_DIR=$(mktemp -d)
export HY2M_WEBROOT="$HY2M_DATA_DIR/web"
mkdir -p "$HY2M_WEBROOT/cluster" "$HY2M_DATA_DIR/peers"
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT

D="$SCRIPT_DIR/webapi/dispatch.sh"
CONF="$HY2M_DATA_DIR/tariffs.conf"
fail() { echo "❌ $1"; exit 1; }
run() { bash "$D" "$@" 2>&1; }

printf '%s\n' 'a1|Первый|1|1|10|XTR' 'b2|Второй|7|1|50|XTR' 'c3|Третий|30|2|100|XTR' > "$CONF"

# --- upsert существующего: позиция сохраняется ---
run tariff-set b2 "Второй, дешевле" 7 3 "40/60" "XTR/RUB" "" >/dev/null || fail "tariff-set упал"
[ "$(sed -n 2p "$CONF")" = "b2|Второй, дешевле|7|3|40/60|XTR/RUB" ] \
    || fail "правка уехала со своей позиции: $(sed -n 2p "$CONF")"
[ "$(grep -c '^' "$CONF")" = 3 ] || fail "upsert размножил тариф"

# --- новый дописывается в конец ---
run tariff-set d4 "Четвёртый" 90 1 "300" "RUB" "" >/dev/null || fail "новый тариф не создался"
[ "$(sed -n 4p "$CONF")" = "d4|Четвёртый|90|1|300|RUB" ] || fail "новый тариф не в конце"

# --- опции: ставятся и снимаются явно (пустая строка = «опций нет») ---
run tariff-set a1 "Первый" 1 1 "10" "XTR" "free=1;wk=3G" >/dev/null || fail "опции не записались"
[ "$(sed -n 1p "$CONF")" = "a1|Первый|1|1|10|XTR|free=1;wk=3G" ] || fail "строка с опциями неверна: $(sed -n 1p "$CONF")"
run tariff-set a1 "Первый" 1 1 "10" "XTR" "" >/dev/null || fail "повторный tariff-set упал"
[ "$(sed -n 1p "$CONF")" = "a1|Первый|1|1|10|XTR" ] || fail "пустые опции не сняли старые: $(sed -n 1p "$CONF")"

# --- порядок витрины ---
run tariff-move d4 up >/dev/null || fail "move up упал"
[ "$(sed -n 3p "$CONF" | cut -d'|' -f1)" = "d4" ] || fail "тариф не поднялся"
run tariff-move d4 1 >/dev/null || fail "move на позицию упал"
[ "$(sed -n 1p "$CONF" | cut -d'|' -f1)" = "d4" ] || fail "тариф не встал первым"
run tariff-move d4 up >/dev/null 2>&1 && fail "подъём с краю должен быть ошибкой"

# --- удаление ---
run tariff-del d4 >/dev/null || fail "tariff-del упал"
grep -q '^d4|' "$CONF" && fail "тариф остался в файле"
out=$(run tariff-del d4); rc=$?
[ "$rc" = 2 ] || fail "удаление несуществующего должно давать rc 2 (404), а дало $rc"
echo "$out" | grep -q 'error=tariff_not_found' || fail "нет кода ошибки tariff_not_found: $out"

# --- защита формата файла: «|» и перевод строки в названии ---
run tariff-set e5 "Плохой|тариф" 30 1 "10" "XTR" "" >/dev/null 2>&1 && fail "название с «|» принято"
run tariff-set e5 "$(printf 'две\nстроки')" 30 1 "10" "XTR" "" >/dev/null 2>&1 && fail "название с переводом строки принято"
run tariff-set e5 "Ок" 30 1 "10;rm" "XTR" "" >/dev/null 2>&1 && fail "мусорная цена принята"
run tariff-set e5 "Ок" 30 1 "10" "xtr" "" >/dev/null 2>&1 && fail "валюта в нижнем регистре принята"
[ "$(grep -c '^' "$CONF")" = 3 ] || fail "отклонённые тарифы всё-таки попали в файл"

# --- режим звёздной цены ---
run pricing-set rate 1.5 >/dev/null || fail "pricing-set упал"
grep -qx 'STARS_MODE=rate' "$HY2M_DATA_DIR/bot.conf" || fail "режим не записан в bot.conf"
grep -qx 'STARS_RUB_PER_STAR=1.5' "$HY2M_DATA_DIR/bot.conf" || fail "курс не записан"
run pricing-set rate 0 >/dev/null 2>&1 && fail "нулевой курс принят"
run pricing-set чепуха 1.5 >/dev/null 2>&1 && fail "неизвестный режим принят"
grep -qx 'STARS_MODE=rate' "$HY2M_DATA_DIR/bot.conf" || fail "отклонённая правка испортила конфиг"

echo "✅ tariff-api: upsert держит позицию, опции снимаются, формат файла защищён, режим цены пишется"
