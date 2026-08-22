#!/bin/bash
# Напоминания об истечении (lib/notify.sh → bot_notify_sweep): один порог = одно
# сообщение (дедуп), параллельный проход не задваивает (flock), и уведомление
# уходит РОВНО в один чат — в директ канала только когда личка не приняла.
# Запуск: bash tests/test-notify.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export HY2M_DATA_DIR=$(mktemp -d)
export HY2M_WEBROOT="$HY2M_DATA_DIR/web"
mkdir -p "$HY2M_WEBROOT/cluster" "$HY2M_DATA_DIR/peers"
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT

source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/expiry.sh"
source "$SCRIPT_DIR/lib/notify.sh"

fail() { echo "❌ $1"; exit 1; }

# Заглушки Telegram: считаем реальные отправки в личку. Как и bot_enabled, они
# живут в lib/tgbot.sh, который тут не сорсится, — включая проверку модуля
# notify (см. docs/design/SALES/README.md); здесь модуль всегда включён.
SENDS=0; CHAN=0; DM_OK=0; LAST_TEXT=''
bot_mod_on()    { return 0; }
bot_enabled()   { return 0; }
bot_token()     { printf 'TESTTOKEN'; }
tg_send()       { SENDS=$((SENDS+1)); LAST_TEXT="$2"; return "$DM_OK"; }
chandm_send()   { CHAN=$((CHAN+1)); }
tg_user_chats() { printf '555\n'; }
bot_username()  { printf 'testbot'; }
bot_get()       { :; }                 # мини-апп в тесте не настроен
bot_sales_on()  { return 1; }

# Юзер со сроком «сегодня»: порог 1д гарантированно пройден при периоде > 2 дней,
# независимо от времени суток (end_ts = сегодня 23:59:59 < now+24ч).
printf 'u1|%s\n' "$(date +%Y-%m-%d)" > "$EXPIRY_FILE"
period_days_set u1 30

# --- дедуп: два прохода подряд шлют ровно одно сообщение ---
SENDS=0
bot_notify_sweep
[ "$SENDS" -eq 1 ] || fail "первый проход должен слать 1 раз, а слал $SENDS"
bot_notify_sweep
[ "$SENDS" -eq 1 ] || fail "второй проход не должен слать повторно (дедуп), стало $SENDS"

# --- flock: пока проход «идёт» (лок держим извне), параллельный молча выходит ---
: > "$NOTIFY_STATE_FILE"                # сбросим метки — без лока проход бы отправил
SENDS=0
exec 9>"$HY2M_DATA_DIR/.notify_sweep.lock"
flock -n 9 || fail "не смогли взять лок в тесте"
bot_notify_sweep
[ "$SENDS" -eq 0 ] || fail "при занятом локе проход обязан пропуститься, а слал $SENDS"
flock -u 9; exec 9>&-

# --- лок свободен: тот же проход теперь отправляет ---
SENDS=0
bot_notify_sweep
[ "$SENDS" -eq 1 ] || fail "со свободным локом должен слать 1 раз, а слал $SENDS"

# --- один канал: личка приняла → в директ канала не дублируем ---
: > "$NOTIFY_STATE_FILE"
SENDS=0; CHAN=0
bot_notify_sweep
[ "$SENDS" -eq 1 ] && [ "$CHAN" -eq 0 ] || fail "личка приняла — канал не нужен (личка=$SENDS, канал=$CHAN)"

# --- личка не приняла (нет диалога с ботом) → уходит в директ канала ---
: > "$NOTIFY_STATE_FILE"
SENDS=0; CHAN=0; DM_OK=1
bot_notify_sweep
[ "$CHAN" -eq 1 ] || fail "личка отказала — обязан быть один заход в канал, было $CHAN"
DM_OK=0

# --- остаток словами порога, без «23ч 59м» ---
[[ "$LAST_TEXT" == *"24 часа"* ]] || fail "остаток должен писаться как «24 часа», а текст: $LAST_TEXT"

# --- округление вверх: ровно сутки до конца дня истечения — это «1д», а не
# «23ч 59м» (срок кончается в 23:59:59, и секунды всегда съедали минуту) ---
end=$(command date -d "$(command date +%F) 23:59:59" +%s)
date() { [ "$1" = "+%s" ] && printf '%s' "$(( end - 86399 ))" || command date "$@"; }
rem=$(format_remaining "$(command date +%F)")
unset -f date
[ "$rem" = "1д" ] || fail "за сутки до конца должно быть «1д», а получено «$rem»"

echo "✅ test-notify: дедуп, flock, один канал доставки и округление остатка"
