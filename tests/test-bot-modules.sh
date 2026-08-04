#!/bin/bash
# Модули бота (BOT_MODULES в bot.conf, lib/tgbot.sh): выключенный модуль убирает
# свою часть бота и НЕ трогает остальные — продажу можно погасить, сохранив
# уведомления. Отсутствие ключа = включено всё (старые конфиги).
# См. docs/design/SALES/README.md.
# Запуск: bash tests/test-bot-modules.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export HY2M_DATA_DIR=$(mktemp -d)
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT

LOG_DIR="$HY2M_DATA_DIR"; LOG_FILE="$LOG_DIR/error.log"   # их ждёт tgbot.sh при сорсинге

source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/tgbot.sh"
source "$SCRIPT_DIR/lib/tariffs.sh"

TARIFFS_CONF="$HY2M_DATA_DIR/tariffs.conf"
printf '%s\n' 'm1|30 дней|30|1|299/240|XTR/RUB' > "$TARIFFS_CONF"
fail() { echo "❌ $1"; exit 1; }

# --- дефолт: ключа нет → включено всё ---
bot_mod_on sales  || fail "без BOT_MODULES продажа выключена (сломана установка из коробки)"
bot_mod_on notify || fail "без BOT_MODULES уведомления выключены"
bot_mod_on admin  || fail "без BOT_MODULES админ выключен"
bot_sales_on      || fail "тариф есть, модуль есть — бот должен продавать"

# --- выключаем только продажу ---
bot_set BOT_MODULES "notify,admin"
bot_mod_on sales  && fail "sales остался включён"
bot_sales_on      && fail "bot_sales_on не смотрит на модуль"
bot_mod_on notify || fail "выключение sales погасило уведомления"
bot_mod_on admin  || fail "выключение sales погасило админа"

# Клавиатура клиента теряет кнопку покупки и только её.
source "$SCRIPT_DIR/lib/tgbot_client.sh"
kb=$(bot_kb_client)
[[ "$kb" == *'m:buy'* ]] && fail "кнопка покупки осталась при выключенном sales"
[[ "$kb" == *'m:link'* && "$kb" == *'m:sub'* && "$kb" == *'m:status'* ]] \
    || fail "вместе с покупкой пропали остальные кнопки"
echo "$kb" | jq -e . >/dev/null 2>&1 || fail "клавиатура без кнопки покупки — невалидный JSON"

bot_set BOT_MODULES "sales,notify,admin"
[[ "$(bot_kb_client)" == *'m:buy'* ]] || fail "кнопка покупки не вернулась"

# --- продавать нечем: модуль включён, тарифов нет ---
: > "$TARIFFS_CONF"
bot_sales_on && fail "бот собрался продавать пустой каталог"
printf '%s\n' 'm1|30 дней|30|1|299|XTR' > "$TARIFFS_CONF"

# --- админ: выключенный модуль снимает права у всех, включая ADMIN_IDS ---
bot_set ADMIN_IDS "777"
bot_is_admin 777 || fail "админ не опознан при включённом модуле"
bot_set BOT_MODULES "sales,notify"
bot_is_admin 777 && fail "при выключенном admin остались админские права"

# --- «выключено всё» отличается от «ключа нет» ---
bot_set BOT_MODULES "none"
bot_mod_on sales  && fail "none не выключил sales"
bot_mod_on notify && fail "none не выключил notify"
bot_mod_on admin  && fail "none не выключил admin"

# Пробелы в значении не должны ломать разбор.
bot_set BOT_MODULES "sales, notify"
bot_mod_on notify || fail "пробел после запятой сломал разбор списка"

echo "✅ модули бота: дефолт, выборочное выключение, none и разбор списка"
