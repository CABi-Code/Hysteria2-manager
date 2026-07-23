#!/bin/bash
# Приём рублей через ЮMoney (lib/yoomoney.sh): сумма к оплате с комиссией,
# уникальность метки, сверка зачисленного с ценой и идемпотентность выдачи.
# Запуск: bash tests/test-yoomoney.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export HY2M_DATA_DIR=$(mktemp -d)
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT

source "$SCRIPT_DIR/lib/config.sh"

# Заглушки вместо бота: интересует только решение «выдать / не выдать».
BOT_CONF="$DATA_DIR/bot.conf"
PAYMENTS_LOG="$DATA_DIR/payments.log"
bot_get() { grep "^${1}=" "$BOT_CONF" 2>/dev/null | head -1 | cut -d= -f2-; }
bot_set() { local t; t=$(mktemp); grep -v "^${1}=" "$BOT_CONF" >"$t" 2>/dev/null; printf '%s=%s\n' "$1" "$2" >>"$t"; cat "$t" >"$BOT_CONF"; rm -f "$t"; }
tg_esc() { printf '%s' "$1"; }
FULFILLED=""; NOTIFIED=""
bot_fulfill_payment() { FULFILLED+="$3/$4/$6 "; printf '%s|%s|%s|%s|%s|%s|%s\n' "$(date '+%F %T')" "$2" "u" "c" "$4" "$5" "$6" >> "$PAYMENTS_LOG"; }
bot_notify_admins()   { NOTIFIED+="$1"; }

source "$SCRIPT_DIR/lib/yoomoney.sh"

fail() { echo "❌ $1"; exit 1; }

# --- выключен, пока нет кошелька и токена ---
ym_enabled && fail "способ включён без настроек"
bot_set YM_WALLET 4100000000000000
ym_enabled && fail "способ включён без токена — подтверждать оплату нечем"
bot_set YM_TOKEN test-token
ym_enabled || fail "способ должен быть включён"

# --- сумма к оплате: делим на (1 − комиссия), а не прибавляем процент ---
bot_set YM_FEE 3
[ "$(ym_pay_sum 1000)" = "1030.93" ] || fail "1000 ₽ при 3 %: $(ym_pay_sum 1000) (ожидали 1030.93)"
# Проверка смысла: после комиссии 3 % на кошелёк приходит НЕ МЕНЬШЕ цены.
[ "$(awk -v s="$(ym_pay_sum 1000)" 'BEGIN{print (s*0.97 >= 1000) ? "ok" : "no"}')" = "ok" ] \
    || fail "после комиссии на кошелёк придёт меньше цены"
bot_set YM_FEE 0
[ "$(ym_pay_sum 500)" = "500.00" ] || fail "без комиссии сумма меняться не должна: $(ym_pay_sum 500)"
bot_set YM_FEE 3

# --- метка: уникальная, ASCII, с префиксом ---
bot_set YM_PREFIX "my proj!"
l1=$(ym_new_label); l2=$(ym_new_label)
[ "$l1" != "$l2" ] || fail "метки повторяются"
[[ "$l1" =~ ^myproj-[0-9a-f]{16}$ ]] || fail "метка неожиданного вида: $l1"
[ "${#l1}" -le 64 ] || fail "метка длиннее 64 символов"

# --- ссылка содержит кошелёк, сумму и метку ---
url=$(ym_link "$l1" "1030.93" "1 месяц")
[[ "$url" == *"receiver=4100000000000000"* ]] || fail "в ссылке нет кошелька"
[[ "$url" == *"sum=1030.93"* && "$url" == *"label=$l1"* ]] || fail "в ссылке нет суммы/метки: $url"
[[ "$url" == *"paymentType=AC"* ]] || fail "тип платежа по умолчанию не AC"
# Форма shop с назначением платежа. Форма button без targets проводится как
# пополнение кошелька: без метки и без следа в истории по метке — оплату не найти.
[[ "$url" == *"quickpay-form=shop"* ]] || fail "форма не shop: $url"
[[ "$url" == *"confirm.xml"* ]] || fail "адрес формы не confirm.xml: $url"
[[ "$url" == *"targets=1%20"* ]] || fail "назначение платежа не закодировано: $url"
# Плательщику назначение показывают formcomment/short-dest, а не targets.
[[ "$url" == *"formcomment=1%20"* && "$url" == *"short-dest=1%20"* ]] || fail "нет назначения для плательщика: $url"

# --- оплата найдена и достаточна → выдаём доступ ровно один раз ---
ym_pending_add "$l1" 777 m1 vasya "1030.93" 1000
ym_find_operation() { echo "op-1 1000.01"; }
ym_settle "$l1" || fail "оплаченный счёт не выдал доступ (код $?)"
[ "$FULFILLED" = "pay:m1:vasya/100001/ym:op-1 " ] || fail "фулфилмент неверный: '$FULFILLED'"
[ -z "$(ym_pending_get "$l1")" ] || fail "счёт остался в ожидающих после выдачи"

# Повтор той же операции (второй опрос до вычистки) доступ не продлевает.
ym_pending_add "$l1" 777 m1 vasya "1030.93" 1000
FULFILLED=""
ym_settle "$l1" || fail "повторная проверка вернула ошибку"
[ -z "$FULFILLED" ] || fail "та же операция выдала доступ второй раз: '$FULFILLED'"

# --- оплаты нет → код 1, счёт ждёт дальше ---
l3=$(ym_new_label)
ym_pending_add "$l3" 778 m1 petya "1030.93" 1000
ym_find_operation() { echo ""; }
ym_settle "$l3"; [ "$?" = 1 ] || fail "неоплаченный счёт должен возвращать 1"
[ -n "$(ym_pending_get "$l3")" ] || fail "неоплаченный счёт выкинули из ожидающих"

# --- пришло меньше цены → доступ НЕ выдаём, зовём админа ---
FULFILLED=""
ym_find_operation() { echo "op-2 100.00"; }
ym_settle "$l3"; [ "$?" = 2 ] || fail "недоплата должна возвращать 2"
[ -z "$FULFILLED" ] || fail "выдали доступ при недоплате"
[[ "$NOTIFIED" == *"100.00"* ]] || fail "админ не уведомлён о недоплате"

# --- просроченные счета вычищаются, свежие остаются ---
l4=$(ym_new_label); l5=$(ym_new_label)
ym_pending_add "$l4" 779 m1 old "1030.93" 1000
# Состариваем запись на трое суток.
sed -i "s/^\($l4|\)[0-9]*/\1$(( $(date +%s) - 3*24*3600 ))/" "$YM_PENDING_FILE"
ym_pending_add "$l5" 780 m1 fresh "1030.93" 1000
ym_find_operation() { echo ""; }
ym_poll
[ -z "$(ym_pending_get "$l4")" ] || fail "просроченный счёт не вычищен"
[ -n "$(ym_pending_get "$l5")" ] || fail "свежий счёт вычищен по TTL"

echo "✅ tests/test-yoomoney.sh: все проверки пройдены"
