#!/bin/bash
# ================================================
# Бот, клиентская часть: доступ, меню, покупка, зачисление оплат
# Часть Telegram-бота (общие настройки и API — lib/tgbot.sh).
# ================================================

# ---------- продление/выдача доступа (общее для оплат и админ-команд) ----------
# Продлить срок юзера на N дней ОТ максимума(сегодня, текущий срок).
bot_extend_user() {   # user days [nonotify] -> печатает новую дату
    local user="$1" days="$2" quiet="$3" cur base new today
    cur=$(get_user_expiry "$user")
    base=$(date +%Y-%m-%d)
    if [ -n "$cur" ] && [[ "$cur" > "$base" ]]; then base="$cur"; fi
    # Знак обязателен: days бывает отрицательным (эскроу подарочных дней —
    # срок у дарителя укорачивается). Ниже сегодняшней даты не опускаемся,
    # иначе «подарок» молча отключил бы доступ дарителю.
    new=$(date -d "$base $(printf '%+d' "$days") days" +%Y-%m-%d 2>/dev/null)
    [ -n "$new" ] || return 1
    today=$(date +%Y-%m-%d)
    if [[ "$new" < "$today" ]]; then new="$today"; fi
    set_user_expiry "$user" "$new"
    # Длина текущего периода — для гейтов порогов «за 7 дней / за 1 день».
    declare -F period_days_set >/dev/null && period_days_set "$user" "$days"
    # Уведомление об активации/продлении с датой окончания. Прямой Stars-платёж
    # шлёт свою расширенную карточку (передаёт nonotify), чтобы не дублировать.
    if [ "$quiet" != "nonotify" ] && declare -F bot_notify_activated >/dev/null; then
        bot_notify_activated "$user" "$new"
    fi
    printf '%s' "$new"
}

# Стойкий пароль даже без pwgen (демон бота не должен зависеть от него —
# пустой пароль из-за отсутствующей утилиты был бы дырой в безопасности).
bot_gen_pass() {
    local p
    p=$(pwgen -s 64 1 2>/dev/null)
    [ -n "$p" ] || p=$(head -c 96 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 64)
    printf '%s' "$p"
}

# Создать нового юзера (или включить выключенного). Печатает пароль.
# Возвращает 1, если пароль получить/создать не удалось (юзера НЕ создаём).
bot_provision_user() {   # username -> pass
    local user="$1" pass
    if is_user_disabled "$user"; then
        enable_user "$user" >/dev/null 2>&1
        pass=$(get_user_password "$user")
    elif db_user_exists "$user"; then
        pass=$(get_user_password "$user")
    else
        pass=$(bot_gen_pass)
        [ -n "$pass" ] || return 1     # ни в коем случае не заводим юзера с пустым паролем
        db_add_user "$user" "$pass"
        # Клиент купил доступ — он должен работать на ВСЕХ нодах, а не только на
        # этой. Помечаем кластерным и публикуем сразу: раньше это была ручная
        # кнопка в меню, и каждый заведённый ботом или мини-аппом профиль
        # оставался локальным. nosync — обход пиров тут не нужен, они забирают
        # ростер своей синхронизацией (~5 мин). Вывод глушим: функция отдаёт
        # пароль через stdout.
        declare -F cluster_share_user >/dev/null 2>&1 \
            && cluster_share_user "$user" nosync >/dev/null 2>&1
    fi
    [ -n "$pass" ] || return 1
    printf '%s' "$pass"
}

# Текст со ссылками для юзера (ссылка + подписка, HTML).
bot_access_text() {   # username
    local user="$1" pass link
    pass=$(get_user_password "$user")
    [ -z "$pass" ] && pass=$(get_disabled_password "$user")
    [ -z "$pass" ] && { printf 'Ключ не найден — обратитесь к администратору.'; return; }
    link=$(build_user_link "$user" "$pass")
    printf '🔗 <b>Ссылка для клиента</b> (Hiddify, Nekobox, Streisand, sing-box):\n<code>%s</code>' "$(tg_esc "$link")"
    if sub_enabled; then
        printf '\n\n📡 <b>Ссылка-подписка</b> (все серверы, автообновление):\n<code>%s</code>' "$(tg_esc "$(subscription_url "$user")")"
    fi
}

