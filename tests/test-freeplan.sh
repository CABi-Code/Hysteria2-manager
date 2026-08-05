#!/bin/bash
# Бесплатный тариф (lib/freeplan.sh): старт окон по первому онлайну, отключение
# по исчерпанию лимита, впуск обратно после прокрутки окна, пороги уведомлений.
# Запуск: bash tests/test-freeplan.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export HY2M_DATA_DIR=$(mktemp -d)
export HY2M_WEBROOT="$HY2M_DATA_DIR/web"
mkdir -p "$HY2M_WEBROOT/cluster" "$HY2M_DATA_DIR/peers"
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT

source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/expiry.sh"      # настоящий expiry_days_left: принимает ДАТУ
source "$SCRIPT_DIR/lib/freeplan.sh"

# Тариф-конструктор: бесплатный, 5 ГБ в неделю, 15 ГБ в месяц, старт по онлайну.
printf 'm1|30 дней|30|1|299/240|XTR/RUB\nfree|Бесплатный|0|1|0/0|XTR/RUB|free=1;wk=5G;mo=15G;start=online\n' \
    > "$HY2M_DATA_DIR/tariffs.conf"
TARIFFS_CONF="$HY2M_DATA_DIR/tariffs.conf"
tariff_list() { grep -vE '^\s*(#|$)' "$TARIFFS_CONF"; }
tariff_get()  { tariff_list | awk -F'|' -v c="$1" '$1==c{print; exit}'; }

# Заглушки окружения: трафик, онлайн, состояние юзера.
BYTES=0; ONLINE=0; DISABLED=0; EXPIRY=$(date -d '5 days ago' +%Y-%m-%d)
NOTIFY=""
freeplan_user_bytes() { printf '%s' "$BYTES"; }
get_user_active()     { printf '%s' "$ONLINE"; }
# Заглушка ровно та, что в проде: срок хранится ДАТОЙ, дни считает expiry.sh.
get_user_expiry()     { printf '%s' "$EXPIRY"; }
is_user_disabled()    { [ "$DISABLED" = 1 ]; }
disable_user()        { DISABLED=1; }
enable_user()         { DISABLED=0; }
sub_enabled()         { return 1; }   # без кластера — публикация не нужна
bot_notify_free_low()     { NOTIFY+="low "; }
bot_notify_free_blocked() { NOTIFY+="blocked "; BLOCK_RESET="$2"; }
bot_notify_free_reset()   { NOTIFY+="reset "; }
bot_notify_free_entered() { NOTIFY+="entered "; }

fail() { echo "❌ $1"; exit 1; }
GB=$((1024*1024*1024)); MB=$((1024*1024))

# --- конструктор тарифа ---
[ "$(free_tariff_code)" = "free" ] || fail "не нашли бесплатный тариф"
[ "$(free_wk_limit)" = "$((5*GB))" ] || fail "недельный лимит: $(free_wk_limit)"
[ "$(free_mo_limit)" = "$((15*GB))" ] || fail "месячный лимит: $(free_mo_limit)"
[ "$(tariff_opt free start)" = "online" ] || fail "опция start не прочиталась"
[ -z "$(tariff_opt m1 wk)" ] || fail "у обычного тарифа не должно быть лимитов"

# --- перевод на free: окна ещё не идут ---
freeplan_enter user1
[ "$(freeplan_field user1 2)" = "pending" ] || fail "ожидали pending"
BYTES=$((3*GB))            # трафик, накопленный ДО перехода, в расход не идёт
freeplan_tick
[ "$(freeplan_field user1 2)" = "pending" ] || fail "офлайн — окна стартовать не должны"

# --- первый выход в онлайн запускает окна, база = текущий трафик ---
ONLINE=1
freeplan_tick
[ "$(freeplan_field user1 2)" = "active" ] || fail "онлайн не запустил окна"
[ "$(freeplan_field user1 5)" = "$((3*GB))" ] || fail "база недели: $(freeplan_field user1 5)"

# --- пороги уведомлений: 1 ГБ → 500 МБ → 50 МБ, по одному разу ---
BYTES=$((3*GB + 4*GB + 512*MB))        # осталось ~512 МБ до недельных 5 ГБ
freeplan_tick
[ "$NOTIFY" = "entered low " ] || fail "ожидали одно 'low', получили: '$NOTIFY'"
freeplan_tick
[ "$NOTIFY" = "entered low " ] || fail "порог послан повторно: '$NOTIFY'"
BYTES=$((3*GB + 5*GB - 300*MB))        # осталось 300 МБ — порог 500 МБ
freeplan_tick
[ "$NOTIFY" = "entered low low " ] || fail "порог 500 МБ: '$NOTIFY'"
BYTES=$((3*GB + 5*GB - 10*MB))         # осталось 10 МБ — порог 50 МБ
freeplan_tick
[ "$NOTIFY" = "entered low low low " ] || fail "порог 50 МБ: '$NOTIFY'"

