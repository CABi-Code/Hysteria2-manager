#!/usr/bin/env bash
# lib/notify.sh — уведомления пользователям в Telegram: активация/продление
# подписки, ступенчатые напоминания об истечении, доставка «от лица канала»
# (Direct Messages in Channels, Bot API 9.2). Кастомные эмодзи из набора
# AdaptivePixelEmoji с фолбэком на обычные. Зависит от lib/tgbot.sh (tg_api,
# tg_send, tg_user_chats, bot_token, bot_enabled) и lib/expiry.sh.

# ---------- пути данных ----------
PERIOD_FILE="$DATA_DIR/period_days.dat"          # user|days — длина текущего периода
NOTIFY_STATE_FILE="$DATA_DIR/notify_state.dat"   # анти-дубли: user|end_ts|label
CHANDM_MAP_FILE="$DATA_DIR/chandm_map.dat"        # tg_id|dm_chat_id|topic_id (канал-DM)

# ---------- кастомные эмодзи (AdaptivePixelEmoji, id стабильны) ----------
# base_emoji -> custom_emoji_id. Нет в карте → отправим обычный юникод.
declare -A CE_MAP=(
    ["⭐"]=5460980668378931880
    ["💵"]=5372874186010158207
    ["🪙"]=5318972874726339331
    ["⌛"]=5296482716567495148
    ["🔔"]=5373136788900571050
    ["❗️"]=5258382581375723416
    ["🎁"]=5235695112419303615
    ["💬"]=5296258510684712098
    ["🚫"]=5339428493992162714
)

# ce «⭐» → <tg-emoji emoji-id="…">⭐</tg-emoji> (для parse_mode=HTML) либо просто «⭐».
ce() {
    local e="$1" id="${CE_MAP[$1]:-}"
    if [ -n "$id" ]; then
        printf '<tg-emoji emoji-id="%s">%s</tg-emoji>' "$id" "$e"
    else
        printf '%s' "$e"
    fi
}

# Y-m-d → d.m.Y (как в примере пользователя: 14.01.2027). Пусто на входе — пусто.
fmt_date_dmy() { [ -n "$1" ] && date -d "$1" +%d.%m.%Y 2>/dev/null || printf '%s' "$1"; }

# @username бота (кэшируем в bot.conf, иначе getMe).
bot_username() {
    local u; u=$(bot_get BOT_USERNAME)
    if [ -z "$u" ]; then
        BOT_TOKEN=${BOT_TOKEN:-$(bot_token)}
        u=$(tg_api getMe | grep -oP '"username":"\K[^"]+' | head -1)
        [ -n "$u" ] && bot_set BOT_USERNAME "$u"
    fi
    printf '%s' "$u"
}

# ---------- длина периода (для порогов «за 7 дней/за 1 день») ----------
period_days_set() {   # user days
    [ -n "$1" ] && [ -n "$2" ] || return 0
    touch "$PERIOD_FILE" 2>/dev/null
    sed -i "/^${1}|/d" "$PERIOD_FILE" 2>/dev/null
    printf '%s|%s\n' "$1" "$2" >> "$PERIOD_FILE"
}
period_days_get() {   # user -> days (0 если нет)
    local d; d=$(fld_by_key "$PERIOD_FILE" "$1" 2)
    [[ "$d" =~ ^[0-9]+$ ]] && printf '%s' "$d" || printf '0'
}

# ---------- доставка: личка бота + (best-effort) канал-DM ----------
# Личные копии идут от бота как есть; канальная копия получает пометку «перейти
# в бота». chandm работает только если у нас есть topic для этого пользователя
# (он уже писал в чат канала) и бот — админ канала с can_post_messages.
notify_user() {   # user  html_text
    local user="$1" text="$2" c
    bot_enabled || return 0
    # Модуль notify (lib/tgbot.sh): выключается отдельно от продажи — надстройка
    # со своими уведомлениями глушит бота, не теряя привязку и фулфилмент.
    bot_mod_on notify || return 0
    BOT_TOKEN=${BOT_TOKEN:-$(bot_token)}; [ -n "$BOT_TOKEN" ] || return 0
    for c in $(tg_user_chats "$user"); do
        [ -n "$c" ] || continue
        tg_send "$c" "$text"
        chandm_send "$c" "$text"
    done
}