# ---------- клавиатуры ----------
KB_CLIENT='{"inline_keyboard":[[{"text":"🔗 Моя ссылка","callback_data":"m:link"},{"text":"📡 Подписка","callback_data":"m:sub"}],[{"text":"📊 Мой статус","callback_data":"m:status"},{"text":"💳 Купить / продлить","callback_data":"m:buy"}]]}'
KB_ADMIN='{"inline_keyboard":[[{"text":"👥 Пользователи","callback_data":"a:users:1"},{"text":"📈 Сервер","callback_data":"a:stat"}],[{"text":"➕ Добавить (/add)","callback_data":"a:add"},{"text":"🎫 Код привязки (/code)","callback_data":"a:codehelp"}],[{"text":"💰 Тарифы","callback_data":"a:tariffs"}]]}'

# Меню клиента / приветствие.
bot_client_menu() {   # chat_id
    local chat="$1" user
    user=$(tg_bound_user "$chat")
    if [ -n "$user" ]; then
        tg_send "$chat" "👤 Аккаунт: <b>$(tg_esc "$user")</b>
Выберите действие:" "$KB_CLIENT"
    elif [ "$(tariff_count)" -gt 0 ] 2>/dev/null; then
        tg_send "$chat" "👋 Привет! Это бот VPN-доступа (Hysteria 2).
У вас пока нет аккаунта. Можно купить доступ прямо здесь — аккаунт создастся автоматически, или введите код привязки от администратора: <code>/start КОД</code>" '{"inline_keyboard":[[{"text":"💳 Купить доступ","callback_data":"m:buy"}]]}'
    else
        tg_send "$chat" "👋 Привет! Это бот VPN-доступа (Hysteria 2).
Чтобы привязать ваш аккаунт, запросите у администратора код и отправьте:
<code>/start КОД</code>"
    fi
}

# Передать /start мини-аппу (Laravel): он заводит/обновляет аккаунт, разбирает
# реферальный код и САМ шлёт приветствие с кнопкой «Открыть приложение», а следом
# уведомления о начисленном бонусе. Сообщение шлёт одна сторона — иначе клиент
# получил бы и приветствие, и меню бота.
# Мини-апп не открывается по ссылке из директа канала (баг Telegram), поэтому
# реферальная ссылка ведёт на /start бота. См. надстройка/docs/BOT-START.md.
# 0 — приветствие отправлено, 1 — мини-апп не настроен/недоступен (зовите меню).
bot_miniapp_start() {   # chat_id tg_id [start_param] [username] [first_name]
    local url secret body resp
    url=$(bot_get MINIAPP_API); secret=$(bot_get MINIAPP_SECRET)
    [ -n "$url" ] && [ -n "$secret" ] || return 1
    body=$(jq -nc --argjson chat "$1" --argjson tg "$2" \
        --arg sp "${3:-}" --arg un "${4:-}" --arg fn "${5:-}" \
        '{chat_id:$chat, tg_id:$tg, start_param:$sp, username:$un, first_name:$fn}') || return 1
    # Долгий таймаут: в ответе может лежать провижининг нового профиля (~18 с).
    resp=$(curl -s --max-time 60 -X POST "${url%/}/api/bot/start" \
        -H "X-Bot-Secret: $secret" -H 'Content-Type: application/json' \
        --data-binary "$body" 2>/dev/null)
    # Telegram легко теряет payload (человек жмёт «START», а не ссылку) — без
    # лога «пришёл без кода» неотличимо от сломанной привязки.
    echo "$(date '+%F %T') miniapp /start: tg=$2 payload='${3:-—}' → ${resp:0:120}"
    [ "$(echo "$resp" | jq -r '.ok // false' 2>/dev/null)" = "true" ]
}

