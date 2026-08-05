#!/bin/bash
# ================================================
# Бот: обработка апдейтов, long-polling демон, авто-уведомления
# Часть Telegram-бота (общие настройки и API — lib/tgbot.sh).
# ================================================

bot_handle_update() {   # json
    local upd="$1"

    # 1) pre_checkout — подтверждаем, если тариф ещё существует.
    local pcq_id
    pcq_id=$(echo "$upd" | jq -r '.pre_checkout_query.id // empty' 2>/dev/null)
    if [ -n "$pcq_id" ]; then
        local payload code
        payload=$(echo "$upd" | jq -r '.pre_checkout_query.invoice_payload // empty')
        # Пополнение баланса мини-аппа (payload «topup:<tg_id>») тарифа не имеет —
        # подтверждаем безусловно, фулфилмент запишет строку topup в журнал.
        if [ "${payload#topup:}" != "$payload" ]; then
            tg_api answerPreCheckoutQuery --data-urlencode "pre_checkout_query_id=$pcq_id" \
                --data-urlencode "ok=true" >/dev/null
            return 0
        fi
        code=$(printf '%s' "$payload" | cut -d: -f2)
        # Продажа выключена (модуль sales) — счёт из старого сообщения не
        # проводим: отказ на pre_checkout деньги не списывает, в отличие от
        # отказа после оплаты.
        if ! bot_mod_on sales; then
            tg_api answerPreCheckoutQuery --data-urlencode "pre_checkout_query_id=$pcq_id" \
                --data-urlencode "ok=false" \
                --data-urlencode "error_message=Покупка через бота отключена." >/dev/null
        elif [ -n "$(tariff_get "$code")" ]; then
            tg_api answerPreCheckoutQuery --data-urlencode "pre_checkout_query_id=$pcq_id" \
                --data-urlencode "ok=true" >/dev/null
        else
            tg_api answerPreCheckoutQuery --data-urlencode "pre_checkout_query_id=$pcq_id" \
                --data-urlencode "ok=false" \
                --data-urlencode "error_message=Тариф больше не доступен. Выберите другой: /buy" >/dev/null
        fi
        return 0
    fi

    # 2) callback_query (кнопки).
    local cb_id
    cb_id=$(echo "$upd" | jq -r '.callback_query.id // empty' 2>/dev/null)
    if [ -n "$cb_id" ]; then
        local data chat mid from
        data=$(echo "$upd" | jq -r '.callback_query.data // empty')
        chat=$(echo "$upd" | jq -r '.callback_query.message.chat.id // empty')
        mid=$(echo "$upd" | jq -r '.callback_query.message.message_id // empty')
        from=$(echo "$upd" | jq -r '.callback_query.from.id // empty')
        # Ответ на нажатие даём ОДИН раз и в конце: Telegram принимает
        # answerCallbackQuery на запрос только однажды, а ответить хочется тем
        # текстом, который получился (всплывашка вместо лишнего сообщения в чат).
        # Ветка, которой есть что сказать, кладёт текст в CB_TEXT.
        local CB_TEXT=""
        [ -z "$chat" ] && { tg_answer_cb "$cb_id"; return 0; }
        case "$data" in
            wl:*)
                # Подтверждение входа в веб-версию: «wl:<ok|no>:<id запроса>».
                local wl="${data#wl:}"
                bot_weblogin_cb "$chat" "$from" "${mid:-0}" "${wl%%:*}" "${wl#*:}" ;;
            m:menu)   bot_client_menu "$chat" "$mid" ;;
            m:link)   bot_client_link "$chat" "$mid" ;;
            m:sub)
                local u; u=$(tg_bound_user "$chat")
                if [ -z "$u" ]; then bot_show "$chat" "$mid" "Аккаунт не привязан (/start КОД)." "$(bot_kb_client)"
                elif ! sub_enabled; then bot_show "$chat" "$mid" "Подписка на сервере не настроена — используйте «Моя ссылка»." "$(bot_kb_client)"
                else bot_show "$chat" "$mid" "📡 <b>Ссылка-подписка</b>:
