#!/bin/bash
# Уведомление, которому некому уйти (lib/notify.sh, notify_user).
#
# Юзер без привязки к Telegram раньше был неотличим от успешной отправки:
# notify_user молча выходил, и человек месяцами не получал ничего. Проверяем,
# что след остаётся, но не заваливает лог: sweep ходит каждые ~5 минут.
# Запуск: bash tests/test-notify-undelivered.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export HY2M_DATA_DIR=$(mktemp -d)
export LOG_DIR="$HY2M_DATA_DIR/log"
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT

source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/tgbot.sh"

FAIL=0
ok()    { echo "  ✅ $1"; }
bad()   { echo "  ❌ $1"; FAIL=1; }
check() { [ "$2" = "$3" ] && ok "$1" || bad "$1: ждали «$3», получили «$2»"; }

source "$SCRIPT_DIR/lib/notify.sh"

bot_enabled() { return 0; }
bot_mod_on()  { return 0; }
bot_token()   { echo stub; }
# Отправку не выполняем: важен сам факт, что доставлять было некуда.
tg_send()     { return 0; }
CHATS=""
tg_user_chats() { [ -n "$CHATS" ] && echo "$CHATS"; }

lines() { grep -c 'некому доставить' "$BOT_LOG" 2>/dev/null || echo 0; }

echo "── привязки нет: след в логе"
notify_user nobody "текст"
check "одна строка" "$(lines)" "1"
grep -q 'nobody' "$BOT_LOG" && ok "в строке указан юзер" || bad "юзер не указан"

echo "── повторный прогон в пределах суток молчит"
notify_user nobody "текст"
notify_user nobody "текст"
check "строк по-прежнему одна" "$(lines)" "1"

echo "── сутки прошли — жалуемся снова"
sed -i "s/^nobody|.*/nobody|$(( $(date +%s) - 90000 ))/" "$NOTIFY_UNDELIV_FILE"
notify_user nobody "текст"
check "строк стало две" "$(lines)" "2"

echo "── привязка есть: в лог не пишем"
CHATS=12345
notify_user somebody "текст"
grep -q 'somebody' "$BOT_LOG" && bad "пожаловались на доставленное" \
                              || ok "тишина"

[ "$FAIL" = 0 ] && echo "✅ test-notify-undelivered: ok" || echo "❌ test-notify-undelivered: есть ошибки"
exit "$FAIL"