# Нажата кнопка в карточке «Вход в веб-версию» (callback_data «wl:ok|no:<id>»).
# Решение принимает мини-апп: он же и переписывает карточку в чате. Здесь только
# доставка нажатия — long-polling наш. См. надстройка/docs/WEB-LOGIN.md.
bot_weblogin_cb() {   # chat_id tg_id message_id action id
    local url secret body
    url=$(bot_get MINIAPP_API); secret=$(bot_get MINIAPP_SECRET)
    [ -n "$url" ] && [ -n "$secret" ] || return 1
    body=$(jq -nc --argjson chat "$1" --argjson tg "$2" --argjson mid "${3:-0}" \
        --arg act "$4" --arg id "$5" \
        '{chat_id:$chat, tg_id:$tg, message_id:$mid, action:$act, request:$id}') || return 1
    curl -s --max-time 15 -X POST "${url%/}/api/bot/weblogin" \
        -H "X-Bot-Secret: $secret" -H 'Content-Type: application/json' \
        --data-binary "$body" >/dev/null 2>&1
}

# ---------- клиентские действия ----------
bot_client_link() {   # chat_id
    local chat="$1" user
    user=$(tg_bound_user "$chat")
    [ -z "$user" ] && { tg_send "$chat" "Аккаунт не привязан. Отправьте /start КОД или купите доступ (/buy)."; return; }
    if is_user_disabled "$user"; then
        tg_send "$chat" "⛔ Аккаунт <b>$(tg_esc "$user")</b> отключён$( [ "$(tariff_count)" -gt 0 ] && echo " — продлите доступ: /buy" )."
        return
    fi
    tg_send "$chat" "$(bot_access_text "$user")"
}

bot_client_status() {   # chat_id
    local chat="$1" user
    user=$(tg_bound_user "$chat")
    [ -z "$user" ] && { tg_send "$chat" "Аккаунт не привязан. Отправьте /start КОД или купите доступ (/buy)."; return; }
    local st exp exps tl tx rx dev oc
    if is_user_disabled "$user"; then st="⛔ отключён"; else st="✅ активен"; fi
    exp=$(get_user_expiry "$user")
    # На бесплатном тарифе платный срок в прошлом по замыслу: показывать
    # «истёк» тому, у кого доступ работает, — вранью в чистом виде.
    if declare -F freeplan_has >/dev/null 2>&1 && freeplan_has "$user"; then
        exps="🆓 бесплатный тариф$(freeplan_limits_line)"
    elif [ -n "$exp" ]; then
        exps="$exp ($(format_remaining "$exp" 2>/dev/null || echo '—'))"
    else
        exps="бессрочно"
    fi
    tl=$(get_user_traffic "$user"); tx=$(echo "$tl" | cut -d'|' -f2); rx=$(echo "$tl" | cut -d'|' -f3)
    dev=$(get_user_devices "$user")
    oc=$(api_get "/online" | jq -r --arg u "$user" '.[$u] // 0' 2>/dev/null); [[ "$oc" =~ ^[0-9]+$ ]] || oc=0
    tg_send "$chat" "📊 <b>$(tg_esc "$user")</b>
Статус: $st
Срок действия: $exps
Трафик: ↑$(format_bytes "$tx") · ↓$(format_bytes "$rx")
Устройств (лимит): $dev
Подключений сейчас: $oc" "$KB_CLIENT"
}

# Список тарифов кнопками (для покупки).
bot_buy_menu() {   # chat_id
    local chat="$1"
    if [ "$(tariff_count)" -eq 0 ] 2>/dev/null; then
        tg_send "$chat" "Тарифы пока не настроены. Свяжитесь с администратором."
        return
    fi
    local kb rows code title days devices price cur
    # Бесплатный тариф (free=1) в витрину покупки не показываем: на него не
    # покупают, а падают по истечении платного (см. lib/freeplan.sh).
    rows=$(tariff_list | while IFS='|' read -r code title days devices price cur _opts; do
        [ -n "$code" ] || continue
        [ "$(tariff_opt "$code" free)" = "1" ] && continue
        jq -nc --arg t "$title — $(tariff_price_str "$price" "$cur")" --arg d "buy:$code" '[{text:$t,callback_data:$d}]'
    done | jq -sc '.')
    kb=$(jq -nc --argjson r "$rows" '{inline_keyboard:$r}')
    tg_send "$chat" "💳 <b>Выберите тариф</b>
Оплата: Telegram Stars (⭐) или картой через платёжного провайдера — доступ выдаётся автоматически сразу после оплаты." "$kb"
}

