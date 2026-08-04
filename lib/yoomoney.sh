#!/bin/bash
# ================================================
# Приём рублей через ЮMoney (quickpay «API для сбора денег»)
#
# Зачем: чтобы продавать тарифы за рубли, не подключая платёжного провайдера
# BotFather (ЮKassa и т.п. требуют юрлицо/ИП и модерацию). Достаточно личного
# кошелька ЮMoney — ссылка на оплату формируется локально.
#
# Из формата quickpay следуют три ограничения, они и определяют схему:
#   1) счёта на стороне ЮMoney НЕТ — ссылка это просто набор параметров;
#   2) идентификатора платежа до оплаты нет: единственная связь платежа с
#      покупателем — метка label, которую придумываем мы сами;
#   3) заплатить по ссылке может кто угодно и любую сумму — сверка обязательна.
#
# Подтверждение оплаты — ОПРОСОМ истории операций по label (нужен OAuth-токен со
# scope operation-history). HTTP-уведомления ЮMoney здесь сознательно НЕ
# используются: они требуют публичный HTTPS-эндпоинт, а менеджер должен работать
# и за NAT без домена (бот живёт на long polling). Клиент может не ждать крона и
# нажать «Проверить оплату» — это тот же опрос, только сразу.
#
# Настройки (bot.conf, задаются в меню бота):
#   YM_WALLET        номер кошелька-получателя (пусто → способ выключен)
#   YM_TOKEN         OAuth-токен для чтения истории операций
#   YM_FEE           комиссия сервиса, % (см. ym_pay_sum)
#   YM_TYPE          AC — банковская карта (по умолчанию), PC — кошелёк ЮMoney
#   YM_PREFIX        префикс метки: на один кошелёк могут принимать несколько проектов
#
# Данные: $DATA_DIR/ympay.dat — ждущие оплаты счета,
#   «label|создан_ts|tg_id|код_тарифа|пользователь|сумма_к_оплате|цена_руб»
#
# Документация: docs/guide/YOOMONEY.md
# ================================================

YM_PENDING_FILE="$DATA_DIR/ympay.dat"
YM_QUICKPAY_URL="https://yoomoney.ru/quickpay/confirm.xml"
YM_HISTORY_URL="https://yoomoney.ru/api/operation-history"
YM_TTL_HOURS=48          # дольше не ждём: счёт вычищается, ссылка бесполезна

ym_enabled() { [ -n "$(bot_get YM_WALLET)" ] && [ -n "$(bot_get YM_TOKEN)" ]; }

ym_fee() {
    local f; f=$(bot_get YM_FEE)
    [[ "$f" =~ ^[0-9]+([.][0-9]+)?$ ]] || f=3
    printf '%s' "$f"
}

ym_type() { [ "$(bot_get YM_TYPE)" = "PC" ] && printf 'PC' || printf 'AC'; }

# Сколько покупатель переводит, чтобы на кошелёк ПРИШЛА цена тарифа.
# Комиссию ЮMoney берёт с ПОЛУЧАТЕЛЯ и считает от переведённой суммы (карта 3 %,
# кошелёк ≈0.99 %), поэтому делим, а не прибавляем процент: «цена + 3 %» дало бы
# на кошельке меньше цены (1000 → 1030 → придёт 999.10). Округляем вверх до копейки.
ym_pay_sum() {   # цена_руб -> «1030.93»
    awk -v p="$1" -v f="$(ym_fee)" 'BEGIN{
        if (f < 0)  f = 0
        if (f >= 90) f = 90
        printf "%.2f", (int(p * 100 / (1 - f/100) - 0.0000001) + 1) / 100
    }'
}

# Метка платежа: случайная, до 64 ASCII без пробелов. Не по порядку — label
# виден плательщику и подставляется в ссылку, угадываемый позволил бы
# притвориться чужим счётом. Персональных данных в метке нет.
ym_new_label() {
    local prefix; prefix=$(bot_get YM_PREFIX)
    prefix=$(printf '%s' "${prefix:-hy2}" | tr -cd 'A-Za-z0-9_-')
    [ -n "$prefix" ] || prefix="hy2"
    printf '%s-%s' "$prefix" "$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
}

# Процентное кодирование значения параметра (назначение платежа — текст с
# пробелами и кириллицей).
ym_urlenc() {
    printf '%s' "$1" | od -An -tx1 -v | tr ' ' '\n' | grep -v '^$' | while read -r h; do
        case "$h" in
            3[0-9]|4[1-9a-f]|5[0-9a]|6[1-9a-f]|7[0-9a]|2d|2e|5f|7e) printf '%b' "\x$h" ;;
            *) printf '%%%s' "$(printf '%s' "$h" | tr 'a-f' 'A-F')" ;;
        esac
    done
}

# Ссылка на форму оплаты. GET со всеми параметрами формы: страницы-редиректа с
# POST у менеджера нет и быть не может — домен не обязателен.
#
# Форма именно «shop» (оплата товара) с обязательным targets — назначением
# платежа. Форма «button» (сбор денег) без назначения ЮMoney проводит как
# ПОПОЛНЕНИЕ КОШЕЛЬКА с карты: деньги приходят, но это не входящий перевод —
# метка к нему не прикрепляется, и по метке такой платёж потом не найти. Со
# стороны это выглядит как «клиент оплатил, а бот не заметил».
ym_link() {   # label sum [назначение]
    local label="$1" sum="$2" targets="${3:-Оплата доступа}" wallet
    wallet=$(bot_get YM_WALLET)
    # targets видит получатель (название операции в истории кошелька),
    # formcomment/short-dest — плательщик на странице оплаты; без них там
    # дежурное «Перевод по кнопке» вместо названия тарифа.
    local enc; enc=$(ym_urlenc "$targets")
    printf '%s?receiver=%s&quickpay-form=shop&targets=%s&formcomment=%s&short-dest=%s&paymentType=%s&sum=%s&label=%s' \
        "$YM_QUICKPAY_URL" "$wallet" "$enc" "$enc" "$enc" "$(ym_type)" "$sum" "$label"
}