<code>$(tg_esc "$(subscription_url "$u")")</code>" "$(bot_kb_client)"
                fi ;;
            m:status) bot_client_status "$chat" "$mid" ;;
            m:buy)    bot_buy_menu "$chat" "$mid" ;;
            buy:*)    bot_buy_dispatch "$chat" "${data#buy:}" "$mid" ;;
            ymchk:*)
                # Проверка оплаты ЮMoney по кнопке. Успех сам пришлёт карточку
                # доступа (bot_fulfill_payment) — здесь только исходы «нет/мало».
                bot_mod_on sales || { tg_answer_cb "$cb_id"; return 0; }
                local ym_rc=0
                ym_settle "${data#ymchk:}" >/dev/null 2>&1 || ym_rc=$?
                # Ответ на кнопку — всплывашкой поверх счёта, а не новым
                # сообщением: счёт остаётся один, история чата не растёт.
                case "$ym_rc" in
                    1) CB_TEXT="Оплата пока не найдена. Перевели только что — подождите минуту и нажмите ещё раз." ;;
                    2) CB_TEXT="Сумма меньше цены тарифа — администратор уведомлён и свяжется с вами." ;;
                esac ;;
            a:*)
                bot_mod_on admin || { tg_answer_cb "$cb_id"; return 0; }
                bot_is_admin "$from" || { tg_answer_cb "$cb_id" "⛔ Только для администратора"; return 0; }
                case "$data" in
                    a:menu)     tg_edit "$chat" "$mid" "🛠 <b>Админ-панель</b>" "$KB_ADMIN" ;;
                    a:users:*)  bot_admin_users "$chat" "${data##*:}" "$mid" ;;
                    a:u:*)      bot_admin_user_card "$chat" "${data#a:u:}" "$mid" ;;
                    a:stat)     bot_admin_server_status "$chat" "$mid" ;;
                    a:add)      bot_show "$chat" "$mid" "Добавить: <code>/add имя [дней] [устройств]</code>
Пример: <code>/add vasya 30 2</code>" "$KB_ADMIN" ;;
                    a:codehelp) bot_show "$chat" "$mid" "Код привязки: <code>/code имя</code> — бот выдаст одноразовый код, клиент отправит его боту командой /start КОД." "$KB_ADMIN" ;;
                    a:tariffs)
                        local tl
                        tl=$(tariff_list | while IFS='|' read -r c t d dv p cur _opts; do
                            read -r p cur <<< "$(tariff_prices_effective "$p" "$cur")"
                            [ -n "$c" ] && echo "• <code>$c</code> — $(tg_esc "$t"): ${d} дн., устройств ${dv}, $(tariff_price_str "$p" "$cur")"
                        done)
                        bot_show "$chat" "$mid" "💰 <b>Тарифы</b>
${tl:-нет тарифов}

Управление тарифами — в менеджере на сервере: Настройки → Telegram-бот → Тарифы." "$KB_ADMIN" ;;
                    a:tgl:*)
                        local u="${data#a:tgl:}"
                        if is_user_disabled "$u"; then enable_user "$u" >/dev/null 2>&1; else disable_user "$u" >/dev/null 2>&1; fi
                        declare -F cstate_mark >/dev/null && { is_user_disabled "$u" && cstate_mark "$u" disabled || cstate_mark "$u" active; }
                        bot_admin_user_card "$chat" "$u" "$mid" ;;
                    a:kick:*)
                        # Кик ничего не меняет на экране — отвечаем всплывашкой
                        # и оставляем карточку юзера как есть.
                        hy_kick_user "${data#a:kick:}" &>/dev/null
                        CB_TEXT="✂ Сессии сброшены" ;;
                    a:link:*)
                        local u="${data#a:link:}"
                        bot_show "$chat" "$mid" "$(bot_access_text "$u")" "$(bot_kb_back_user "$u")" ;;
                    a:sub:*)
                        local u="${data#a:sub:}"
                        if sub_enabled; then
                            bot_show "$chat" "$mid" "📡 <code>$(tg_esc "$(subscription_url "$u")")</code>" "$(bot_kb_back_user "$u")"
                        else
                            bot_show "$chat" "$mid" "Подписка не настроена." "$(bot_kb_back_user "$u")"
                        fi ;;
                    a:ext:*)
                        local rest="${data#a:ext:}" u days
                        u="${rest%%:*}"; days="${rest##*:}"
                        # Итог виден в самой карточке (строка «Срок») — отдельным
                        # сообщением его не дублируем, только всплывашка.
                        if [ "$days" = "0" ]; then
                            remove_user_expiry "$u"
                            CB_TEXT="Срок снят — доступ бессрочный"
                        else
                            local newd; newd=$(bot_extend_user "$u" "$days")
                            CB_TEXT="Продлено до ${newd:-?}"
                        fi
                        bot_admin_user_card "$chat" "$u" "$mid" ;;
                    a:code:*)
                        local u="${data#a:code:}" code botun
                        code=$(bot_bind_code "$u")
                        botun=$(bot_get BOT_USERNAME)
                        bot_show "$chat" "$mid" "🎫 Код привязки для <b>$(tg_esc "$u")</b> (действует 48 ч):
