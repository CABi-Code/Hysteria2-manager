#!/bin/bash
# Режимы звёздной цены (bot.conf STARS_MODE, lib/tariffs.sh): fixed берёт XTR из
# тарифа, rate считает её из рублёвой с округлением ВВЕРХ. Бот и Web API должны
# считать ОДИНАКОВО — иначе клиент увидит одну цену, а заплатит другую.
# См. docs/design/SALES/README.md.
# Запуск: bash tests/test-stars-price.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export HY2M_DATA_DIR=$(mktemp -d)
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT

LOG_DIR="$HY2M_DATA_DIR"; LOG_FILE="$LOG_DIR/error.log"

source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/tgbot.sh"
source "$SCRIPT_DIR/lib/tariffs.sh"

TARIFFS_CONF="$HY2M_DATA_DIR/tariffs.conf"
printf '%s\n' 'm1|30 дней|30|1|299/240|XTR/RUB' 'r1|Только рубли|30|1|240|RUB' > "$TARIFFS_CONF"
fail() { echo "❌ $1"; exit 1; }

eff() { tariff_prices_effective "$1" "$2"; }

# --- fixed (по умолчанию): цены как в файле ---
[ "$(stars_mode)" = fixed ] || fail "без ключа режим должен быть fixed"
[ "$(eff '299/240' 'XTR/RUB')" = "299/240 XTR/RUB" ] || fail "fixed изменил цены"
[ "$(eff '240' 'RUB')" = "240 RUB" ] || fail "fixed приписал звёздную цену"
[ "$(tariff_currencies_of m1)" = "XTR RUB" ] || fail "fixed: неверный список валют"

# --- rate: XTR = ceil(RUB / курс) ---
bot_set STARS_MODE rate
bot_set STARS_RUB_PER_STAR 1.5
[ "$(stars_mode)" = rate ] || fail "режим rate не включился"
# 240 / 1.5 = 160 ровно
[ "$(eff '299/240' 'XTR/RUB')" = "160/240 XTR/RUB" ] || fail "звёздная цена не пересчиталась: $(eff '299/240' 'XTR/RUB')"
# У тарифа без колонки XTR она появляется
[ "$(eff '240' 'RUB')" = "240/160 RUB/XTR" ] || fail "XTR не добавилась: $(eff '240' 'RUB')"
[ "$(tariff_currencies_of r1)" = "RUB XTR" ] || fail "rate: XTR не попала в список валют"

# Округление вверх: 100/1.5 = 66.67 → 67 (недобор = продажа дешевле цены).
[ "$(eff '100' 'RUB')" = "100/67 RUB/XTR" ] || fail "нет округления вверх: $(eff '100' 'RUB')"

# Рублёвой цены нет — считать не из чего, строка не меняется.
[ "$(eff '5' 'XTR')" = "5 XTR" ] || fail "тариф без ₽ подменил звёздную цену"

# Мусорный/нулевой курс не должен делить на ноль.
bot_set STARS_RUB_PER_STAR 0
[ "$(stars_rub_per_star)" = 1 ] || fail "нулевой курс не заменён на 1"
[ "$(eff '240' 'RUB')" = "240/240 RUB/XTR" ] || fail "курс 0 сломал пересчёт: $(eff '240' 'RUB')"
bot_set STARS_RUB_PER_STAR "чепуха"
[ "$(stars_rub_per_star)" = 1 ] || fail "мусорный курс не заменён на 1"

# --- Web API считает то же самое (одна формула на два языка) ---
bot_set STARS_RUB_PER_STAR 1.5
api=$(HY2M_DATA_DIR="$HY2M_DATA_DIR" python3 -c '
import sys, json
sys.path.insert(0, "'"$SCRIPT_DIR"'/webapi")
import wa_core
wa_core.DATA_DIR = "'"$HY2M_DATA_DIR"'"
from wa_dispatch import tariffs, pricing
print(json.dumps({"t": tariffs(), "p": pricing()}, ensure_ascii=False))
') || fail "webapi не смог прочитать тарифы"
echo "$api" | jq -e '.p.stars_mode == "rate" and .p.rub_per_star == 1.5' >/dev/null \
    || fail "API не отдал режим цены: $api"
echo "$api" | jq -e '[.t[] | select(.code=="m1") | .prices[] | select(.currency=="XTR") | .price] == ["160"]' >/dev/null \
    || fail "API отдал звёздную цену не по режиму: $api"
echo "$api" | jq -e '[.t[] | select(.code=="r1") | .prices[] | select(.currency=="XTR") | .price] == ["160"]' >/dev/null \
    || fail "API не добавил звёздную цену тарифу без неё: $api"

echo "✅ звёздная цена: fixed/rate, округление вверх, защита курса, бот и API совпадают"
