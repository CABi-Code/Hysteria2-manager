#!/bin/bash
# Зачисление Stars-пополнения надстройки (bot_fulfill_topup, lib/tgbot_client.sh):
# пишем строку в журнал оплат и уведомляем админов, а КЛИЕНТУ молчим — счёт
# выставила надстройка, она же перепишет своё сообщение в «зачислено»; наше
# «оплата получена» было вторым сообщением об одном событии.
# Запуск: bash tests/test-topup-fulfill.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export HY2M_DATA_DIR=$(mktemp -d)
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT

LOG_DIR="$HY2M_DATA_DIR"; LOG_FILE="$LOG_DIR/error.log"   # их ждёт tgbot.sh при сорсинге

source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/tgbot.sh"
source "$SCRIPT_DIR/lib/tariffs.sh"
source "$SCRIPT_DIR/lib/tgbot_client.sh"

fail() { echo "❌ $1"; exit 1; }

# Наружу не ходим: подменяем отправку и считаем, кому что ушло.
CLIENT_MSGS="$HY2M_DATA_DIR/client.txt"; : > "$CLIENT_MSGS"
ADMIN_MSGS="$HY2M_DATA_DIR/admin.txt"; : > "$ADMIN_MSGS"
tg_send() { printf '%s\n' "$*" >> "$CLIENT_MSGS"; }
bot_notify_admins() { printf '%s\n' "$*" >> "$ADMIN_MSGS"; }

bot_fulfill_topup 555 555 100 XTR "charge_abc"

line=$(tail -n1 "$PAYMENTS_LOG")
IFS='|' read -r _date tgid user code amount cur charge <<< "$line"
[ "$tgid" = "555" ]        || fail "в журнал ушёл чужой tg_id: $line"
[ "$user" = "-" ]          || fail "пополнение записано на пользователя «$user» (биллинг матчит по tg_id)"
[ "$code" = "topup" ]      || fail "код строки «$code», а не topup — биллинг зачислит как тариф"
[ "$amount" = "100" ]      || fail "потеряна сумма: $line"
[ "$cur" = "XTR" ]         || fail "потеряна валюта: $line"
[ "$charge" = "charge_abc" ] || fail "потерян charge_id — сломается курсор и дедуп: $line"

[ -s "$CLIENT_MSGS" ] && fail "бот написал клиенту про пополнение — это дубль сообщения надстройки: $(cat "$CLIENT_MSGS")"
[ "$(wc -l < "$ADMIN_MSGS")" = "1" ] || fail "админам ушло не одно сообщение"

echo "✅ пополнение: журнал + админы, клиенту молчим"