<code>${code}</code>
Клиент отправляет боту: <code>/start ${code}</code>${botun:+
Или по ссылке: https://t.me/${botun}?start=${code}}" "$(bot_kb_back_user "$u")" ;;
                    a:del:*)
                        local u="${data#a:del:}"
                        bot_show "$chat" "$mid" "Удалить <b>$(tg_esc "$u")</b> ПОЛНОСТЬЮ (ключи, статистика, привязки)?" \
                            "$(jq -nc --arg u "$u" '{inline_keyboard:[[{text:"🗑 Да, удалить",callback_data:("a:del2:"+$u)},{text:"Отмена",callback_data:("a:u:"+$u)}]]}')" ;;
                    a:del2:*)
                        local u="${data#a:del2:}" t
                        delete_user "$u" >/dev/null 2>&1
                        for t in $(tg_user_chats "$u"); do tg_unbind "$t"; done
                        bot_show "$chat" "$mid" "🗑 <b>$(tg_esc "$u")</b> удалён." \
                            '{"inline_keyboard":[[{"text":"↩ К списку","callback_data":"a:users:1"}]]}' ;;
                esac ;;
        esac
        tg_answer_cb "$cb_id" "$CB_TEXT"
        return 0
    fi

    # 3) обычное сообщение.
    local chat from text
    chat=$(echo "$upd" | jq -r '.message.chat.id // empty' 2>/dev/null)
    [ -z "$chat" ] && return 0
    from=$(echo "$upd" | jq -r '.message.from.id // empty')
    text=$(echo "$upd" | jq -r '.message.text // empty')

    # 3-DM) чат прямых сообщений канала (Direct Messages in Channels, Bot API 9.2):
    # запоминаем topic пользователя, чтобы слать уведомления «от лица канала».
    # Не прерываемся — обычные команды тоже могут приходить отсюда.
    if [ "$(echo "$upd" | jq -r '.message.chat.is_direct_messages // false' 2>/dev/null)" = "true" ]; then
        local dm_uid dm_topic
        dm_uid=$(echo "$upd" | jq -r '.message.direct_messages_topic.user.id // empty')
        dm_topic=$(echo "$upd" | jq -r '.message.direct_messages_topic.topic_id // empty')
        [ -n "$dm_uid" ] && [ -n "$dm_topic" ] && declare -F chandm_topic_set >/dev/null \
            && chandm_topic_set "$dm_uid" "$chat" "$dm_topic"
    fi

    # 3а) успешная оплата.
    local sp
    sp=$(echo "$upd" | jq -r '.message.successful_payment.invoice_payload // empty' 2>/dev/null)
    if [ -n "$sp" ]; then
        local amount cur charge
        amount=$(echo "$upd" | jq -r '.message.successful_payment.total_amount // 0')
        cur=$(echo "$upd" | jq -r '.message.successful_payment.currency // ""')
        charge=$(echo "$upd" | jq -r '.message.successful_payment.telegram_payment_charge_id // ""')
        bot_fulfill_payment "$chat" "$from" "$sp" "$amount" "$cur" "$charge" \
            "$(echo "$upd" | jq -r '.message.from.username // empty')"
        return 0
    fi

    case "$text" in
        /start|/start@*)
            if bot_is_admin "$from"; then
                tg_send "$chat" "🛠 <b>Админ-панель</b>
