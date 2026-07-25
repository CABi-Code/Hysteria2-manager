#!/bin/bash
# Напоминания об истечении (lib/notify.sh → bot_notify_sweep): один порог = одно
# сообщение (дедуп), и параллельный проход не задваивает (flock).
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

# Заглушки Telegram: считаем реальные отправки в личку.
SENDS=0
bot_enabled()   { return 0; }
bot_token()     { printf 'TESTTOKEN'; }
tg_send()       { SENDS=$((SENDS+1)); }
chandm_send()   { :; }                 # канал-DM в этом тесте не проверяем
tg_user_chats() { printf '555\n'; }
bot_username()  { printf 'testbot'; }

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

echo "✅ test-notify: дедуп и flock работают"
