#!/bin/bash
# Чем скачивают подписку (lib/ip_tracking.sh): разбор заголовков клиента из
# access-лога Caddy в SUBAPPS_FILE, свойства-колонки в _ips_merge и удаление
# записей по просьбе человека (apps_forget).
#
# Приложение видно ТОЛЬКО в HTTP-запросе за подпиской: на туннеле его не отдаёт
# ни один движок. Поэтому разбор User-Agent и X-* заголовков — единственное
# место, где эта информация вообще появляется, и ломать его молча нельзя.
# Запуск: bash tests/test-subapps.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export HY2M_DATA_DIR=$(mktemp -d)
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT

source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/ip_tracking.sh"

FAIL=0
ok()    { echo "  ✅ $1"; }
bad()   { echo "  ❌ $1"; FAIL=1; }
check() { [ "$2" = "$3" ] && ok "$1" || bad "$1: ждали «$3», получили «$2»"; }

NOW=$(date +%s)
OLD=$(( NOW - 40 * 86400 ))

echo "── свойства в _ips_merge (nattr)"
: > "$SUBAPPS_FILE"
printf 'tok1\thw1\tHapp\t4.1.0\tAndroid 15\tPixel\n' | _ips_merge "$SUBAPPS_FILE" "$NOW" 4
check "строка записана целиком" "$(cat "$SUBAPPS_FILE")" "tok1|hw1|Happ|4.1.0|Android 15|Pixel|$NOW|$NOW|1"

# Свойство — не часть ключа: обновлённое приложение не должно плодить вторую
# строку на то же устройство, иначе у человека «7 устройств» вместо одного.
printf 'tok1\thw1\tHapp\t4.2.0\tAndroid 16\tPixel\n' | _ips_merge "$SUBAPPS_FILE" "$(( NOW + 60 ))" 4
check "та же строка, не вторая" "$(wc -l < "$SUBAPPS_FILE")" "1"
check "версия приложения обновилась" "$(cut -d'|' -f4 "$SUBAPPS_FILE")" "4.2.0"
check "версия ОС обновилась" "$(cut -d'|' -f5 "$SUBAPPS_FILE")" "Android 16"
check "first_seen сохранён" "$(cut -d'|' -f7 "$SUBAPPS_FILE")" "$NOW"
check "счётчик вырос" "$(cut -d'|' -f9 "$SUBAPPS_FILE")" "2"

printf 'tok1\thw2\tHapp\t4.2.0\tAndroid 16\tPixel\n' | _ips_merge "$SUBAPPS_FILE" "$NOW" 4
check "другой hwid — другая строка" "$(wc -l < "$SUBAPPS_FILE")" "2"

echo "── старый формат без свойств не сломан"
: > "$IPS_FILE"
printf 'alice\t1.1.1.1\n' | _ips_merge "$IPS_FILE" "$NOW"
check "пять колонок как раньше" "$(cat "$IPS_FILE")" "alice|1.1.1.1|$NOW|$NOW|1"

echo "── чистка протухших со свойствами"
printf 'tok|hw|Happ|1|Android|M|%s|%s|5\n' "$OLD" "$OLD" > "$SUBAPPS_FILE"
printf '' | _ips_merge "$SUBAPPS_FILE" "$NOW" 4
check "запись 40-дневной давности выброшена" "$(grep -c . "$SUBAPPS_FILE")" "0"

