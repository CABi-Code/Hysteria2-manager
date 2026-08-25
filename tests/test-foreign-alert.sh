#!/bin/bash
# Уведомление о чужом устройстве (lib/notify.sh, notify_foreign_devices).
#
# Проверяем ровно то, из-за чего фича может стать вредной: спам и ложные
# срабатывания. Подписка обновляется у всех раз в час, поэтому «прогнали второй
# раз — тишина» здесь важнее, чем «сообщение вообще отправилось».
# Запуск: bash tests/test-foreign-alert.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export HY2M_DATA_DIR=$(mktemp -d)
OUT="$HY2M_DATA_DIR/sent.log"
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT

source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/ip_tracking.sh"

FAIL=0
ok()    { echo "  ✅ $1"; }
bad()   { echo "  ❌ $1"; FAIL=1; }
check() { [ "$2" = "$3" ] && ok "$1" || bad "$1: ждали «$3», получили «$2»"; }

source "$SCRIPT_DIR/lib/notify.sh"

# Заглушки ПОСЛЕ source: notify.sh определяет ce, notify_user,
# bot_username и miniapp_screen_url — объяви мы их выше, файл бы их затёр.
# --- заглушки окружения бота и менеджера ---------------------------------
bot_enabled()  { return 0; }
bot_mod_on()   { return 0; }
bot_token()    { echo stub; }
bot_username() { echo stubbot; }
miniapp_screen_url() { echo "https://t.me/stubbot/app?startapp=$1"; }
ce() { printf '%s' "$1"; }
sub_all_users()  { echo alice; }
sub_token_for()  { echo tokA; }
DEVICES=2
get_user_devices() { echo "$DEVICES"; }
# Одно сообщение — одна строка: текст многострочный, а считаем мы сообщения.
notify_user() { printf '%s\n' "$(printf '%s' "$2" | tr '\n' ' ')" >> "$OUT"; }
sent() { wc -l < "$OUT" | tr -d " "; }

# get_user_apps читает SUBAPPS_FILE по токенам юзера; в тесте токен один.
sub_tokens_cluster() { echo tokA; }

NOW=$(date +%s)
dev() {   # hwid app ver os model
    printf 'tokA|%s|%s|%s|%s|%s|%s|%s|1\n' "$1" "$2" "$3" "$4" "$5" "$NOW" "$NOW" >> "$SUBAPPS_FILE"
}

: > "$OUT"; : > "$SUBAPPS_FILE"; : > "$SUBAPPS_SEEN_FILE"

echo "── первый взгляд на человека молчит"
# Иначе первый же прогон после обновления разошлёт «новое устройство» всем,
# у кого вообще есть телефон.
dev aaa Happ 4.1.0 "Android 15" Pixel
dev bbb Happ 4.1.0 "Android 14" Redmi
dev ccc v2raytun 5.0 "Android 11" Xiaomi     # уже сверх лимита (оплачено 2)
notify_foreign_devices
check "сообщений нет" "$(sent)" "0"
check "все три устройства помечены" "$(grep -c '^tokA|[a-z]' "$SUBAPPS_SEEN_FILE")" "3"

echo "── новое устройство сверх оплаченного"
dev ddd v2raytun 5.25.81 "Android 11" "Redmi M2004J19C"
notify_foreign_devices
check "одно сообщение" "$(sent)" "1"
grep -q "Redmi M2004J19C" "$OUT" && ok "в тексте модель нового устройства" \
                                 || bad "модель нового устройства не попала в текст"
grep -q "4</b> устройств" "$OUT" && ok "сказано, сколько всего устройств" \
                                 || bad "не сказано, сколько устройств"

echo "── повторный прогон молчит (главное правило)"
# Подписка обновляется раз в час у КАЖДОГО устройства. Без отметки человек
# получал бы это сообщение 24 раза в сутки и перестал бы читать бота вовсе.
notify_foreign_devices
notify_foreign_devices
check "сообщений по-прежнему одно" "$(sent)" "1"

echo "── клиент без X-Hwid не тревожит никогда"
# Hiddify и v2rayNG не присылают идентификатор: сказать «это новое устройство»
# про них честно нельзя, они неотличимы друг от друга.
: > "$OUT"
dev '~HiddifyNext/windows' HiddifyNext 4.1.1 windows ''
dev '~v2rayNG/' v2rayNG 1.9.46 '' ''
notify_foreign_devices
check "тишина" "$(sent)" "0"

echo "── в пределах оплаченного не тревожим"
: > "$OUT"; : > "$SUBAPPS_FILE"; : > "$SUBAPPS_SEEN_FILE"
DEVICES=5
dev aaa Happ 4.1.0 "Android 15" Pixel
notify_foreign_devices                      # первый взгляд — метки
dev eee Happ 4.1.0 "Android 16" Poco        # второй телефон, оплачено 5
notify_foreign_devices
check "новое устройство в лимите — молчим" "$(sent)" "0"
grep -qF 'tokA|eee|' "$SUBAPPS_SEEN_FILE" && ok "но устройство запомнено" \
                                          || bad "устройство не запомнено"

echo "── кулдаун при утечке ссылки"
: > "$OUT"; DEVICES=1
dev fff Happ 1 Android A
notify_foreign_devices
check "первое сообщение ушло" "$(sent)" "1"
dev ggg Happ 1 Android B                    # ссылку выложили: устройства капают
notify_foreign_devices
check "второе за сутки не ушло" "$(sent)" "1"
grep -qF 'tokA|ggg|' "$SUBAPPS_SEEN_FILE" && ok "но и оно запомнено (не выстрелит потом)" \
                                          || bad "устройство из кулдауна не запомнено"

echo "── безлимит устройств не тревожит"
: > "$OUT"; DEVICES=0
dev hhh Happ 1 Android C
notify_foreign_devices
check "тишина" "$(sent)" "0"

echo "── уборка старых отметок"
DEVICES=2
printf 'tokA|ancient|%s\n' "$(( NOW - 400 * 86400 ))" >> "$SUBAPPS_SEEN_FILE"
notify_foreign_devices
grep -q '|ancient|' "$SUBAPPS_SEEN_FILE" && bad "отметка 400-дневной давности осталась" \
                                         || ok "отметка старше 30 дней убрана"

[ "$FAIL" = 0 ] && echo "✅ test-foreign-alert: ok" || echo "❌ test-foreign-alert: есть ошибки"
exit "$FAIL"