# --- исчерпание недельного лимита отключает ---
BYTES=$((3*GB + 5*GB))
freeplan_tick
[ "$DISABLED" = 1 ] || fail "лимит выбран, а юзер не отключён"
[ "$(freeplan_field user1 2)" = "blocked" ] || fail "состояние не blocked"
[[ "$NOTIFY" == *blocked* ]] || fail "не уведомили об исчерпании"

# --- прокрутка недельного окна впускает обратно с новой базой ---
old_start=$(freeplan_field user1 4)
freeplan_set user1 blocked "$(freeplan_field user1 3)" "$(( old_start - FREE_WEEK_SEC - 60 ))" \
    "$(freeplan_field user1 5)" "$(freeplan_field user1 6)" "$(freeplan_field user1 7)" 4
freeplan_tick
[ "$DISABLED" = 0 ] || fail "окно прокрутилось, а юзер всё ещё отключён"
[ "$(freeplan_field user1 2)" = "active" ] || fail "после сброса ожидали active"
[ "$(freeplan_field user1 5)" = "$BYTES" ] || fail "база не обновилась на новом окне"

# --- месячный потолок держит, даже когда недельный сброшен ---
BYTES=$((3*GB + 15*GB))
freeplan_tick
[ "$DISABLED" = 1 ] || fail "месячный лимит не сработал"
# Обещанное время возврата — сброс месячного окна (позднее недельного), а не
# недельного: раньше блокировка по месячной квоте обещала доступ через неделю.
[ "$BLOCK_RESET" = "$(( $(freeplan_field user1 6) + FREE_MONTH_SEC ))" ] \
    || fail "время сброса не месячное: $BLOCK_RESET"

# --- оплатил снова → бесплатный тариф снимается ---
EXPIRY=$(date -d '+30 days' +%Y-%m-%d)
freeplan_tick
[ -n "$(freeplan_row user1)" ] && fail "строка free не удалена после оплаты"
[ "$DISABLED" = 0 ] || fail "после оплаты юзер должен быть включён"

# --- срок кончился ВЧЕРА: перевод на free держится, а не гоняется туда-сюда ---
# Регрессия: expiry_days_left резала деление к нулю и на вчерашней дате давала
# 0 («ещё действует»), поэтому freeplan_tick снимал юзера с бесплатного, а
# check_expired_users тут же возвращал — с уведомлением на КАЖДЫЙ прогон.
[ "$(expiry_days_left "$(date -d yesterday +%Y-%m-%d)")" = "-1" ] \
    || fail "вчерашний срок: expiry_days_left = $(expiry_days_left "$(date -d yesterday +%Y-%m-%d)"), ждали -1"
[ "$(expiry_days_left "$(date +%Y-%m-%d)")" = "0" ] || fail "сегодняшний срок должен давать 0"
expiry_is_over "$(date -d yesterday +%Y-%m-%d)" || fail "вчерашний срок не считается истёкшим"
expiry_is_over "$(date +%Y-%m-%d)" && fail "сегодняшний срок посчитан истёкшим"

EXPIRY=$(date -d yesterday +%Y-%m-%d); DISABLED=0; NOTIFY=""
freeplan_enter user2
[ -n "$(freeplan_row user2)" ] || fail "не перевели на бесплатный вчерашний срок"
freeplan_tick
[ -n "$(freeplan_row user2)" ] || fail "freeplan_tick снял с бесплатного вчера истёкшего"
freeplan_enter user2
[ "$NOTIFY" = "entered " ] || fail "повторное уведомление о переводе: '$NOTIFY'"

# --- нода БЕЗ бесплатного тарифа не отключает того, кто на бесплатном ---
# Регрессия: тариф free есть только на части нод, а expiry.dat кластерный.
# Нода без free=1 в своём tariffs.conf отключала такого юзера и слала админу
# «⏰ Автоотключение по сроку», а клиенту — «доступ отключён».
EXPIRED_NOTIFY=""
db_user_exists()     { return 0; }
bot_notify_expired() { EXPIRED_NOTIFY+="expired "; }
EXPIRY_FILE="$HY2M_DATA_DIR/expiry.dat"
printf 'user2|%s\n' "$(date -d yesterday +%Y-%m-%d)" > "$EXPIRY_FILE"
TARIFFS_CONF="$HY2M_DATA_DIR/tariffs-nofree.conf"     # тарифов free на этой ноде нет
printf 'm1|30 дней|30|1|299/240|XTR/RUB\n' > "$TARIFFS_CONF"
free_enabled && fail "на ноде без free=1 бесплатный тариф не должен быть включён"
DISABLED=0
check_expired_users >/dev/null
[ "$DISABLED" = 0 ] || fail "юзера на бесплатном отключили на ноде без free-тарифа"
[ -z "$EXPIRED_NOTIFY" ] || fail "прислали «автоотключение» юзеру на бесплатном"

echo "✅ freeplan: окна, лимиты и пороги ок"