Команды: /add имя [дней] [устройств] · /code имя · /users · /status_srv" "$KB_ADMIN"
            else
                # Приветствие с кнопкой «Открыть приложение» шлёт мини-апп;
                # своё меню — только если он не настроен/не ответил.
                bot_miniapp_start "$chat" "$from" "" "$(echo "$upd" | jq -r '.message.from.username // empty')" \
                    "$(echo "$upd" | jq -r '.message.from.first_name // empty')" \
                    || bot_client_menu "$chat"
            fi ;;
        "/start "*)
            local code="${text#/start }" u
            code=$(printf '%s' "$code" | tr -d '[:space:]')
            # ref_<КОД> — реферальная ссылка мини-аппа (не код привязки);
            # wl_<id> — подтверждение входа в веб-версию (карточку шлёт мини-апп).
            if [ "${code#ref_}" != "$code" ] || [ "${code#wl_}" != "$code" ]; then
                bot_miniapp_start "$chat" "$from" "$code" "$(echo "$upd" | jq -r '.message.from.username // empty')" \
                    "$(echo "$upd" | jq -r '.message.from.first_name // empty')" \
                    || bot_client_menu "$chat"
                return 0
            fi
            u=$(bot_code_lookup "$code")
            if [ -n "$u" ]; then
                tg_bind "$from" "$u"
                tg_send "$chat" "✅ Аккаунт <b>$(tg_esc "$u")</b> привязан к вашему Telegram!" "$(bot_kb_client)"
                bot_notify_admins "🔗 tg:$from привязал аккаунт $(tg_esc "$u")"
            else
                tg_send "$chat" "❌ Код неверен или истёк. Запросите новый у администратора."
                bot_client_menu "$chat"
            fi ;;
        "/web "*|"/web@"*|"/веб "*|"/сайт "*)
            # Вход на сайт кодом, набранным руками: Telegram у человека может
            # стоять вообще на другом устройстве, где кнопка-deeplink не
            # открывается. Дальше всё как у deeplink — карточку подтверждения
            # шлёт мини-апп. См. надстройка/docs/WEB-LOGIN.md.
            local wcode
            # Всё после первого слова: «/web@бот КОД» и «/web  код» тоже валидны.
            wcode=$(printf '%s' "$text" | sed 's/^[^[:space:]]*[[:space:]]*//' | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
            if [ -z "$wcode" ]; then
                tg_send "$chat" "Отправьте код со страницы входа: <code>/web КОД</code>"
            else
                bot_miniapp_start "$chat" "$from" "wl_${wcode}" \
                    "$(echo "$upd" | jq -r '.message.from.username // empty')" \
                    "$(echo "$upd" | jq -r '.message.from.first_name // empty')" \
                    || tg_send "$chat" "Не получилось проверить код — попробуйте ещё раз через минуту."
            fi ;;
        /web|/веб|/сайт)
            # Адрес сайта — из bot.conf (MINIAPP_WEB_URL), а не константой: у
            # каждого, кто поднял менеджер, он свой. Не задан — объясняем схему
            # без адреса.
            local wurl; wurl=$(bot_get MINIAPP_WEB_URL)
            tg_send "$chat" "🌐 Вход на сайт: ${wurl:+откройте <b>$(tg_esc "$wurl")</b>, }возьмите код со страницы входа и пришлите его сюда командой <code>/web КОД</code>." ;;
        /menu|/help)
            if bot_is_admin "$from"; then
                tg_send "$chat" "🛠 <b>Команды администратора</b>
/users — список пользователей
/add имя [дней] [устройств] — создать
/code имя — код привязки Telegram
/status_srv — состояние сервера
/refund tg_id charge_id — возврат Stars