# ---------- ждущие оплаты счета ----------

ym_pending_add() {   # label tg_id код пользователь сумма цена
    mkdir -p "$DATA_DIR"; touch "$YM_PENDING_FILE"; chmod 600 "$YM_PENDING_FILE" 2>/dev/null
    printf '%s|%s|%s|%s|%s|%s|%s\n' "$1" "$(date +%s)" "$2" "$3" "$4" "$5" "$6" >> "$YM_PENDING_FILE"
}

ym_pending_del() {   # label
    local tmp; tmp=$(mktemp) || return 1
    grep -v "^${1}|" "$YM_PENDING_FILE" > "$tmp" 2>/dev/null
    cat "$tmp" > "$YM_PENDING_FILE"; rm -f "$tmp"
}

ym_pending_get() { awk -F'|' -v l="$1" '$1==l{print; exit}' "$YM_PENDING_FILE" 2>/dev/null; }

# ---------- проверка оплаты ----------

# Успешное входящее по метке: «operation_id сумма» либо пусто.
# refused/in_progress оплатой не считаются.
ym_find_operation() {   # label
    local token resp
    token=$(bot_get YM_TOKEN); [ -n "$token" ] || return 1
    resp=$(curl -s --max-time 20 -H "Authorization: Bearer $token" \
        -d "type=deposition" --data-urlencode "label=$1" -d "details=true" \
        "$YM_HISTORY_URL" 2>/dev/null) || return 1
    printf '%s' "$resp" | jq -r '.operations[]? | select(.status=="success")
        | "\(.operation_id) \(.amount)"' 2>/dev/null | head -1
}

# Проверить один счёт и выдать доступ, если оплачен.
# Коды возврата: 0 — оплачен и выдан, 1 — оплаты нет, 2 — пришло меньше цены.
# Проверка идемпотентности смотрит в журнал оплат, а строку туда пишет
# bot_fulfill_payment В КОНЦЕ — после провижининга (~18 с, внутри рестарт
# протоколов). Всё это окно кнопка «Проверить оплату» и крон --ym-poll видят
# «не выдавали» и продлевают второй раз за один платёж. Замок закрывает окно
# целиком: второй процесс ждёт и после ожидания уже находит запись в журнале.
# Не дождался за 60 с — считаем «оплаты нет» (вернётся следующим опросом).
# fd 7: 8 занят подметанием уведомлений, 9 — тиком скоростей.
ym_settle() {   # label
    local rc
    { exec 7>"$DATA_DIR/.yoomoney.lock"; } 2>/dev/null || return 1
    flock -w 60 7 2>/dev/null || { { exec 7>&-; } 2>/dev/null; return 1; }
    _ym_settle "$1"; rc=$?
    flock -u 7 2>/dev/null; { exec 7>&-; } 2>/dev/null
    return $rc
}

_ym_settle() {   # label
    local label="$1" row ts tgid code user sum price op amount
    row=$(ym_pending_get "$label"); [ -n "$row" ] || return 1
    IFS='|' read -r label ts tgid code user sum price <<< "$row"

    read -r op amount <<< "$(ym_find_operation "$label")"
    [ -n "${op:-}" ] || return 1

    # Идемпотентность: журнал оплат — единственный след выдачи, и он же переживает
    # рестарт бота. Повторный опрос той же операции доступ второй раз не продлит.
    if grep -q "|ym:${op}$" "$PAYMENTS_LOG" 2>/dev/null; then
        ym_pending_del "$label"; return 0
    fi

    # Сверяем ЗАЧИСЛЕННОЕ (amount) с ценой тарифа: в истории операций суммы уже
    # без комиссии, а сумма из ссылки (sum) была больше ровно на неё.
    # Копейка допуска — округления с обеих сторон.
    if [ "$(awk -v a="${amount:-0}" -v p="$price" 'BEGIN{print (a + 0.01 >= p) ? 1 : 0}')" != "1" ]; then
        bot_notify_admins "⚠️ ЮMoney: по метке <code>$(tg_esc "$label")</code> пришло ${amount} ₽ вместо ${price} ₽ (tg:${tgid}). Доступ НЕ выдан — разберитесь вручную."
        ym_pending_del "$label"
        return 2
    fi

    # Тот же фулфилмент, что у Stars и провайдера: сумма в копейках, как у
    # Telegram-платежей в не-XTR валюте.
    bot_fulfill_payment "$tgid" "$tgid" "pay:${code}:${user}" \
        "$(awk -v a="$amount" 'BEGIN{printf "%d", a*100 + 0.5}')" "RUB" "ym:${op}"
    ym_pending_del "$label"
    return 0
}

# Обойти все ждущие счета (крон, раз в минуту). Просроченные — вычистить.
ym_poll() {
    ym_enabled || return 0
    [ -s "$YM_PENDING_FILE" ] || return 0
    local now cutoff label ts rest
    now=$(date +%s); cutoff=$((now - YM_TTL_HOURS * 3600))

    while IFS='|' read -r label ts rest; do
        [ -n "$label" ] || continue
        if [ "${ts:-0}" -lt "$cutoff" ] 2>/dev/null; then
            ym_pending_del "$label"; continue
        fi
        ym_settle "$label" >/dev/null 2>&1
    done < <(cut -d'|' -f1,2 "$YM_PENDING_FILE" 2>/dev/null)
}