# Выставить счёт по тарифу.
bot_send_invoice() {   # chat_id tariff_code [currency]
    local chat="$1" code="$2" want="${3:-}" row title days devices price cur _opts user payload prices provider
    row=$(tariff_get "$code")
    [ -z "$row" ] && { tg_send "$chat" "Тариф не найден (возможно, удалён)."; return; }
    IFS='|' read -r code title days devices price cur _opts <<< "$row"
    # Мультивалютный тариф: берём указанную валюту, иначе первую в списке.
    local -a pa ca; IFS='/' read -r -a pa <<< "$price"; IFS='/' read -r -a ca <<< "$cur"
    local pick=0 k
    if [ -n "$want" ]; then
        pick=-1
        for k in "${!ca[@]}"; do [ "${ca[$k]}" = "$want" ] && { pick=$k; break; }; done
        [ "$pick" -lt 0 ] && { tg_send "$chat" "Эта валюта недоступна для тарифа."; return; }
    fi
    price="${pa[$pick]}"; cur="${ca[$pick]:-XTR}"
    user=$(tg_bound_user "$chat"); [ -z "$user" ] && user="-"
    payload="pay:${code}:${user}"
    local desc="Доступ на ${days} дн."
    [ "$devices" -gt 0 ] 2>/dev/null && desc="$desc, устройств: ${devices}"
    [ "$user" != "-" ] && desc="$desc. Продление аккаунта ${user}." || desc="$desc. Аккаунт создастся автоматически."
    if [ "$cur" = "XTR" ]; then
        prices=$(jq -nc --arg l "$title" --argjson a "$price" '[{label:$l,amount:$a}]')
        tg_api sendInvoice --data-urlencode "chat_id=$chat" --data-urlencode "title=$title" \
            --data-urlencode "description=$desc" --data-urlencode "payload=$payload" \
            --data-urlencode "currency=XTR" --data-urlencode "prices=$prices" >/dev/null
    else
        provider=$(bot_get PAY_PROVIDER_TOKEN)
        # Провайдер не настроен, но есть кошелёк ЮMoney → продаём рубли через него
        # (счёт-ссылка + опрос истории, см. lib/yoomoney.sh).
        if [ -z "$provider" ] && [ "$cur" = "RUB" ] && ym_enabled; then
            bot_ym_invoice "$chat" "$code" "$title" "$price" "$days" "$user"
            return
        fi
        if [ -z "$provider" ]; then
            tg_send "$chat" "⚠️ Платёжный провайдер не настроен (тариф в $cur). Сообщите администратору."
            return
        fi
        prices=$(jq -nc --arg l "$title" --argjson a "$(( price * 100 ))" '[{label:$l,amount:$a}]')
        tg_api sendInvoice --data-urlencode "chat_id=$chat" --data-urlencode "title=$title" \
            --data-urlencode "description=$desc" --data-urlencode "payload=$payload" \
            --data-urlencode "provider_token=$provider" --data-urlencode "currency=$cur" \
            --data-urlencode "prices=$prices" >/dev/null
    fi
}