# Отправить копию «от лица канала» в персональный топик пользователя, добавив
# рекомендацию перейти в бота. tg_id → (dm_chat_id, topic_id) из CHANDM_MAP_FILE.
chandm_send() {   # tg_id  html_text
    local tgid="$1" text="$2" row dm topic bu note
    [ -f "$CHANDM_MAP_FILE" ] || return 0
    row=$(awk -F'|' -v id="$tgid" '$1==id{print; exit}' "$CHANDM_MAP_FILE" 2>/dev/null)
    [ -n "$row" ] || return 0
    dm=$(printf '%s' "$row" | cut -d'|' -f2)
    topic=$(printf '%s' "$row" | cut -d'|' -f3)
    [ -n "$dm" ] && [ -n "$topic" ] || return 0
    bu=$(bot_username)
    note="

$(ce "💬") Управляйте подпиской в боте${bu:+: @$bu}"
    tg_api sendMessage \
        --data-urlencode "chat_id=$dm" \
        --data-urlencode "direct_messages_topic_id=$topic" \
        --data-urlencode "parse_mode=HTML" \
        --data-urlencode "disable_web_page_preview=true" \
        --data-urlencode "text=${text}${note}" >/dev/null 2>&1
}

# Запомнить топик прямых сообщений канала для пользователя (зовётся из update-loop
# при входящем сообщении, где message.chat.is_direct_messages=true).
chandm_topic_set() {   # tg_id dm_chat_id topic_id
    [ -n "$1" ] && [ -n "$2" ] && [ -n "$3" ] || return 0
    # 600, а не 644: внутри tg_id↔chat_id канала. Каталог и так закрыт от чужих
    # (drwxr-x--- hysteria), но ядру Hysteria эта карта не нужна — пусть не видит.
    touch "$CHANDM_MAP_FILE" 2>/dev/null; chmod 600 "$CHANDM_MAP_FILE" 2>/dev/null
    sed -i "/^${1}|/d" "$CHANDM_MAP_FILE" 2>/dev/null
    printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$CHANDM_MAP_FILE"
}

# ---------- активация/продление подписки ----------
# Зовётся из bot_extend_user для ВСЕХ путей продления (бот-оплата, Laravel/webapi,
# админ). Прямой Stars-платёж шлёт свою расширенную карточку → там notify=nonotify.
bot_notify_activated() {   # user expiry_ymd
    bot_enabled || return 0
    local user="$1" exp="$2" dmy
    [ -n "$user" ] || return 0
    dmy=$(fmt_date_dmy "$exp")
    notify_user "$user" "$(ce "⭐") <b>Подписка активна</b>
Ваша подписка действует до <b>${dmy:-без срока}</b>."
}

