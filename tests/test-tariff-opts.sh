#!/bin/bash
# Редактор опций тарифа (7-е поле «k=v;k=v», lib/tariffs.sh): tariff_ask_opts
# собирает строку из ответов, а tariff_update кладёт её на место — включая
# ПУСТУЮ (снятие лимитов) при force_opts.
# Запуск: bash tests/test-tariff-opts.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export HY2M_DATA_DIR=$(mktemp -d)
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT

# ask() из ui.sh: читает ответ в переменную с именем $1. Подменяем на чтение
# stdin, чтобы прогнать диалог без интерактива.
ask() { local __v="$1"; shift; printf '%s' "$*" >/dev/null; read -r "$__v"; }

LOG_DIR="$HY2M_DATA_DIR"; LOG_FILE="$LOG_DIR/error.log"   # их ждёт tgbot.sh при сорсинге

source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/tgbot.sh"
source "$SCRIPT_DIR/lib/tariffs.sh"
source "$SCRIPT_DIR/lib/freeplan.sh"

TARIFFS_CONF="$HY2M_DATA_DIR/tariffs.conf"
fail() { echo "❌ $1"; exit 1; }

# Ответы диалога построчно; «¶» — перевод строки (Enter = оставить как было).
opts_after() {   # answers current_opts -> итоговая строка опций
    printf '%s\n' "${1//¶/$'\n'}" | { tariff_ask_opts "$2" >/dev/null; printf '%s' "$_TOPTS"; }
}

[ "$(opts_after '¶¶' 'free=1;wk=5G;mo=15G;start=online')" = 'free=1;wk=5G;mo=15G;start=online' ] \
    || fail "Enter на всех вопросах изменил строку опций"
[ "$(opts_after 'да¶1G 10G¶online' 'free=1;wk=5G;mo=15G;start=online')" = 'free=1;wk=1G;mo=10G;start=online' ] \
    || fail "новые лимиты не записались"
[ "$(opts_after 'нет¶-' 'free=1;wk=5G;mo=15G;start=online')" = '' ] \
    || fail "«-» не снял лимиты"
[ "$(opts_after '¶' '')" = '' ] \
    || fail "обычному тарифу приписались опции"
# Ключи будущих версий редактор не знает, но и не выбрасывает.
[ "$(opts_after '¶¶' 'wk=5G;start=paid;xx=7')" = 'wk=5G;start=paid;xx=7' ] \
    || fail "неизвестный ключ потерялся"
# Мусор отвергаем, а не пишем в файл.
printf '%s\n' 'нет' '5Гб' | tariff_ask_opts '' >/dev/null 2>&1 && fail "принят лимит «5Гб»"

# --- строка тарифа: правка не должна ломать 7-е поле ---
tariff_add free "Бесплатный" 0 1 "0/0" "XTR/RUB" "free=1;wk=5G;mo=15G;start=online"
tariff_update free free "Бесплатный" 0 2 "0/0" "XTR/RUB" "free=1;wk=1G;mo=10G;start=online"
[ "$(tariff_opt free wk)" = "1G" ] || fail "лимит недели не обновился: $(tariff_get free)"
[ "$(tariff_get free | cut -d'|' -f4)" = "2" ] || fail "устройства не обновились"

# Без опций и без force_opts старые сохраняются…
tariff_update free free "Бесплатный" 0 2 "0/0" "XTR/RUB"
[ "$(tariff_opt free free)" = "1" ] || fail "правка без опций сняла free=1"
# …а с force_opts пустая строка реально снимает их.
tariff_update free free "Бесплатный" 0 2 "0/0" "XTR/RUB" "" force_opts
[ -z "$(tariff_opts free)" ] || fail "force_opts не снял опции: $(tariff_get free)"

# Валюта не должна утаскивать 7-е поле (баг «Валюта RUB|FREE=1;… — 3 буквы»).
tariff_add m1 "Месяц" 30 1 "240" "RUB" "wk=50G"
IFS='|' read -r _ _ _ _ _ cur _opts <<< "$(tariff_get m1)"
[ "$cur" = "RUB" ] || fail "в валюту попало лишнее: «$cur»"
[ "$_opts" = "wk=50G" ] || fail "опции прочитались неверно: «$_opts»"

echo "tariff opts: ok"
