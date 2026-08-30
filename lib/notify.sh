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

# ---------- доставка: ОДИН канал на человека ----------
# Приоритет — личка бота: она интерактивна (кнопки, мини-апп), директ канала
# такого не умеет. В директ уходит только то, что в личку не прошло: человек не
# начинал диалог с ботом или заблокировал его (tg_send вернёт 1). Раньше слали в
# оба — клиент с двумя чатами получал каждое уведомление дважды.
# chandm работает только если у нас есть topic для этого пользователя (он уже
# писал в чат канала) и бот — админ канала с can_post_messages.
notify_user() {   # user  html_text  [kb_json]  [channel_cta_html]
    local user="$1" text="$2" kb="$3" cta="$4" c
    bot_enabled || return 0
    # Модуль notify (lib/tgbot.sh): выключается отдельно от продажи — надстройка
    # со своими уведомлениями глушит бота, не теряя привязку и фулфилмент.
    bot_mod_on notify || return 0
    BOT_TOKEN=${BOT_TOKEN:-$(bot_token)}; [ -n "$BOT_TOKEN" ] || return 0
    for c in $(tg_user_chats "$user"); do
        [ -n "$c" ] || continue
        tg_send "$c" "$text" "$kb" || chandm_send "$c" "$text" "$cta"
    done
}