# ---------- ступенчатые напоминания об истечении ----------
# Пороги: за 7д (если период >8д), 3д, 1д (если период >2д), 12ч, 1ч, 30мин.
# Дедуп по (user|end_ts|label) — новая покупка меняет end_ts и сбрасывает пороги.
# Гонять из cron часто (каждые ~5 мин), иначе поймать 30мин/1ч нельзя.
bot_notify_sweep() {
    bot_enabled || return 0
    BOT_TOKEN=$(bot_token); [ -n "$BOT_TOKEN" ] || return 0
    [ -f "$EXPIRY_FILE" ] || return 0
    touch "$NOTIFY_STATE_FILE"
    # Один sweep за раз: проверка порога и отметка в notify_state.dat не атомарны
    # (читаем «не отправлено» → шлём → дописываем метку), а cleanup ниже
    # перезаписывает файл целиком. Два параллельных прохода без блокировки слали
    # напоминание дважды и затирали метки друг друга. flock -n: если проход уже
    # идёт, молча выходим — он всех обойдёт.
    { exec 8>"$DATA_DIR/.notify_sweep.lock"; } 2>/dev/null || true
    flock -n 8 2>/dev/null || return 0
    local now user exp end_ts left pdays label secs bu
    now=$(date +%s)
    bu=$(bot_username)

    # Пороги: «label secs» по убыванию. Гейты 7д/1д — по длине периода (в днях).
    while IFS='|' read -r user exp; do
        [ -n "$user" ] && [ -n "$exp" ] || continue
        end_ts=$(date -d "$exp 23:59:59" +%s 2>/dev/null) || continue
        left=$(( end_ts - now ))
        [ "$left" -gt 0 ] || continue          # уже истёк — этим займётся check_expired_users
        pdays=$(period_days_get "$user")

        # Идём от крупного порога к мелкому. Собираем ВСЕ пройденные и прошедшие
        # гейт пороги (crossed); шлём ОДНО сообщение — за самый срочный ещё не
        # отправленный порог, а все пройденные молча помечаем отправленными.
        # Так исключаем «пачку» (7д+3д+1д разом) при первом проходе на дозревшей
        # подписке: одно напоминание на каждый переход через порог.
        local crossed="" have_new=""
        for pair in "7d:604800" "3d:259200" "1d:86400" "12h:43200" "1h:3600" "30m:1800"; do
            label="${pair%%:*}"; secs="${pair##*:}"
            [ "$left" -le "$secs" ] || continue         # порог ещё не пройден
            case "$label" in                            # гейты по длине периода
                7d) [ "$pdays" -gt 8 ] 2>/dev/null || continue ;;
                3d) [ "$pdays" -ge 3 ] 2>/dev/null || continue ;;
                1d) [ "$pdays" -gt 2 ] 2>/dev/null || continue ;;
            esac
            crossed="$crossed $label"
            grep -qxF "${user}|${end_ts}|${label}" "$NOTIFY_STATE_FILE" 2>/dev/null || have_new=1
        done
        [ -n "$crossed" ] || continue
        # Отправляем только если появился новый (ещё не отправленный) порог.
        if [ -n "$have_new" ]; then
            notify_user "$user" "$(ce "⭐") <b>Подписка скоро закончится</b>
Действует до <b>$(fmt_date_dmy "$exp")</b> — осталось $(format_remaining "$exp").
Продлите заранее, чтобы не потерять доступ${bu:+ — /buy}."
        fi
        # Помечаем отправленными ВСЕ пройденные пороги (в т.ч. более крупные —
        # чтобы они не «выстрелили» задним числом на следующих проходах).
        for label in $crossed; do
            grep -qxF "${user}|${end_ts}|${label}" "$NOTIFY_STATE_FILE" 2>/dev/null \
                || echo "${user}|${end_ts}|${label}" >> "$NOTIFY_STATE_FILE"
        done
    done < "$EXPIRY_FILE"

    # Подчистка: выкидываем метки для уже истёкших end_ts (в прошлом).
    local tmp; tmp=$(mktemp 2>/dev/null)
    if [ -n "$tmp" ]; then
        awk -F'|' -v now="$now" '$2+0>now' "$NOTIFY_STATE_FILE" > "$tmp" 2>/dev/null
        cat "$tmp" > "$NOTIFY_STATE_FILE"; rm -f "$tmp"
    fi

    # Отпускаем лок сразу (а не с завершением процесса): иначе в одном
    # долгоживущем шелле — демон, тесты — второй проход навсегда бы блокировался.
    flock -u 8 2>/dev/null; { exec 8>&-; } 2>/dev/null
}