Клиентские: /link /sub /status /buy /id" "$KB_ADMIN"
            else
                bot_client_menu "$chat"
            fi ;;
        /id) tg_send "$chat" "Ваш chat ID: <code>$chat</code>" ;;
        /link) bot_client_link "$chat" ;;
        /sub)
            local u; u=$(tg_bound_user "$chat")
            if [ -z "$u" ]; then tg_send "$chat" "Аккаунт не привязан (/start КОД)."
            elif ! sub_enabled; then tg_send "$chat" "Подписка на сервере не настроена — используйте /link."
            else tg_send "$chat" "📡 <code>$(tg_esc "$(subscription_url "$u")")</code>"; fi ;;
        /status) bot_client_status "$chat" ;;
        /buy) bot_buy_menu "$chat" ;;
        /users|/users@*)
            bot_is_admin "$from" && bot_admin_users "$chat" 1 || bot_client_menu "$chat" ;;
        /status_srv)
            bot_is_admin "$from" && bot_admin_server_status "$chat" ;;
        "/add "*)
            bot_is_admin "$from" || return 0
            local args u days dev
            # read -ra, а не args=($…): иначе «/add *» раскрылось бы как glob.
            read -ra args <<< "${text#/add }"
            u="${args[0]:-}"; days="${args[1]:-0}"; dev="${args[2]:-0}"
            if [[ ! "$u" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                tg_send "$chat" "❌ Имя: латиница/цифры/_/-"
            elif db_user_exists "$u" || is_user_disabled "$u"; then
                tg_send "$chat" "❌ $(tg_esc "$u") уже существует."
            elif ! bot_provision_user "$u" >/dev/null; then
                tg_send "$chat" "❌ Не удалось создать пользователя (см. логи бота)."
            else
                local extra=""
                if [[ "$days" =~ ^[0-9]+$ ]] && [ "$days" -gt 0 ]; then
                    extra=" · до $(bot_extend_user "$u" "$days")"
                fi
                if [[ "$dev" =~ ^[0-9]+$ ]] && [ "$dev" -gt 0 ]; then
                    set_user_devices "$u" "$dev"; extra="$extra · устройств: $dev"
                fi
                write_authlimits 2>/dev/null
                sub_enabled && sub_refresh >/dev/null 2>&1
                tg_send "$chat" "✅ Пользователь <b>$(tg_esc "$u")</b> создан${extra}.

$(bot_access_text "$u")"
            fi ;;
        "/code "*)
            bot_is_admin "$from" || return 0
            local u="${text#/code }" code botun
            u=$(printf '%s' "$u" | tr -d '[:space:]')
            if ! db_user_exists "$u" && ! is_user_disabled "$u"; then
                tg_send "$chat" "❌ Пользователь $(tg_esc "$u") не найден."
            else
                code=$(bot_bind_code "$u")
                botun=$(bot_get BOT_USERNAME)
                tg_send "$chat" "🎫 Код для <b>$(tg_esc "$u")</b> (48 ч): <code>${code}</code>
Клиент отправляет боту: <code>/start ${code}</code>${botun:+
Ссылка: https://t.me/${botun}?start=${code}}"
            fi ;;
        "/refund "*)
            bot_is_admin "$from" || return 0
            local args; read -ra args <<< "${text#/refund }"
            local r
            r=$(tg_api refundStarPayment --data-urlencode "user_id=${args[0]}" \
                --data-urlencode "telegram_payment_charge_id=${args[1]}")
            if [ "$(echo "$r" | jq -r '.ok' 2>/dev/null)" = "true" ]; then
                tg_send "$chat" "✅ Возврат Stars выполнен."
            else
                tg_send "$chat" "❌ Возврат не прошёл: $(tg_esc "$(echo "$r" | jq -r '.description // "нет ответа"' 2>/dev/null)")"
            fi ;;
        "")
            : ;;   # стикеры/фото и т.п. — игнор
        *)
            if bot_is_admin "$from"; then
                tg_send "$chat" "Не понял. /help — список команд."
            else
                bot_client_menu "$chat"
            fi ;;
    esac
    return 0
}