# Отправить «от лица канала» в персональный топик пользователя, добавив призыв
# перейти в бота (кнопок в директе канала нет — только ссылка текстом).
# tg_id → (dm_chat_id, topic_id) из CHANDM_MAP_FILE.
chandm_send() {   # tg_id  html_text  [cta_html]
    local tgid="$1" text="$2" cta="$3" row dm topic bu note
    [ -f "$CHANDM_MAP_FILE" ] || return 0
    row=$(awk -F'|' -v id="$tgid" '$1==id{print; exit}' "$CHANDM_MAP_FILE" 2>/dev/null)
    [ -n "$row" ] || return 0
    dm=$(printf '%s' "$row" | cut -d'|' -f2)
    topic=$(printf '%s' "$row" | cut -d'|' -f3)
    [ -n "$dm" ] && [ -n "$topic" ] || return 0
    bu=$(bot_username)
    note="

${cta:-$(ce "💬") Управляйте подпиской в боте${bu:+: https://t.me/$bu}}"
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

# ---------- куда идти продлевать ----------
# Ссылка на мини-апп (MINIAPP_URL в bot.conf = https://t.me/<бот>/<апп>) с
# ?startapp=<экран>. Пусто — мини-апп не настроен, зовущий обходится без него.
miniapp_screen_url() {   # screen
    local app; app=$(bot_get MINIAPP_URL)
    [ -n "$app" ] || return 1
    printf '%s?startapp=%s' "${app%/}" "$1"
}

# Кнопки под напоминанием (только личка бота: в директе канала кнопок нет).
# Мини-апп есть → ведём прямо на тарифы и баланс; нет, но бот продаёт сам →
# его витрина; ни того ни другого → без клавиатуры.
bot_renew_kb() {
    local t b
    if t=$(miniapp_screen_url tariffs); then
        b=$(miniapp_screen_url balance)
        jq -nc --arg t "$t" --arg b "$b" \
            '{inline_keyboard:[[{text:"💳 Продлить подписку",url:$t}],[{text:"💰 Пополнить баланс",url:$b}]]}'
    elif bot_sales_on; then
        printf '%s' '{"inline_keyboard":[[{"text":"💳 Купить / продлить","callback_data":"m:buy"}]]}'
    fi
}

# То же для директа канала: команду там не наберёшь и мини-апп по ссылке не
# откроется (баг Telegram) — только ссылка на /start бота с параметром экрана.
# Бот, получив «/start tariffs», откроет тарифы (lib/tgbot_daemon.sh).
bot_renew_link() {
    local bu; bu=$(bot_username)
    [ -n "$bu" ] || return 0
    printf '%s Продлить: https://t.me/%s?start=tariffs' "$(ce "⭐")" "$bu"
}

# ---------- чужое устройство в подписке ----------
# Разбор темы — docs/guide/SUB-ALERTS.md. Здесь коротко о трёх правилах, потому
# что нарушить их легко, а стоит это доверия к каждому следующему уведомлению.
#
# 1. Тревожим ТОЛЬКО по опознанным устройствам (`X-Hwid`). Клиент, не приславший
#    его (Hiddify, v2rayNG, браузер, бот предпросмотра ссылки), неотличим от
#    любого другого такого же — сказать «это новое устройство» про него нельзя
#    честно. Молчим: пропущенная утечка дешевле обвинения в пустоту.
# 2. Одно сообщение на устройство НАВСЕГДА (SUBAPPS_SEEN_FILE). Подписка
#    обновляется раз в час у всех — без отметки то же самое устройство поднимало
#    бы тревогу 24 раза в сутки. Отметка ставится ДО отправки: сбой доставки не
#    должен превращаться в вечный цикл попыток.
# 3. Тревога — только когда устройств БОЛЬШЕ, чем оплачено. Второй телефон
#    человека, купившего два устройства, — не чужой.
#
# Уровень «новое приложение» (ниже, _newapp_check_user) правило 1 сознательно
# ослабляет: тревожит и по неопознанным клиентам. Он поэтому и не обвиняет —
# сообщает факт и объясняет, чем опасна общая ссылка. Правила 2 и 4 держат
# частоту: одно сообщение на приложение навсегда плюс свой суточный кулдаун.
FOREIGN_COOLDOWN_SEC="${FOREIGN_COOLDOWN_SEC:-86400}"   # не чаще раза в сутки на человека
NEWAPP_COOLDOWN_SEC="${NEWAPP_COOLDOWN_SEC:-86400}"     # свой кулдаун у мягкого уровня
FOREIGN_LIST_MAX="${FOREIGN_LIST_MAX:-10}"              # сколько устройств перечислять в сообщении
SUBAPPS_SEEN_KEEP_DAYS="${SUBAPPS_SEEN_KEEP_DAYS:-30}"

# Кнопки под уведомлением об утечке. «Свои устройства» ведут на экран подписки:
# там и список ссылок, и перевыпуск — отдельной кнопки «сбросить» не нужно,
# сброс живёт на том же экране. «Купить устройство» — на витрину: устройства
# докупаются там же, где срок. Третьей строкой статья, если оператор её завёл
# (SUB_DEVICES_URL): объяснять устройство лимита внутри сообщения негде.
bot_subscription_kb() {
    local s t a p rows
    s=$(miniapp_screen_url subscription) || return 0
    t=$(miniapp_screen_url tariffs)
    a=$(sub_devices_url 2>/dev/null)
    p=$(miniapp_screen_url privacy)
    rows=$(jq -nc --arg s "$s" '[[{text:"📱 Свои устройства",url:$s}]]')
    [ -n "$t" ] && rows=$(jq -nc --argjson r "$rows" --arg t "$t" \
        '$r + [[{text:"➕ Купить устройство",url:$t}]]')
    [ -n "$a" ] && rows=$(jq -nc --argjson r "$rows" --arg a "$a" \
        '$r + [[{text:"📄 Почему у каждого своя ссылка",url:$a}]]')
    # Человеку, которому только что перечислили его приложения, нужен ответ
    # «а что вы вообще обо мне храните» в один тап. Ведёт в «Помощь»,
    # раскрытую на политике конфиденциальности.
    [ -n "$p" ] && rows=$(jq -nc --argjson r "$rows" --arg p "$p" \
        '$r + [[{text:"🔒 Какие данные мы храним",url:$p}]]')
    jq -nc --argjson r "$rows" '{inline_keyboard:$r}'
}
# То же для директа канала: кнопок там нет вовсе, только ссылки текстом.
bot_subscription_link() {
    local bu; bu=$(bot_username)
    [ -n "$bu" ] || return 0
    printf '%s Свои устройства: https://t.me/%s?start=subscription\n%s Купить устройство: https://t.me/%s?start=tariffs' \
        "$(ce "🚫")" "$bu" "$(ce "⭐")" "$bu"
}

# Строка со ссылкой на статью в теле сообщения. Кнопки видны только в личке
# бота, а в директе канала их нет вовсе — там эта строка и остаётся
# единственным способом дочитать объяснение.
_devices_article_line() {
    local a; a=$(sub_devices_url 2>/dev/null)
    [ -n "$a" ] || return 0
    printf '\n\nПодробнее — <a href="%s">как устроены устройства</a>.' "$a"
}

# Отметка «об этом устройстве уже писали»: «основной_токен|hwid|ts».
# Ключ — ОСНОВНОЙ токен человека, а не тот, по которому пришли: одно устройство
# может качать подписку по двум его ссылкам, и это всё равно одно устройство.
# Строка начинается с токена, поэтому erase_user стирает её своим обходом
# DATA_DIR — отдельный список файлов не нужен (docs/guide/DATA-RETENTION.md).
_seen_has() {   # primary hwid
    grep -qF "$1|$2|" "$SUBAPPS_SEEN_FILE" 2>/dev/null
}
_seen_add() {   # primary hwid ts
    _seen_has "$1" "$2" || printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$SUBAPPS_SEEN_FILE"
}

# Первый взгляд на человека: всё, что у него уже есть, — не новость. Без этого
# первый же прогон после обновления разослал бы тревогу вообще всем.
#
# Гейт ОБЩИЙ для обоих уровней и стоит ДО них: уровни делят один файл отметок,
# и если бы каждый заводил человека сам, первый пометил бы токен своими ключами,
# а второй увидел бы токен уже знакомым и выстрелил по всем своим ключам сразу.
# Поэтому метим все ключи разом — и опознанные устройства, и приложения.
# Возврат 0 = «человека только что завели, тревожить нечем».
_seen_prime_user() {   # user now
    local user="$1" now="$2" primary apps key
    primary=$(sub_token_for "$user" 2>/dev/null) || return 1
    [ -n "$primary" ] || return 1
    grep -qF "$primary|" "$SUBAPPS_SEEN_FILE" 2>/dev/null && return 1

    apps=$(get_user_apps "$user" 2>/dev/null) || return 1
    [ -n "$apps" ] || return 1
    while IFS='|' read -r key _rest; do
        [ -n "$key" ] && _seen_add "$primary" "$key" "$now"
    done <<< "$apps"
    return 0
}

# Возврат обоих уровней: 0 — сообщение УШЛО, 1 — тревожить было не о чем.
# Обход в notify_foreign_devices на этом и построен: отправил резкий уровень —
# мягкий в тот же прогон уже не зовём. Если бы «ничего не нашёл» тоже был нулём,
# мягкий уровень не выполнялся бы никогда.
_foreign_check_user() {   # user now → 0 если отправили
    local user="$1" now="$2" allowed primary apps ids count new_line="" new_count=0 cool="" list=""
    allowed=$(get_user_devices "$user" 2>/dev/null)
    # Безлимит — тревожить не о чем: «больше, чем оплачено» недостижимо.
    [ "${allowed:-0}" -gt 0 ] 2>/dev/null || return 1
    primary=$(sub_token_for "$user" 2>/dev/null) || return 1
    [ -n "$primary" ] || return 1

    apps=$(get_user_apps "$user" 2>/dev/null) || return 1
    [ -n "$apps" ] || return 1
    # Только опознанные: «~…» это не устройство, а «кто-то с таким приложением».
    ids=$(printf '%s\n' "$apps" | awk -F'|' '$1 !~ /^~/ && $1 != "" { print }')
    [ -n "$ids" ] || return 1
    count=$(printf '%s\n' "$ids" | wc -l)

    # Показываем ВЕСЬ список опознанных устройств, а не только новое: человек
    # решает, свои они или чужие, а для этого ему надо видеть их рядом. Порядок
    # — как отдал get_user_apps, самое свежее первым. Список режем по
    # FOREIGN_LIST_MAX: утёкшая в общий чат ссылка даёт десятки строк, а в
    # сообщение Telegram влезает 4096 символов.
    local hwid app ver os model _first _last _cnt line shown=0
    while IFS='|' read -r hwid app ver os model _first _last _cnt; do
        line="${model:-${os:-Неизвестное устройство}} · ${os:-—} · ${app:-—}${ver:+ $ver}"
        if ! _seen_has "$primary" "$hwid"; then
            _seen_add "$primary" "$hwid" "$now"
            new_count=$(( new_count + 1 ))
            line="$line — новое"
            [ -n "$new_line" ] || new_line="$line"
        fi
        if [ "$shown" -lt "$FOREIGN_LIST_MAX" ]; then
            list="${list}
📱 <b>${line}</b>"
            shown=$(( shown + 1 ))
        fi
    done <<< "$ids"
    [ "$count" -gt "$shown" ] && list="${list}
… и ещё $(( count - shown ))"

    [ "$new_count" -gt 0 ] || return 1
    # Новое устройство в пределах оплаченного — это просто новое устройство.
    [ "$count" -gt "$allowed" ] 2>/dev/null || return 1

    # Кулдаун: ссылку выложили в общий чат — новые устройства будут капать
    # часами, а человеку нужно одно сообщение, а не поток.
    cool=$(awk -F'|' -v t="$primary" '$1 == t && $2 == "=alert" { print $3 }' \
           "$SUBAPPS_SEEN_FILE" 2>/dev/null | tail -1)
    [ -n "$cool" ] && [ $(( now - cool )) -lt "$FOREIGN_COOLDOWN_SEC" ] 2>/dev/null && return 1
    sed -i "/^${primary}|=alert|/d" "$SUBAPPS_SEEN_FILE" 2>/dev/null
    printf '%s|=alert|%s\n' "$primary" "$now" >> "$SUBAPPS_SEEN_FILE"

    local kb cta
    kb=$(bot_subscription_kb); cta=$(bot_subscription_link)
    notify_user "$user" "$(ce "❗️") <b>Устройств больше, чем оплачено</b>

Подписку скачивают <b>${count}</b> устройств, оплачено <b>${allowed}</b>:
${list}

Сервер разрывает лишние подключения и не разбирает, какое из них лишнее, — обрывы получают все ваши устройства сразу. Это и есть «связь работает через раз».

Если устройства ваши — докупите недостающие. Если ссылка ушла другому человеку — сбросьте её или добавьте ему отдельное устройство со своей ссылкой.$(_devices_article_line)" \
        "$kb" "$cta"
    return 0
}

# ---------- мягкий уровень: подписку скачало новое ПРИЛОЖЕНИЕ ----------
# Зачем он нужен, когда есть уровень выше: половина клиентов (Hiddify, v2rayNG,
# браузер) `X-Hwid` не шлёт вовсе, и утечка через них уровню выше не видна в
# принципе — он молчит, человек ничего не узнаёт, а связь у него тем временем
# рвётся. Этот уровень смотрит на то, что видно всегда: каким приложением
# скачали подписку. Новое приложение по ссылке — повод предупредить.
#
# Чем платим: неопознанный клиент — это «кто-то с таким приложением», а не
# устройство, поэтому сказать «у вас чужой» тут нельзя. Сообщение и не говорит:
# оно сообщает факт, первым делом объясняет безобидные причины и только потом
# предупреждает. Тревога сверх лимита осталась отдельным, более резким уровнем.
#
# ~TelegramBot исключён намеренно: этот след оставляет предпросмотр ссылки в
# Telegram, а его дёргает и НАШ СОБСТВЕННЫЙ бот, когда присылает человеку его
# же подписку. Тревожить по нему — писать «вашу ссылку кто-то открыл» сразу
# после того, как мы сами её и отправили.
_newapp_check_user() {   # user now
    local user="$1" now="$2" primary apps syn new_line="" new_count=0 cool="" kb cta
    primary=$(sub_token_for "$user" 2>/dev/null) || return 1
    [ -n "$primary" ] || return 1

    apps=$(get_user_apps "$user" 2>/dev/null) || return 1
    [ -n "$apps" ] || return 1
    syn=$(printf '%s\n' "$apps" | awk -F'|' '$1 ~ /^~/ && $1 != "~TelegramBot" { print }')
    [ -n "$syn" ] || return 1

    local key app ver os _model _first _last _cnt
    while IFS='|' read -r key app ver os _model _first _last _cnt; do
        _seen_has "$primary" "$key" && continue
        _seen_add "$primary" "$key" "$now"
        new_count=$(( new_count + 1 ))
        [ -n "$new_line" ] || new_line="${app:-неизвестное приложение}${ver:+ $ver}${os:+ · $os}"
    done <<< "$syn"

    [ "$new_count" -gt 0 ] || return 1

    cool=$(awk -F'|' -v t="$primary" '$1 == t && $2 == "=newapp" { print $3 }' \
           "$SUBAPPS_SEEN_FILE" 2>/dev/null | tail -1)
    [ -n "$cool" ] && [ $(( now - cool )) -lt "$NEWAPP_COOLDOWN_SEC" ] 2>/dev/null && return 1
    sed -i "/^${primary}|=newapp|/d" "$SUBAPPS_SEEN_FILE" 2>/dev/null
    printf '%s|=newapp|%s\n' "$primary" "$now" >> "$SUBAPPS_SEEN_FILE"

    local more=""
    [ "$new_count" -gt 1 ] && more=" и ещё $(( new_count - 1 ))"
    kb=$(bot_subscription_kb); cta=$(bot_subscription_link)
    notify_user "$user" "$(ce "❗️") <b>Вашу подписку скачало новое приложение</b>

📱 <b>${new_line}</b>${more}

Если это вы — ничего делать не нужно. Если нет, ссылка могла уйти на сторону: сбросьте её, старая перестанет работать.

Одна ссылка рассчитана на одно устройство. Когда по ней подключаются двое, сервер рвёт лишние подключения — связь портится у обоих. Нужен доступ близкому: добавьте отдельное устройство, у него будет своя ссылка.$(_devices_article_line)" \
        "$kb" "$cta"
    return 0
}

# Проход по всем: у кого появилось устройство сверх оплаченного.
# Зовётся из --notify-sweep (раз в ~5 мин), данные готовит collect_sub_ips.
notify_foreign_devices() {
    bot_enabled || return 0
    bot_mod_on notify || return 0
    BOT_TOKEN=${BOT_TOKEN:-$(bot_token)}; [ -n "$BOT_TOKEN" ] || return 0
    [ -s "$SUBAPPS_FILE" ] || return 0
    declare -F get_user_apps >/dev/null 2>&1 || return 0
    touch "$SUBAPPS_SEEN_FILE" 2>/dev/null || return 0

    # Свой замок: проверка «писали ли» и отметка не атомарны, два параллельных
    # прохода прислали бы одно и то же дважды (та же причина, что у sweep выше).
    { exec 9>"$DATA_DIR/.foreign_sweep.lock"; } 2>/dev/null || true
    flock -n 9 2>/dev/null || return 0

    local now user; now=$(date +%s)
    while IFS= read -r user; do
        [ -n "$user" ] || continue
        # Только что завели — метки поставлены, тревожить не о чем.
        _seen_prime_user "$user" "$now" && continue
        # Резкий уровень идёт первым: если устройств уже больше, чем оплачено,
        # человеку нужно именно это сообщение, а не «замечено новое приложение».
        # Оба в один прогон — это два сообщения об одном событии.
        _foreign_check_user "$user" "$now" && continue
        _newapp_check_user "$user" "$now"
    done < <(sub_all_users 2>/dev/null)

    # Уборка: отметка живёт дольше самих записей о скачивании (те 7 дней), иначе
    # устройство, помолчавшее неделю, вернулось бы как «новое». Но не вечно —
    # через месяц тишины тревога по нему оправданна, а файл не растёт.
    local cut=$(( now - SUBAPPS_SEEN_KEEP_DAYS * 86400 )) tmp
    tmp="${SUBAPPS_SEEN_FILE}.tmp.$BASHPID"
    awk -F'|' -v cut="$cut" 'NF >= 3 && $3 + 0 >= cut' "$SUBAPPS_SEEN_FILE" > "$tmp" \
        && mv "$tmp" "$SUBAPPS_SEEN_FILE" || rm -f "$tmp"
}

# ---------- ступенчатые напоминания об истечении ----------
# Пороги: за 7д (если период >8д), 3д, 1д (если период >2д), 1ч, 10мин.
# Дедуп по (user|end_ts|label) — новая покупка меняет end_ts и сбрасывает пороги.
# Гонять из cron часто (каждые ~5 мин), иначе поймать 10мин/1ч нельзя.
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
    local now user exp end_ts left pdays label secs human kb cta
    now=$(date +%s)
    kb=$(bot_renew_kb)
    cta=$(bot_renew_link)

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
        local crossed="" have_new="" last_human=""
        for pair in "7d:604800:7 дней" "3d:259200:3 дня" "1d:86400:24 часа" "1h:3600:1 час" "10m:600:10 минут"; do
            IFS=':' read -r label secs human <<< "$pair"
            [ "$left" -le "$secs" ] || continue         # порог ещё не пройден
            case "$label" in                            # гейты по длине периода
                7d) [ "$pdays" -gt 8 ] 2>/dev/null || continue ;;
                3d) [ "$pdays" -ge 3 ] 2>/dev/null || continue ;;
                1d) [ "$pdays" -gt 2 ] 2>/dev/null || continue ;;
            esac
            crossed="$crossed $label"
            last_human="$human"                         # самый срочный пройденный
            grep -qxF "${user}|${end_ts}|${label}" "$NOTIFY_STATE_FILE" 2>/dev/null || have_new=1
        done
        [ -n "$crossed" ] || continue
        # Отправляем только если появился новый (ещё не отправленный) порог.
        # Остаток пишем словами порога («24 часа»), а не точным счётчиком: срок
        # кончается в 23:59:59, и до порога всегда не хватает секунд — точный
        # счётчик показывал бы «23ч 59м» там, где человек ждёт «24 часа».
        if [ -n "$have_new" ]; then
            notify_user "$user" "$(ce "⭐") <b>Подписка скоро закончится</b>
Действует до <b>$(fmt_date_dmy "$exp")</b> — осталось <b>${last_human}</b>.
Продлите заранее, чтобы не потерять доступ." "$kb" "$cta"
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