# Счёт ЮMoney: ссылка на форму оплаты + кнопка «Проверить оплату».
# Автоматически оплату подхватит крон (--ym-poll), кнопка — чтобы не ждать минуту.
bot_ym_invoice() {   # chat_id код название цена дней пользователь
    local chat="$1" code="$2" title="$3" price="$4" days="$5" user="$6"
    local label sum url kb
    label=$(ym_new_label)
    sum=$(ym_pay_sum "$price")
    # Назначение платежа = название тарифа: оно попадёт в историю кошелька и
    # будет видно плательщику.
    url=$(ym_link "$label" "$sum" "$title")
    ym_pending_add "$label" "$chat" "$code" "$user" "$sum" "$price"

    kb=$(jq -nc --arg u "$url" --arg d "ymchk:$label" \
        '{inline_keyboard:[[{text:"💳 Оплатить",url:$u}],[{text:"✅ Проверить оплату",callback_data:$d}]]}')
    tg_send "$chat" "💳 <b>$(tg_esc "$title")</b> — ${days} дн.
К оплате: <b>${sum} ₽</b> (в сумму включена комиссия платёжной системы).

Нажмите «Оплатить», а после перевода — «Проверить оплату».
Если закроете сообщение, доступ всё равно выдастся автоматически в течение минуты после оплаты." "$kb"
}

# Меню выбора валюты оплаты для мультивалютного тарифа (кнопка на валюту).
bot_buy_currency_menu() {   # chat_id tariff_code
    local chat="$1" code="$2" row title price cur _opts
    row=$(tariff_get "$code")
    [ -z "$row" ] && { tg_send "$chat" "Тариф не найден."; return; }
    IFS='|' read -r _ title _ _ price cur _opts <<< "$row"
    local -a pa ca; IFS='/' read -r -a pa <<< "$price"; IFS='/' read -r -a ca <<< "$cur"
    local rows i c p label
    rows=$(for i in "${!ca[@]}"; do
        c="${ca[$i]}"; p="${pa[$i]}"
        [ "$c" = "XTR" ] && label="⭐ $p" || label="$p $c"
        jq -nc --arg t "$label" --arg d "buy:$code:$c" '[{text:$t,callback_data:$d}]'
    done | jq -sc '.')
    local kb; kb=$(jq -nc --argjson r "$rows" '{inline_keyboard:$r}')
    tg_send "$chat" "💳 <b>$(tg_esc "$title")</b> — выберите способ оплаты:" "$kb"
}

# Обработка кнопки «buy:...»: «buy:код» (без валюты) или «buy:код:ВАЛЮТА».
# Без валюты: одна валюта → сразу счёт; несколько → меню выбора валюты.
bot_buy_dispatch() {   # chat_id rest(код | код:валюта)
    local chat="$1" rest="$2" code cur
    code="${rest%%:*}"
    if [ "$rest" = "$code" ]; then
        local -a ca; read -r -a ca <<< "$(tariff_currencies_of "$code")"
        if [ "${#ca[@]}" -le 1 ]; then bot_send_invoice "$chat" "$code"
        else bot_buy_currency_menu "$chat" "$code"; fi
    else
        cur="${rest#*:}"
        bot_send_invoice "$chat" "$code" "$cur"
    fi
}

# Пополнение баланса мини-аппа (payload «topup:<tg_id>»): доступ VPN НЕ трогаем,
# только пишем строку topup в журнал оплат — её подхватит биллинг мини-аппа
# (Laravel PollPayments) и зачислит баланс = звёзды × курс. Формат строки тот же,
# что у обычной оплаты; отличие — code=topup, username=«-» (биллинг матчит по tgid).
bot_fulfill_topup() {   # chat_id tg_id amount currency charge_id
    local chat="$1" tgid="$2" amount="$3" cur="$4" charge="$5"
    mkdir -p "$DATA_DIR"
    printf '%s|%s|%s|%s|%s|%s|%s\n' "$(date '+%F %T')" "$tgid" "-" "topup" "$amount" "$cur" "$charge" >> "$PAYMENTS_LOG"
    tg_send "$chat" "✅ <b>Оплата получена</b> — баланс пополняется, обновите приложение через пару секунд."
    bot_notify_admins "💎 <b>Пополнение баланса</b>: tg:${tgid} · ${amount} ${cur} · charge: <code>$(tg_esc "$charge")</code>"
}