echo "── разбор заголовков реальных клиентов"
# Подменяем journalctl: тест не должен зависеть от журнала машины.
LOG=$(mktemp); trap 'rm -rf "$HY2M_DATA_DIR" "$LOG"' EXIT
emit() {   # ua  [заголовки json]
    printf '{"request":{"uri":"/sub/tokA","remote_ip":"5.5.5.5","headers":{"User-Agent":["%s"]%s}}}\n' "$1" "${2:-}"
}
{
  emit 'HiddifyNext/4.1.1 (windows) like ClashMeta v2ray sing-box'
  emit 'HiddifyNext/4.0.0 (ios) like ClashMeta v2ray sing-box'
  emit 'Happ/4.1.0/Android/17860741775021899510' \
       ',"X-Hwid":["239d26a99ed813ff"],"X-Device-Os":["Android"],"X-Ver-Os":["15"],"X-Device-Model":["25062RN2DY"]'
  emit 'INCY/2.5.2/ios CFNetwork/3860.600.12 Darwin/25.5.0' \
       ',"X-Hwid":["AAAA-BBBB"],"X-Client":["INCY"],"X-App-Version":["2.5.2"],"X-Device-Os":["iOS"],"X-Ver-Os":["26.5.2"],"X-Device-Model":["iPhone 17 Pro Max"]'
  emit 'v2raytun/android' \
       ',"X-Hwid":["6E0D2EDF"],"X-Ver-Os":["Android 11"],"X-Device-Os":["Android"],"X-Device-Model":["Redmi M2004J19C"],"X-App-Version":["5.25.81"]'
  emit 'v2rayNG/1.9.46'
  # Клиент, пытающийся сломать формат файла: «|» в модели обязан быть вычищен.
  emit 'Happ/1.0/Android/1' ',"X-Hwid":["evil"],"X-Device-Model":["a|b\tc"]'
} > "$LOG"
journalctl() { cat "$LOG"; }
export -f journalctl 2>/dev/null || true

: > "$SUBAPPS_FILE"; : > "$SUBIPS_FILE"; rm -f "$SUBLOG_TS"
sub_tokens_cluster() { echo tokA; }        # без sub_links.sh в тесте
collect_sub_ips

row() { awk -F'|' -v a="$1" '$3 == a { print; exit }' "$SUBAPPS_FILE"; }
check "Hiddify: версия не потерялась в хвосте UA" "$(row HiddifyNext | cut -d'|' -f4)" "4.1.1"
check "Hiddify: ОС из скобок"                     "$(row HiddifyNext | cut -d'|' -f5)" "windows"
check "Hiddify без hwid — синтетический ключ"      "$(row HiddifyNext | cut -d'|' -f2)" "~HiddifyNext/windows"
check "Happ: модель"                              "$(row Happ | cut -d'|' -f6)" "25062RN2DY"
check "Happ: ОС с версией"                        "$(row Happ | cut -d'|' -f5)" "Android 15"
check "Happ: hwid"                                "$(row Happ | cut -d'|' -f2)" "239d26a99ed813ff"
check "INCY: имя из X-Client"                     "$(row INCY | cut -d'|' -f4)" "2.5.2"
check "INCY: ОС и её версия"                      "$(row INCY | cut -d'|' -f5)" "iOS 26.5.2"
check "v2raytun: «android» это ОС, а не версия"   "$(row v2raytun | cut -d'|' -f5)" "Android 11"
check "v2raytun: версия из X-App-Version"         "$(row v2raytun | cut -d'|' -f4)" "5.25.81"
check "v2rayNG: версия из UA"                     "$(row v2rayNG | cut -d'|' -f4)" "1.9.46"

# Два Hiddify на разных ОС — две строки, а не одна: без этого у человека с
# ноутбуком и телефоном видно только то устройство, что обновилось последним.
check "Hiddify на двух ОС — две записи" "$(grep -c '|~HiddifyNext/' "$SUBAPPS_FILE")" "2"

# Разделитель полей, пришедший от клиента, ломал бы разбор всего файла.
evil=$(awk -F'|' '$2 == "evil"' "$SUBAPPS_FILE")
check "строка злого клиента не разъехалась" "$(printf '%s' "$evil" | awk -F'|' '{print NF}')" "9"
printf '%s' "$evil" | grep -qP '\t' && bad "таб от клиента попал в файл" || ok "таб от клиента вычищен"

check "адреса собраны тем же проходом" "$(cut -d'|' -f2 "$SUBIPS_FILE" | sort -u)" "5.5.5.5"

echo "── удаление по просьбе человека"
before=$(grep -c . "$SUBAPPS_FILE")
printf 'tokZ|hwZ|Happ|1|Android|M|%s|%s|1\n' "$NOW" "$NOW" >> "$SUBAPPS_FILE"
removed=$(apps_forget someone)
check "удалены все строки токенов юзера" "$removed" "$before"
check "чужая строка не тронута" "$(grep -c '^tokZ|' "$SUBAPPS_FILE")" "1"

[ "$FAIL" = 0 ] && echo "✅ test-subapps: ok" || echo "❌ test-subapps: есть ошибки"
exit "$FAIL"
