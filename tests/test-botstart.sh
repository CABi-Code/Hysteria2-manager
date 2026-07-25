#!/bin/bash
# /start → мини-апп (lib/tgbot_client.sh, bot_miniapp_start): что уходит в
# запросе и когда менеджер обязан замолчать (сообщение шлёт мини-апп), а когда
# упасть на своё меню. См. docs/BOT-START.md.
# Запуск: bash tests/test-botstart.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export HY2M_DATA_DIR=$(mktemp -d)
export HY2M_WEBROOT="$HY2M_DATA_DIR/web"
mkdir -p "$HY2M_WEBROOT"
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT

source "$SCRIPT_DIR/lib/config.sh"
LOG_DIR="$HY2M_DATA_DIR/log"        # задаётся в hy2-manager.sh, тут его нет
source "$SCRIPT_DIR/lib/tgbot.sh"
source "$SCRIPT_DIR/lib/tgbot_client.sh"

# Заглушка сети: пишет аргументы в файл, отвечает тем, что лежит в $CURL_REPLY.
CURL_ARGS="$HY2M_DATA_DIR/curl.args"
CURL_REPLY='{"ok":true}'
curl() { printf '%s\n' "$@" > "$CURL_ARGS"; printf '%s' "$CURL_REPLY"; }

FAIL=0
ok()   { echo "  ✅ $1"; }
bad()  { echo "  ❌ $1"; FAIL=1; }
check() { [ "$2" = "$3" ] && ok "$1" || bad "$1: ждали «$3», получили «$2»"; }

echo "── без настроек мини-аппа"
bot_miniapp_start 111 111 "" "" "" && bad "должен вернуть 1" || ok "возврат 1 → менеджер шлёт своё меню"
[ -f "$CURL_ARGS" ] && bad "сети быть не должно" || ok "в сеть не ходили"

bot_set MINIAPP_API "https://webapp.example/"
bot_set MINIAPP_SECRET "s3cret"

echo "── реферальный /start"
bot_miniapp_start 111 222 "ref_ABCD1234" "vasya" "Вася" && ok "возврат 0 → приветствие отправил мини-апп" \
    || bad "ok:true должен давать 0"
body=$(grep -A1 -- '--data-binary' "$CURL_ARGS" | tail -1)
check "url без двойного слэша" "$(grep -c '^https://webapp.example/api/bot/start$' "$CURL_ARGS")" "1"
check "секрет в заголовке"     "$(grep -c '^X-Bot-Secret: s3cret$' "$CURL_ARGS")" "1"
check "tg_id"       "$(echo "$body" | jq -r .tg_id)"       "222"
check "chat_id"     "$(echo "$body" | jq -r .chat_id)"     "111"
check "start_param" "$(echo "$body" | jq -r .start_param)" "ref_ABCD1234"
check "first_name"  "$(echo "$body" | jq -r .first_name)"  "Вася"

echo "── мини-апп ответил отказом / молчит"
CURL_REPLY='{"ok":false}'
bot_miniapp_start 111 222 "" "" "" && bad "ok:false должен давать 1" || ok "ok:false → фолбэк на меню"
CURL_REPLY=''
bot_miniapp_start 111 222 "" "" "" && bad "пустой ответ должен давать 1" || ok "нет ответа → фолбэк на меню"

echo
[ "$FAIL" -eq 0 ] && echo "ВСЁ ЗЕЛЁНОЕ" || echo "ЕСТЬ ПАДЕНИЯ"
exit "$FAIL"