# Имя для НОВОГО профиля: @username Telegram, если он есть и свободен, иначе
# tg<ID>. Так в списке пользователей видно живых людей, а не столбик из цифр;
# @username необязателен и меняется, поэтому уникальность гарантирует только
# запасное имя. Занятое чужим профилем имя не забираем — это чужой доступ.
bot_pick_username() {   # tg_id [handle]
    local tgid="$1" handle="${2:-}" name n=2
    handle="${handle#@}"
    if [[ "$handle" =~ ^[A-Za-z0-9_-]{1,64}$ ]] \
       && ! db_user_exists "$handle" && ! is_user_disabled "$handle"; then
        printf '%s' "$handle"; return 0
    fi
    name="tg${tgid}"
    while db_user_exists "$name" || is_user_disabled "$name"; do
        name="tg${tgid}_$n"; n=$((n+1))
    done
    printf '%s' "$name"
}

# Оплата прошла — выдать/продлить доступ.
bot_fulfill_payment() {   # chat_id tg_id payload total_amount currency charge_id [tg_handle]
    local chat="$1" tgid="$2" payload="$3" amount="$4" cur="$5" charge="$6" handle="${7:-}"
    local code user row title days devices price tcur _opts newexp
    # Пополнение баланса — отдельная ветка, тариф не ищем.
    if [ "${payload#topup:}" != "$payload" ]; then
        bot_fulfill_topup "$chat" "$tgid" "$amount" "$cur" "$charge"
        return
    fi
    code=$(printf '%s' "$payload" | cut -d: -f2)
    user=$(printf '%s' "$payload" | cut -d: -f3)
    row=$(tariff_get "$code")
    if [ -z "$row" ]; then
        # Тариф удалили между счётом и оплатой — сообщаем админам, не молчим.
        bot_notify_admins "⚠️ Оплата за НЕИЗВЕСТНЫЙ тариф «$(tg_esc "$code")» от tg:$tgid ($amount $cur). Выдайте доступ вручную!"
        tg_send "$chat" "Оплата получена, но тариф не найден. Администратор уведомлён и выдаст доступ вручную."
        return
    fi
    IFS='|' read -r code title days devices price tcur _opts <<< "$row"

    # Аккаунт: привязанный, из payload, либо новый (tg<ID>).
    [ "$user" = "-" ] && user=$(tg_bound_user "$tgid")
    [ -z "$user" ] && user=$(bot_pick_username "$tgid" "$handle")

    if ! bot_provision_user "$user" >/dev/null; then
        bot_notify_admins "🛑 Оплата от tg:$tgid получена, но создать пользователя «$(tg_esc "$user")» НЕ удалось. Разберитесь вручную (charge: <code>$(tg_esc "$charge")</code>)."
        tg_send "$chat" "Оплата получена, но при выдаче доступа произошла ошибка. Администратор уведомлён и всё выдаст вручную."
        return
    fi
    newexp=$(bot_extend_user "$user" "$days" nonotify)
    [ "$devices" -gt 0 ] 2>/dev/null && set_user_devices "$user" "$devices"
    tg_bind "$tgid" "$user"
    write_authlimits 2>/dev/null
    sub_enabled && sub_refresh >/dev/null 2>&1

    # Журнал и уведомления.
    mkdir -p "$DATA_DIR"
    printf '%s|%s|%s|%s|%s|%s|%s\n' "$(date '+%F %T')" "$tgid" "$user" "$code" "$amount" "$cur" "$charge" >> "$PAYMENTS_LOG"
    tg_send "$chat" "✅ <b>Оплата получена — доступ активирован!</b>
Аккаунт: <b>$(tg_esc "$user")</b>
Тариф: $(tg_esc "$title")
Действует до: <b>${newexp:-без срока}</b>

$(bot_access_text "$user")" "$KB_CLIENT"
    local amount_h="$amount"
    [ "$cur" != "XTR" ] && amount_h=$(awk "BEGIN{printf \"%.2f\", $amount/100}")
    bot_notify_admins "💰 <b>Оплата</b>: $(tg_esc "$user") · тариф «$(tg_esc "$title")» · ${amount_h} ${cur}
Действует до: ${newexp:-∞} · tg:${tgid} · charge: <code>$(tg_esc "$charge")</code>"
}