# ---------- демон ----------
tgbot_daemon() {
    BOT_TOKEN=$(bot_token)
    if [ -z "$BOT_TOKEN" ]; then
        echo "BOT_TOKEN не задан (Настройки → Telegram-бот)" >&2
        exit 1
    fi
    mkdir -p "$LOG_DIR" 2>/dev/null
    exec >>"$BOT_LOG" 2>&1
    echo "$(date '+%F %T') ── bot daemon start (pid $$)"

    # Запомним username бота (для deep-link кодов привязки).
    local me un
    me=$(tg_api getMe)
    un=$(echo "$me" | jq -r '.result.username // empty' 2>/dev/null)
    [ -n "$un" ] && bot_set BOT_USERNAME "$un"

    local off resp uid
    off=$(cat "$BOT_OFFSET_FILE" 2>/dev/null); [[ "$off" =~ ^[0-9]+$ ]] || off=0
    while :; do
        resp=$(tg_api getUpdates --data-urlencode "timeout=50" --data-urlencode "offset=$off" \
            --data-urlencode 'allowed_updates=["message","callback_query","pre_checkout_query"]')
        if [ -z "$resp" ] || [ "$(echo "$resp" | jq -r '.ok' 2>/dev/null)" != "true" ]; then
            echo "$(date '+%F %T') getUpdates: нет ответа/ошибка: $(echo "$resp" | jq -r '.description // "timeout"' 2>/dev/null)"
            sleep 3
            continue
        fi
        while IFS= read -r upd; do
            [ -n "$upd" ] || continue
            uid=$(echo "$upd" | jq -r '.update_id // empty' 2>/dev/null)
            [[ "$uid" =~ ^[0-9]+$ ]] && { off=$((uid + 1)); echo "$off" > "$BOT_OFFSET_FILE"; }
            bot_handle_update "$upd" || echo "$(date '+%F %T') ошибка обработчика: $(echo "$upd" | jq -c '{id:.update_id}' 2>/dev/null)"
        done < <(echo "$resp" | jq -c '.result[]?' 2>/dev/null)
        # Не даём логу расти бесконечно (~1 МБ потолок).
        if [ "$(stat -c %s "$BOT_LOG" 2>/dev/null || echo 0)" -gt 1048576 ]; then
            tail -c 262144 "$BOT_LOG" > "${BOT_LOG}.tmp.$BASHPID" 2>/dev/null && mv "${BOT_LOG}.tmp.$BASHPID" "$BOT_LOG"
        fi
    done
}

# Уведомление об автоотключении (зовётся из check_expired_users через хук).
bot_notify_expired() {   # user
    bot_enabled || return 0
    bot_mod_on notify || return 0
    BOT_TOKEN=$(bot_token); [ -n "$BOT_TOKEN" ] || return 0
    local user="$1" c
    for c in $(tg_user_chats "$user"); do
        tg_send "$c" "⛔ Срок действия вашего доступа (<b>$(tg_esc "$user")</b>) истёк — доступ отключён.$( bot_sales_on && echo "
Продлить и включить снова: /buy" )"
    done
    bot_notify_admins "⏰ Автоотключение по сроку: $(tg_esc "$user")"
}

# ---------- бесплатный тариф (lib/freeplan.sh) ----------
# Единая отправка клиенту: у бесплатного тарифа четыре события — перевод,
# «осталось немного» (три порога), исчерпание и обновление лимита.
_bot_free_send() {   # user html
    bot_enabled || return 0
    bot_mod_on notify || return 0
    BOT_TOKEN=$(bot_token); [ -n "$BOT_TOKEN" ] || return 0
    local c
    for c in $(tg_user_chats "$1"); do tg_send "$c" "$2"; done
}

bot_notify_free_entered() {   # user
    _bot_free_send "$1" "🆓 Платный доступ закончился — вы переведены на <b>бесплатный тариф</b>.
Интернет продолжает работать в пределах лимита трафика; лимит обновляется автоматически.
Вернуть полную скорость и объём: /buy"
}

bot_notify_free_low() {   # user left_bytes
    _bot_free_send "$1" "⚠️ Бесплатный трафик заканчивается: осталось <b>$(format_bytes "$2")</b>.
Когда закончится — доступ приостановится до обновления лимита. Продлить: /buy"
}

bot_notify_free_blocked() {   # user reset_ts
    _bot_free_send "$1" "⛔ Бесплатный трафик закончился — доступ приостановлен.
Лимит обновится: <b>$(date -d "@$2" '+%d.%m %H:%M' 2>/dev/null)</b>.
Не ждать и подключиться сразу: /buy"
}

bot_notify_free_reset() {   # user left_bytes
    _bot_free_send "$1" "✅ Лимит бесплатного тарифа обновлён — доступ снова работает.
Доступно: <b>$(format_bytes "$2")</b>."
}

