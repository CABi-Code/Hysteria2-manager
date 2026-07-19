#!/bin/bash
# ================================================
# Telegram-бот, привязанный к менеджеру.
#
# Возможности:
#   • Клиент (после привязки по коду или после покупки):
#       — получить свою ссылку hysteria2:// и ссылку-подписку;
#       — посмотреть статус (трафик, срок, устройства, онлайн);
#       — купить/продлить доступ (Telegram Stars или провайдер BotFather:
#         ЮKassa, Stripe и т.д.) — доступ выдаётся/продлевается автоматически.
#   • Админ (chat ID в списке ADMIN_IDS):
#       — список пользователей с онлайном, карточка с действиями
#         (вкл/выкл, кик, ссылка, подписка, продление, удаление);
#       — добавить пользователя (/add), выдать код привязки (/code);
#       — статус сервера (/status_srv), уведомления об оплатах и истечениях.
#
# Демон: systemd-юнит hy2-bot.service → hy2-manager.sh --bot-daemon
# (long-polling getUpdates; вебхуки не нужны — работает за NAT и без домена).
#
# Все данные — в $DATA_DIR:
#   bot.conf      BOT_TOKEN / ADMIN_IDS / PAY_PROVIDER_TOKEN / PAY_CURRENCY / ...
#   tariffs.conf  тарифы: «код|Название|дней|устройств|цена|валюта» (XTR = Stars;
#                 цена/валюта могут быть '/'-списками — несколько цен на тариф)
#   tgusers.dat   привязки: «tg_id|username|ts»
#   botcodes.dat  одноразовые коды привязки: «код|username|expires_ts»
#   payments.log  журнал оплат
# ================================================

BOT_CONF="$DATA_DIR/bot.conf"
TARIFFS_CONF="$DATA_DIR/tariffs.conf"
TGUSERS_FILE="$DATA_DIR/tgusers.dat"
BOTCODES_FILE="$DATA_DIR/botcodes.dat"
BOT_OFFSET_FILE="$DATA_DIR/bot.offset"
BOT_NOTIFY_FILE="$DATA_DIR/botnotify.dat"     # анти-дубли напоминаний: «user|YYYY-MM-DD»
PAYMENTS_LOG="$DATA_DIR/payments.log"
BOT_LOG="$LOG_DIR/bot.log"
BOT_UNIT="/etc/systemd/system/hy2-bot.service"

# ---------- конфиг бота (KEY=VALUE, как node.conf) ----------
bot_get() { [ -f "$BOT_CONF" ] && grep "^${1}=" "$BOT_CONF" 2>/dev/null | head -1 | cut -d= -f2-; }
bot_set() {   # key value
    local key="$1" val="$2" tmp
    mkdir -p "$DATA_DIR"; touch "$BOT_CONF"; chmod 600 "$BOT_CONF" 2>/dev/null
    tmp=$(mktemp) || return 1
    grep -v "^${key}=" "$BOT_CONF" > "$tmp" 2>/dev/null
    printf '%s=%s\n' "$key" "$val" >> "$tmp"
    cat "$tmp" > "$BOT_CONF"
    rm -f "$tmp"
}

bot_token()    { bot_get BOT_TOKEN; }
bot_enabled()  { [ -n "$(bot_token)" ] && [ -f "$BOT_UNIT" ]; }
bot_running()  { systemctl is-active --quiet hy2-bot.service 2>/dev/null; }

# Является ли chat_id админом (список через запятую/пробел).
bot_is_admin() {
    local id="$1" a
    for a in $(bot_get ADMIN_IDS | tr ',;' '  '); do
        [ "$a" = "$id" ] && return 0
    done
    return 1
}

# ---------- Telegram API ----------
tg_api() {   # method [curl args...] -> JSON
    local method="$1"; shift
    curl -s --max-time 65 "https://api.telegram.org/bot${BOT_TOKEN}/${method}" "$@" 2>/dev/null
}

# Экранирование для parse_mode=HTML.
tg_esc() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

tg_send() {   # chat_id text [reply_markup_json]
    local chat="$1" text="$2" kb="$3"
    if [ -n "$kb" ]; then
        tg_api sendMessage --data-urlencode "chat_id=$chat" --data-urlencode "text=$text" \
            --data-urlencode "parse_mode=HTML" --data-urlencode "disable_web_page_preview=true" \
            --data-urlencode "reply_markup=$kb" >/dev/null
    else
        tg_api sendMessage --data-urlencode "chat_id=$chat" --data-urlencode "text=$text" \
            --data-urlencode "parse_mode=HTML" --data-urlencode "disable_web_page_preview=true" >/dev/null
    fi
}

tg_edit() {   # chat_id message_id text [reply_markup_json]
    local chat="$1" mid="$2" text="$3" kb="$4"
    if [ -n "$kb" ]; then
        tg_api editMessageText --data-urlencode "chat_id=$chat" --data-urlencode "message_id=$mid" \
            --data-urlencode "text=$text" --data-urlencode "parse_mode=HTML" \
            --data-urlencode "disable_web_page_preview=true" \
            --data-urlencode "reply_markup=$kb" >/dev/null
    else
        tg_api editMessageText --data-urlencode "chat_id=$chat" --data-urlencode "message_id=$mid" \
            --data-urlencode "text=$text" --data-urlencode "parse_mode=HTML" \
            --data-urlencode "disable_web_page_preview=true" >/dev/null
    fi
}

tg_answer_cb() {   # callback_id [text]
    tg_api answerCallbackQuery --data-urlencode "callback_query_id=$1" \
        ${2:+--data-urlencode "text=$2"} >/dev/null
}

# Разослать всем админам.
bot_notify_admins() {
    local a
    [ -n "${BOT_TOKEN:-}" ] || BOT_TOKEN=$(bot_token)
    [ -n "$BOT_TOKEN" ] || return 0
    for a in $(bot_get ADMIN_IDS | tr ',;' '  '); do
        [ -n "$a" ] && tg_send "$a" "$1"
    done
}

# ---------- привязки Telegram ↔ пользователи ----------
# Пустой username в строке «tg_id||ts» — tombstone отвязки (нужен для кластера:
# без него запись-привязка с пира воскрешала бы уже отвязанный tg_id, см.
# cluster_apply_tgbind). Поэтому tg_bound_user трактует пустое поле как «не
# привязан», а список привязок такие строки пропускает.
tg_bound_user() { awk -F'|' -v id="$1" '$1==id && $2!=""{print $2; exit}' "$TGUSERS_FILE" 2>/dev/null; }
tg_user_chats() { awk -F'|' -v u="$1" '$2==u{print $1}' "$TGUSERS_FILE" 2>/dev/null; }
tg_bind() {   # tg_id username
    touch "$TGUSERS_FILE"; chmod 600 "$TGUSERS_FILE" 2>/dev/null
    sed -i "/^${1}|/d" "$TGUSERS_FILE" 2>/dev/null
    printf '%s|%s|%s\n' "$1" "$2" "$(date +%s)" >> "$TGUSERS_FILE"
    publish_cluster_tgbind    # держим статический файл кластера свежим (no-op вне кластера)
}
# Отвязка = tombstone (пустой username + свежий ts), а НЕ удаление строки:
# иначе last-write-wins по пиру откатил бы отвязку назад к старой привязке.
tg_unbind() {   # tg_id
    touch "$TGUSERS_FILE"; chmod 600 "$TGUSERS_FILE" 2>/dev/null
    sed -i "/^${1}|/d" "$TGUSERS_FILE" 2>/dev/null
    printf '%s||%s\n' "$1" "$(date +%s)" >> "$TGUSERS_FILE"
    publish_cluster_tgbind
}

# Одноразовый код привязки для юзера (живёт 48 часов).
bot_bind_code() {   # username -> code
    local user="$1" code
    touch "$BOTCODES_FILE"; chmod 600 "$BOTCODES_FILE" 2>/dev/null
    code=$(pwgen -s -A 8 1 2>/dev/null || head -c16 /dev/urandom | md5sum | cut -c1-8)
    # прибрать протухшие коды
    local now tmp; now=$(date +%s); tmp=$(mktemp)
    awk -F'|' -v n="$now" '$3+0 > n' "$BOTCODES_FILE" > "$tmp" 2>/dev/null; cat "$tmp" > "$BOTCODES_FILE"; rm -f "$tmp"
    printf '%s|%s|%s\n' "$code" "$user" $(( now + 48*3600 )) >> "$BOTCODES_FILE"
    printf '%s' "$code"
}
bot_code_lookup() {   # code -> username (и гасит код)
    local code="$1" now user
    now=$(date +%s)
    user=$(awk -F'|' -v c="$code" -v n="$now" '$1==c && $3+0>n {print $2; exit}' "$BOTCODES_FILE" 2>/dev/null)
    [ -n "$user" ] && sed -i "/^${code}|/d" "$BOTCODES_FILE" 2>/dev/null
    printf '%s' "$user"
}

# ---------- тарифы ----------
# Строка: «код|Название|дней|устройств|цена|валюта». Валюта XTR = Telegram Stars
# (цена = кол-во звёзд, целое). Иначе — валюта платёжного провайдера
# (цена в ОСНОВНЫХ единицах: 199 = 199 руб; в копейки переводим сами).
#
# Мультивалютность: поля «цена» и «валюта» могут быть '/'-списками одинаковой
# длины (индексы выровнены), напр. «100/199|XTR/RUB» — один тариф с ценой и в
# звёздах, и в рублях. Одиночная цена — частный случай списка из одного элемента.
tariff_list()   { grep -vE '^\s*(#|$)' "$TARIFFS_CONF" 2>/dev/null; }
tariff_get()    { tariff_list | awk -F'|' -v c="$1" '$1==c{print; exit}'; }
tariff_count()  { tariff_list | grep -c '^'; }
tariff_add()    {   # code title days devices price currency
    touch "$TARIFFS_CONF"
    sed -i "/^${1}|/d" "$TARIFFS_CONF" 2>/dev/null
    printf '%s|%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >> "$TARIFFS_CONF"
}
tariff_del()    { sed -i "/^${1}|/d" "$TARIFFS_CONF" 2>/dev/null; }

# Заменить строку тарифа НА МЕСТЕ (позиция в файле = порядок в /buy и в webapp
# сохраняется). Код тоже можно сменить: ищем по СТАРОМУ коду, пишем новую строку.
tariff_update() {   # oldcode newcode title days devices price currency
    local old="$1"; shift
    local new="$1|$2|$3|$4|$5|$6" tmp line
    tmp=$(mktemp) || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" == "$old|"* ]]; then printf '%s\n' "$new"; else printf '%s\n' "$line"; fi
    done < "$TARIFFS_CONF" > "$tmp"
    mv "$tmp" "$TARIFFS_CONF"
}

# Поменять тариф местами с соседним (dir = up|down). Меняет порядок показа
# тарифов клиенту. Возврат 1, если тариф уже с краю или не найден.
tariff_move() {   # code up|down
    local code="$1" dir="$2" tmp i idx=-1 j
    local -a lines
    mapfile -t lines < <(tariff_list)
    local n=${#lines[@]}
    for ((i=0; i<n; i++)); do
        [ "${lines[$i]%%|*}" = "$code" ] && { idx=$i; break; }
    done
    [ "$idx" -lt 0 ] && return 1
    if [ "$dir" = "up" ]; then j=$((idx-1)); else j=$((idx+1)); fi
    if [ "$j" -lt 0 ] || [ "$j" -ge "$n" ]; then return 1; fi
    local t="${lines[$idx]}"; lines[$idx]="${lines[$j]}"; lines[$j]="$t"
    tmp=$(mktemp) || return 1
    printf '%s\n' "${lines[@]}" > "$tmp"
    mv "$tmp" "$TARIFFS_CONF"
}

# Переставить тариф на позицию N (1-based) в списке: удаляем со старого места и
# вставляем на нужное. N вне диапазона зажимается к [1..кол-во]. Возврат 1, если
# тариф не найден.
tariff_move_to() {   # code position
    local code="$1" pos="$2" tmp i idx=-1 target
    [[ "$pos" =~ ^[0-9]+$ ]] || return 1
    local -a lines; mapfile -t lines < <(tariff_list)
    local n=${#lines[@]}
    [ "$n" -eq 0 ] && return 1
    [ "$pos" -lt 1 ] && pos=1; [ "$pos" -gt "$n" ] && pos="$n"
    for ((i=0; i<n; i++)); do
        [ "${lines[$i]%%|*}" = "$code" ] && { idx=$i; break; }
    done
    [ "$idx" -lt 0 ] && return 1
    target=$((pos-1))
    [ "$target" -eq "$idx" ] && return 0
    local moved="${lines[$idx]}"
    local -a rest=() out=()
    for ((i=0; i<n; i++)); do [ "$i" -ne "$idx" ] && rest+=("${lines[$i]}"); done
    for ((i=0; i<${#rest[@]}; i++)); do
        [ "$i" -eq "$target" ] && out+=("$moved")
        out+=("${rest[$i]}")
    done
    [ "$target" -ge "${#rest[@]}" ] && out+=("$moved")
    tmp=$(mktemp) || return 1
    printf '%s\n' "${out[@]}" > "$tmp"
    mv "$tmp" "$TARIFFS_CONF"
}

# Человеческая цена тарифа: «⭐ 100», «199 RUB» или список «⭐ 100 / 199 RUB».
# Оба аргумента — '/'-списки одинаковой длины (или одиночные значения).
tariff_price_str() {   # price[/...] currency[/...]
    local -a pa ca; IFS='/' read -r -a pa <<< "$1"; IFS='/' read -r -a ca <<< "$2"
    local i p c one out=""
    for i in "${!pa[@]}"; do
        p="${pa[$i]}"; c="${ca[$i]:-XTR}"
        if [ "$c" = "XTR" ]; then one="⭐ $p"; else one="$p $c"; fi
        [ -n "$out" ] && out="$out / $one" || out="$one"
    done
    printf '%s' "$out"
}

# Цена тарифа для конкретной валюты из '/'-списков price/cur (пусто → нет такой).
tariff_price_in_list() {   # price_list cur_list want_currency
    local -a pa ca; IFS='/' read -r -a pa <<< "$1"; IFS='/' read -r -a ca <<< "$2"
    local i
    for i in "${!ca[@]}"; do
        [ "${ca[$i]}" = "$3" ] && { printf '%s' "${pa[$i]}"; return 0; }
    done
    return 1
}

# Список валют тарифа (через пробел) по его коду.
tariff_currencies_of() {   # code
    local row c; row=$(tariff_get "$1"); [ -z "$row" ] && return 1
    IFS='|' read -r _ _ _ _ _ c <<< "$row"
    printf '%s' "$c" | tr '/' ' '
}

# Диалог ввода набора валют и цены для каждой. Результат в _TPRICE/_TCUR
# ('/'-списки). Возврат 1 при ошибке ввода (сообщение уже напечатано).
# Необязательные аргументы cur_default/price_default показываются как текущие.
tariff_ask_prices() {   # [cur_default] [price_default]
    _TPRICE=""; _TCUR=""
    local dcur="${1:-}" dprice="${2:-}" raw
    local hint="  Валюты через пробел/запятую/слеш (XTR — Stars; RUB/USD/...)"
    if [ -n "$dcur" ]; then
        ask raw "$hint [$(printf '%s' "$dcur" | tr '/' ' ')]: "; raw="${raw:-$dcur}"
    else
        ask raw "$hint (Enter = XTR): "; raw="${raw:-XTR}"
    fi
    raw=$(printf '%s' "$raw" | tr ',/' '  ' | tr 'a-z' 'A-Z')
    local -a curs=(); local c dup s
    for c in $raw; do
        [ -z "$c" ] && continue
        [[ "$c" =~ ^[A-Z]{3}$ ]] || { echo "  ❌ Валюта «$c» — ровно 3 буквы (XTR/RUB/USD...)."; return 1; }
        dup=0; for s in "${curs[@]}"; do [ "$s" = "$c" ] && dup=1; done
        [ "$dup" -eq 0 ] && curs+=("$c")
    done
    [ "${#curs[@]}" -eq 0 ] && { echo "  ❌ Не указано ни одной валюты."; return 1; }
    local -a prices=(); local cur p def
    for cur in "${curs[@]}"; do
        def=$(tariff_price_in_list "$dprice" "$dcur" "$cur" 2>/dev/null || true)
        if [ "$cur" = "XTR" ]; then
            ask p "  Цена в звёздах (XTR)${def:+ [$def]}: "
        else
            ask p "  Цена в $cur (целое, осн. единицы)${def:+ [$def]}: "
        fi
        p="${p:-$def}"
        [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -gt 0 ] || { echo "  ❌ Цена в $cur — целое число > 0."; return 1; }
        prices+=("$p")
    done
    local IFS='/'
    _TCUR="${curs[*]}"; _TPRICE="${prices[*]}"
    return 0
}

# ---------- продление/выдача доступа (общее для оплат и админ-команд) ----------
# Продлить срок юзера на N дней ОТ максимума(сегодня, текущий срок).
bot_extend_user() {   # user days -> печатает новую дату
    local user="$1" days="$2" cur base new
    cur=$(get_user_expiry "$user")
    base=$(date +%Y-%m-%d)
    if [ -n "$cur" ] && [[ "$cur" > "$base" ]]; then base="$cur"; fi
    new=$(date -d "$base +${days} days" +%Y-%m-%d 2>/dev/null)
    [ -n "$new" ] || return 1
    set_user_expiry "$user" "$new"
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
    if [ -n "$exp" ]; then
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
    rows=$(tariff_list | while IFS='|' read -r code title days devices price cur; do
        [ -n "$code" ] || continue
        jq -nc --arg t "$title — $(tariff_price_str "$price" "$cur")" --arg d "buy:$code" '[{text:$t,callback_data:$d}]'
    done | jq -sc '.')
    kb=$(jq -nc --argjson r "$rows" '{inline_keyboard:$r}')
    tg_send "$chat" "💳 <b>Выберите тариф</b>
Оплата: Telegram Stars (⭐) или картой через платёжного провайдера — доступ выдаётся автоматически сразу после оплаты." "$kb"
}

# Выставить счёт по тарифу.
bot_send_invoice() {   # chat_id tariff_code [currency]
    local chat="$1" code="$2" want="${3:-}" row title days devices price cur user payload prices provider
    row=$(tariff_get "$code")
    [ -z "$row" ] && { tg_send "$chat" "Тариф не найден (возможно, удалён)."; return; }
    IFS='|' read -r code title days devices price cur <<< "$row"
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

# Меню выбора валюты оплаты для мультивалютного тарифа (кнопка на валюту).
bot_buy_currency_menu() {   # chat_id tariff_code
    local chat="$1" code="$2" row title price cur
    row=$(tariff_get "$code")
    [ -z "$row" ] && { tg_send "$chat" "Тариф не найден."; return; }
    IFS='|' read -r _ title _ _ price cur <<< "$row"
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

# Оплата прошла — выдать/продлить доступ.
bot_fulfill_payment() {   # chat_id tg_id payload total_amount currency charge_id
    local chat="$1" tgid="$2" payload="$3" amount="$4" cur="$5" charge="$6"
    local code user row title days devices price tcur newexp
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
    IFS='|' read -r code title days devices price tcur <<< "$row"

    # Аккаунт: привязанный, из payload, либо новый (tg<ID>).
    [ "$user" = "-" ] && user=$(tg_bound_user "$tgid")
    if [ -z "$user" ]; then
        user="tg${tgid}"
        local n=2
        while db_user_exists "$user" || is_user_disabled "$user"; do
            user="tg${tgid}_$n"; n=$((n+1))
        done
    fi

    if ! bot_provision_user "$user" >/dev/null; then
        bot_notify_admins "🛑 Оплата от tg:$tgid получена, но создать пользователя «$(tg_esc "$user")» НЕ удалось. Разберитесь вручную (charge: <code>$(tg_esc "$charge")</code>)."
        tg_send "$chat" "Оплата получена, но при выдаче доступа произошла ошибка. Администратор уведомлён и всё выдаст вручную."
        return
    fi
    newexp=$(bot_extend_user "$user" "$days")
    [ "$devices" -gt 0 ] 2>/dev/null && set_user_limits "$user" "$devices" "$(get_user_hardcheck "$user")"
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

# ---------- админ: список/карточка пользователя ----------
bot_admin_users() {   # chat_id page [message_id]
    local chat="$1" page="$2" mid="$3"
    local users total pages start
    users=$(get_all_users)
    total=$(printf '%s\n' "$users" | grep -c .)
    [ "$total" -eq 0 ] && { tg_send "$chat" "Пользователей нет."; return; }
    pages=$(( (total + 7) / 8 )); [ "$page" -gt "$pages" ] && page=$pages; [ "$page" -lt 1 ] && page=1
    start=$(( (page - 1) * 8 + 1 ))
    local online; online=$(api_get "/online")
    local rows u icon oc
    rows=$(printf '%s\n' "$users" | sed -n "${start},$((start+7))p" | while IFS= read -r u; do
        [ -n "$u" ] || continue
        if is_user_disabled "$u"; then icon="🔴"
        else
            oc=$(echo "$online" | jq -r --arg x "$u" '.[$x] // 0' 2>/dev/null); [[ "$oc" =~ ^[0-9]+$ ]] || oc=0
            [ "$oc" -gt 0 ] && icon="💚" || icon="⚫"
        fi
        jq -nc --arg t "$icon $u" --arg d "a:u:$u" '[{text:$t,callback_data:$d}]'
    done | jq -sc '.')
    local nav='[]'
    if [ "$pages" -gt 1 ]; then
        nav=$(jq -nc --arg p "a:users:$((page-1))" --arg n "a:users:$((page+1))" --arg t "стр. $page/$pages" \
            '[{text:"←",callback_data:$p},{text:$t,callback_data:"a:menu"},{text:"→",callback_data:$n}]')
    fi
    local kb; kb=$(jq -nc --argjson r "$rows" --argjson n "$nav" '{inline_keyboard:($r + (if ($n|length)>0 then [$n] else [] end))}')
    local text="👥 <b>Пользователи</b> (всего $total)"
    if [ -n "$mid" ]; then tg_edit "$chat" "$mid" "$text" "$kb"; else tg_send "$chat" "$text" "$kb"; fi
}

bot_admin_user_card() {   # chat_id username [message_id]
    local chat="$1" user="$2" mid="$3"
    local st exp exps tl tx rx dev oc ipc tglabel
    if is_user_disabled "$user"; then st="🔴 отключён"
    elif db_user_exists "$user"; then st="✅ активен"
    else st="❓ не найден"; fi
    exp=$(get_user_expiry "$user")
    [ -n "$exp" ] && exps="$exp ($(format_remaining "$exp" 2>/dev/null || echo '—'))" || exps="бессрочно"
    tl=$(get_user_traffic "$user"); tx=$(echo "$tl" | cut -d'|' -f2); rx=$(echo "$tl" | cut -d'|' -f3)
    dev=$(get_user_devices "$user")
    oc=$(api_get "/online" | jq -r --arg u "$user" '.[$u] // 0' 2>/dev/null); [[ "$oc" =~ ^[0-9]+$ ]] || oc=0
    ipc=$(get_user_ip_count "$user")
    tglabel=$(tg_user_chats "$user" | tr '\n' ' ')
    local text="👤 <b>$(tg_esc "$user")</b>
Статус: $st · онлайн: $oc
Срок: $exps
Трафик: ↑$(format_bytes "$tx") ↓$(format_bytes "$rx") · IP: $ipc
Устройств (лимит): $dev
Telegram: ${tglabel:-не привязан}"
    local tgl_text="🔴 Отключить"
    is_user_disabled "$user" && tgl_text="✅ Включить"
    local kb
    kb=$(jq -nc --arg u "$user" --arg tgl "$tgl_text" '{inline_keyboard:[
        [{text:$tgl,callback_data:("a:tgl:"+$u)},{text:"✂ Кик",callback_data:("a:kick:"+$u)}],
        [{text:"🔗 Ссылка",callback_data:("a:link:"+$u)},{text:"📡 Подписка",callback_data:("a:sub:"+$u)}],
        [{text:"⏰ +30 дней",callback_data:("a:ext:"+$u+":30")},{text:"⏰ +90",callback_data:("a:ext:"+$u+":90")},{text:"⏰ снять срок",callback_data:("a:ext:"+$u+":0")}],
        [{text:"🎫 Код привязки",callback_data:("a:code:"+$u)},{text:"🗑 Удалить",callback_data:("a:del:"+$u)}],
        [{text:"↩ К списку",callback_data:"a:users:1"}]
    ]}')
    if [ -n "$mid" ]; then tg_edit "$chat" "$mid" "$text" "$kb"; else tg_send "$chat" "$text" "$kb"; fi
}

bot_admin_server_status() {   # chat_id
    local chat="$1" la mem du online total
    la=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)
    mem=$(free -m 2>/dev/null | awk '/^Mem:/{printf "%s/%s МБ", $3, $2}')
    du=$(df -h / 2>/dev/null | awk 'NR==2{printf "%s/%s (%s)", $3, $2, $5}')
    online=$(api_get "/online" | jq 'to_entries | map(select(.value>0)) | length' 2>/dev/null); [[ "$online" =~ ^[0-9]+$ ]] || online=0
    total=$(get_all_users | grep -c .)
    local hyst="🔴 остановлена"
    systemctl is-active --quiet "$SERVICE" 2>/dev/null && hyst="💚 работает"
    local kl="⚪ выкл"
    if declare -F klimit_down >/dev/null && { [ "$(klimit_down)" -gt 0 ] || [ "$(klimit_up)" -gt 0 ]; } 2>/dev/null; then
        klimit_active && kl="💚 ↓$(klimit_down)/↑$(klimit_up) Мбит" || kl="🔴 настроен, но не загружен"
    fi
    tg_send "$chat" "📈 <b>Сервер «$(tg_esc "$(node_name 2>/dev/null || hostname -s)")»</b>
Hysteria: $hyst · онлайн: $online из $total
LoadAvg: ${la:-?} · RAM: ${mem:-?}
Диск: ${du:-?}
Лимит скорости: $kl" "$KB_ADMIN"
}

# ---------- обработка одного апдейта ----------
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
        if [ -n "$(tariff_get "$code")" ]; then
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
        tg_answer_cb "$cb_id"
        [ -z "$chat" ] && return 0
        case "$data" in
            m:link)   bot_client_link "$chat" ;;
            m:sub)
                local u; u=$(tg_bound_user "$chat")
                if [ -z "$u" ]; then tg_send "$chat" "Аккаунт не привязан (/start КОД)."
                elif ! sub_enabled; then tg_send "$chat" "Подписка на сервере не настроена — используйте «Моя ссылка»."
                else tg_send "$chat" "📡 <b>Ссылка-подписка</b>:
<code>$(tg_esc "$(subscription_url "$u")")</code>"
                fi ;;
            m:status) bot_client_status "$chat" ;;
            m:buy)    bot_buy_menu "$chat" ;;
            buy:*)    bot_buy_dispatch "$chat" "${data#buy:}" ;;
            a:*)
                bot_is_admin "$from" || { tg_send "$chat" "⛔ Только для администратора."; return 0; }
                case "$data" in
                    a:menu)     tg_edit "$chat" "$mid" "🛠 <b>Админ-панель</b>" "$KB_ADMIN" ;;
                    a:users:*)  bot_admin_users "$chat" "${data##*:}" "$mid" ;;
                    a:u:*)      bot_admin_user_card "$chat" "${data#a:u:}" "$mid" ;;
                    a:stat)     bot_admin_server_status "$chat" ;;
                    a:add)      tg_send "$chat" "Добавить: <code>/add имя [дней] [устройств]</code>
Пример: <code>/add vasya 30 2</code>" ;;
                    a:codehelp) tg_send "$chat" "Код привязки: <code>/code имя</code> — бот выдаст одноразовый код, клиент отправит его боту командой /start КОД." ;;
                    a:tariffs)
                        local tl
                        tl=$(tariff_list | while IFS='|' read -r c t d dv p cur; do
                            [ -n "$c" ] && echo "• <code>$c</code> — $(tg_esc "$t"): ${d} дн., устройств ${dv}, $(tariff_price_str "$p" "$cur")"
                        done)
                        tg_send "$chat" "💰 <b>Тарифы</b>
${tl:-нет тарифов}

Управление тарифами — в менеджере на сервере: Настройки → Telegram-бот → Тарифы." ;;
                    a:tgl:*)
                        local u="${data#a:tgl:}"
                        if is_user_disabled "$u"; then enable_user "$u" >/dev/null 2>&1; else disable_user "$u" >/dev/null 2>&1; fi
                        declare -F cstate_mark >/dev/null && { is_user_disabled "$u" && cstate_mark "$u" disabled || cstate_mark "$u" active; }
                        bot_admin_user_card "$chat" "$u" "$mid" ;;
                    a:kick:*)
                        api_post "/kick" "[\"${data#a:kick:}\"]" &>/dev/null
                        tg_send "$chat" "✂ Сессии сброшены." ;;
                    a:link:*)
                        local u="${data#a:link:}"
                        tg_send "$chat" "$(bot_access_text "$u")" ;;
                    a:sub:*)
                        local u="${data#a:sub:}"
                        sub_enabled && tg_send "$chat" "📡 <code>$(tg_esc "$(subscription_url "$u")")</code>" \
                            || tg_send "$chat" "Подписка не настроена." ;;
                    a:ext:*)
                        local rest="${data#a:ext:}" u days
                        u="${rest%%:*}"; days="${rest##*:}"
                        if [ "$days" = "0" ]; then
                            remove_user_expiry "$u"
                            tg_send "$chat" "⏰ Срок у $(tg_esc "$u") снят (бессрочно)."
                        else
                            local newd; newd=$(bot_extend_user "$u" "$days")
                            tg_send "$chat" "⏰ $(tg_esc "$u"): продлено до <b>${newd:-?}</b>."
                        fi
                        bot_admin_user_card "$chat" "$u" "$mid" ;;
                    a:code:*)
                        local u="${data#a:code:}" code botun
                        code=$(bot_bind_code "$u")
                        botun=$(bot_get BOT_USERNAME)
                        tg_send "$chat" "🎫 Код привязки для <b>$(tg_esc "$u")</b> (действует 48 ч):
<code>${code}</code>
Клиент отправляет боту: <code>/start ${code}</code>${botun:+
Или по ссылке: https://t.me/${botun}?start=${code}}" ;;
                    a:del:*)
                        local u="${data#a:del:}"
                        tg_send "$chat" "Удалить <b>$(tg_esc "$u")</b> ПОЛНОСТЬЮ (ключи, статистика, привязки)?" \
                            "$(jq -nc --arg u "$u" '{inline_keyboard:[[{text:"🗑 Да, удалить",callback_data:("a:del2:"+$u)},{text:"Отмена",callback_data:("a:u:"+$u)}]]}')" ;;
                    a:del2:*)
                        local u="${data#a:del2:}" t
                        delete_user "$u" >/dev/null 2>&1
                        for t in $(tg_user_chats "$u"); do tg_unbind "$t"; done
                        tg_send "$chat" "🗑 $(tg_esc "$u") удалён." ;;
                esac ;;
        esac
        return 0
    fi

    # 3) обычное сообщение.
    local chat from text
    chat=$(echo "$upd" | jq -r '.message.chat.id // empty' 2>/dev/null)
    [ -z "$chat" ] && return 0
    from=$(echo "$upd" | jq -r '.message.from.id // empty')
    text=$(echo "$upd" | jq -r '.message.text // empty')

    # 3а) успешная оплата.
    local sp
    sp=$(echo "$upd" | jq -r '.message.successful_payment.invoice_payload // empty' 2>/dev/null)
    if [ -n "$sp" ]; then
        local amount cur charge
        amount=$(echo "$upd" | jq -r '.message.successful_payment.total_amount // 0')
        cur=$(echo "$upd" | jq -r '.message.successful_payment.currency // ""')
        charge=$(echo "$upd" | jq -r '.message.successful_payment.telegram_payment_charge_id // ""')
        bot_fulfill_payment "$chat" "$from" "$sp" "$amount" "$cur" "$charge"
        return 0
    fi

    case "$text" in
        /start|/start@*)
            if bot_is_admin "$from"; then
                tg_send "$chat" "🛠 <b>Админ-панель</b>
Команды: /add имя [дней] [устройств] · /code имя · /users · /status_srv" "$KB_ADMIN"
            else
                bot_client_menu "$chat"
            fi ;;
        "/start "*)
            local code="${text#/start }" u
            code=$(printf '%s' "$code" | tr -d '[:space:]')
            u=$(bot_code_lookup "$code")
            if [ -n "$u" ]; then
                tg_bind "$from" "$u"
                tg_send "$chat" "✅ Аккаунт <b>$(tg_esc "$u")</b> привязан к вашему Telegram!" "$KB_CLIENT"
                bot_notify_admins "🔗 tg:$from привязал аккаунт $(tg_esc "$u")"
            else
                tg_send "$chat" "❌ Код неверен или истёк. Запросите новый у администратора."
                bot_client_menu "$chat"
            fi ;;
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
                    set_user_limits "$u" "$dev" 0; extra="$extra · устройств: $dev"
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
            tail -c 262144 "$BOT_LOG" > "${BOT_LOG}.tmp" 2>/dev/null && mv "${BOT_LOG}.tmp" "$BOT_LOG"
        fi
    done
}

# ---------- напоминания об истечении (вызывается из cron --check-expiry) ----------
# Клиентам с привязанным Telegram — за 3 дня и в день истечения (раз в день).
bot_expiry_reminders() {
    bot_enabled || return 0
    BOT_TOKEN=$(bot_token); [ -n "$BOT_TOKEN" ] || return 0
    touch "$BOT_NOTIFY_FILE"
    local today user exp dl chats c
    today=$(date +%Y-%m-%d)
    while IFS='|' read -r user exp; do
        [ -n "$user" ] && [ -n "$exp" ] || continue
        dl=$(expiry_days_left "$exp" 2>/dev/null) || continue
        [ -n "$dl" ] || continue
        # Напоминаем при 3 днях и менее (но ещё не истёк).
        { [ "$dl" -le 3 ] && [ "$dl" -ge 0 ]; } 2>/dev/null || continue
        grep -qxF "${user}|${today}" "$BOT_NOTIFY_FILE" 2>/dev/null && continue
        chats=$(tg_user_chats "$user")
        [ -n "$chats" ] || continue
        for c in $chats; do
            tg_send "$c" "⏰ Ваш доступ (<b>$(tg_esc "$user")</b>) истекает <b>$exp</b> (осталось: $(format_remaining "$exp")).$( [ "$(tariff_count)" -gt 0 ] && echo "
Продлить: /buy" )"
        done
        echo "${user}|${today}" >> "$BOT_NOTIFY_FILE"
        # Подчистка старых меток (держим только сегодняшние и вчерашние).
        local tmp; tmp=$(mktemp)
        grep -E "\|($today|$(date -d yesterday +%Y-%m-%d 2>/dev/null))$" "$BOT_NOTIFY_FILE" > "$tmp" 2>/dev/null
        cat "$tmp" > "$BOT_NOTIFY_FILE"; rm -f "$tmp"
    done < "$EXPIRY_FILE"
}

# Уведомление об автоотключении (зовётся из check_expired_users через хук).
bot_notify_expired() {   # user
    bot_enabled || return 0
    BOT_TOKEN=$(bot_token); [ -n "$BOT_TOKEN" ] || return 0
    local user="$1" c
    for c in $(tg_user_chats "$user"); do
        tg_send "$c" "⛔ Срок действия вашего доступа (<b>$(tg_esc "$user")</b>) истёк — доступ отключён.$( [ "$(tariff_count)" -gt 0 ] && echo "
Продлить и включить снова: /buy" )"
    done
    bot_notify_admins "⏰ Автоотключение по сроку: $(tg_esc "$user")"
}

# ---------- systemd-юнит ----------
bot_install_unit() {
    cat > "$BOT_UNIT" <<EOF
[Unit]
Description=Hysteria2 Manager Telegram bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash ${SCRIPT_DIR}/hy2-manager.sh --bot-daemon
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload 2>/dev/null
}

bot_start()  { bot_install_unit; systemctl enable --now hy2-bot.service &>/dev/null; bot_running; }
bot_stop()   { systemctl disable --now hy2-bot.service &>/dev/null; return 0; }
bot_remove() { bot_stop; rm -f "$BOT_UNIT"; systemctl daemon-reload 2>/dev/null; }
bot_restart(){ bot_running && systemctl restart hy2-bot.service &>/dev/null; return 0; }

# ---------- TUI-меню бота (вызывается из настроек менеджера) ----------
bot_menu() {
    while true; do
        clear
        local tok admins st getme un prov cur
        tok=$(bot_token); admins=$(bot_get ADMIN_IDS)
        prov=$(bot_get PAY_PROVIDER_TOKEN); cur=$(bot_get PAY_CURRENCY); [ -z "$cur" ] && cur=RUB
        if bot_running; then st="💚 работает"; elif bot_enabled; then st="🔴 остановлен"; else st="⚪ не настроен"; fi
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  🤖 Telegram-бот"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Статус     : $st"
        echo "  Токен      : $([ -n "$tok" ] && echo "задан (${tok:0:10}…)" || echo "❌ не задан")"
        echo "  Админы     : ${admins:-❌ не заданы}"
        un=$(bot_get BOT_USERNAME)
        echo "  Бот        : $([ -n "$un" ] && echo "@$un" || echo "имя не определено (запустите бота)")"
        echo "  Тарифов    : $(tariff_count 2>/dev/null || echo 0)"
        echo "  Провайдер  : $([ -n "$prov" ] && echo "настроен, валюта $cur" || echo "не настроен (доступны Telegram Stars)")"
        echo "  Оплат всего: $(grep -c '^' "$PAYMENTS_LOG" 2>/dev/null | tr -dc '0-9' || echo 0)"
        echo ""
        echo "  1. 🔑 Задать токен бота (из @BotFather)"
        echo "  2. 👑 Задать админов (chat ID через запятую; свой ID — команда /id боту)"
        echo "  3. $(bot_running && echo "⏹  Остановить бота" || echo "▶  Запустить бота")"
        echo "  4. 💰 Тарифы (просмотр/добавление/удаление)"
        echo "  5. 💳 Платёжный провайдер (токен BotFather Payments + валюта)"
        echo "  6. 🔗 Привязки Telegram (список/отвязать)"
        echo "  7. 🎫 Выдать код привязки пользователю"
        echo "  8. 📨 Тест: сообщение всем админам"
        echo "  9. 📜 Логи бота (последние 25 строк)"
        echo "  0. ↩  Назад"
        echo ""
        local ch; ask ch "  Выберите: "
        case "$ch" in
            1)
                echo ""
                echo "  Создайте бота у @BotFather (/newbot) и вставьте токен вида 123456:AA..."
                local t; ask t "  Токен: "
                t=$(printf '%s' "$t" | tr -d '[:space:]')
                if [[ "$t" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
                    bot_set BOT_TOKEN "$t"
                    # Сразу проверяем токен запросом getMe.
                    BOT_TOKEN="$t"
                    getme=$(tg_api getMe)
                    un=$(echo "$getme" | jq -r '.result.username // empty' 2>/dev/null)
                    if [ -n "$un" ]; then
                        bot_set BOT_USERNAME "$un"
                        echo "  ✅ Токен работает: @$un"
                        bot_restart
                    else
                        echo "  ⚠️  Токен сохранён, но Telegram не ответил (сеть? токен?)."
                    fi
                elif [ -n "$t" ]; then
                    echo "  ❌ Не похоже на токен BotFather."
                fi
                pause ;;
            2)
                echo ""
                echo "  Узнать свой ID: напишите боту /id (или @userinfobot)."
                local ids; ask ids "  ID админов через запятую [${admins}]: "
                if [ -n "$ids" ]; then
                    if [[ "$ids" =~ ^[0-9,[:space:]-]+$ ]]; then
                        bot_set ADMIN_IDS "$(printf '%s' "$ids" | tr -d '[:space:]')"
                        echo "  ✅ Сохранено."
                        bot_restart
                    else
                        echo "  ❌ Только цифры и запятые."
                    fi
                fi
                pause ;;
            3)
                if bot_running; then
                    bot_stop
                    echo "  ⏹ Бот остановлен (юнит hy2-bot отключён)."
                else
                    if [ -z "$(bot_token)" ]; then
                        echo "  ❌ Сначала задайте токен (пункт 1)."
                    elif [ -z "$(bot_get ADMIN_IDS)" ]; then
                        echo "  ❌ Сначала задайте админов (пункт 2) — иначе ботом никто не управляет."
                    else
                        if bot_start; then
                            echo "  ✅ Бот запущен (systemd: hy2-bot.service, автозапуск включён)."
                            echo "     Напишите боту /start."
                        else
                            echo "  ❌ Бот не стартовал — journalctl -u hy2-bot -e и логи (пункт 9)."
                        fi
                    fi
                fi
                pause ;;
            4)
                bot_tariffs_menu ;;
            5)
                echo ""
                echo "  Оплата возможна двумя способами:"
                echo "   • Telegram Stars (валюта XTR) — работает СРАЗУ, настройка не нужна;"
                echo "   • Карты/СБП через провайдера BotFather: @BotFather → /mybots → ваш бот →"
                echo "     Payments → выберите провайдера (ЮKassa, Stripe и др.) → получите токен."
                local pt pc
                ask pt "  Токен провайдера (Enter — не менять, '-' — убрать): "
                if [ "$pt" = "-" ]; then
                    bot_set PAY_PROVIDER_TOKEN ""
                    echo "  ✅ Провайдер убран (останутся только Stars-тарифы)."
                elif [ -n "$pt" ]; then
                    bot_set PAY_PROVIDER_TOKEN "$(printf '%s' "$pt" | tr -d '[:space:]')"
                    echo "  ✅ Токен провайдера сохранён."
                fi
                ask pc "  Валюта провайдера (RUB/USD/EUR..., сейчас $cur): "
                if [ -n "$pc" ]; then
                    pc=$(printf '%s' "$pc" | tr 'a-z' 'A-Z' | tr -d '[:space:]')
                    [[ "$pc" =~ ^[A-Z]{3}$ ]] && { bot_set PAY_CURRENCY "$pc"; echo "  ✅ Валюта: $pc"; } || echo "  ❌ Код валюты — 3 буквы."
                fi
                bot_restart
                pause ;;
            6)
                echo ""
                echo "  Привязки (tg_id → пользователь):"
                local i=0 tgid u ts
                local -a unb_ids=()
                while IFS='|' read -r tgid u ts; do
                    [ -n "$tgid" ] && [ -n "$u" ] || continue   # пропускаем tombstone-отвязки
                    i=$((i+1)); unb_ids[$i]="$tgid"
                    printf "    %d. tg:%s → %s (с %s)\n" "$i" "$tgid" "$u" "$(date -d "@${ts:-0}" '+%Y-%m-%d' 2>/dev/null || echo '?')"
                done < "$TGUSERS_FILE" 2>/dev/null
                [ "$i" -eq 0 ] && echo "    (пусто)"
                echo ""
                local sel; ask sel "  Номер для ОТВЯЗКИ (Enter — назад): "
                if [[ "$sel" =~ ^[0-9]+$ ]] && [ -n "${unb_ids[$sel]:-}" ]; then
                    tg_unbind "${unb_ids[$sel]}"
                    echo "  ✅ Отвязано."
                fi
                pause ;;
            7)
                echo ""
                local u code
                ask u "  Имя пользователя: "
                if db_user_exists "$u" || is_user_disabled "$u"; then
                    code=$(bot_bind_code "$u")
                    un=$(bot_get BOT_USERNAME)
                    echo "  🎫 Код (48 ч): $code"
                    echo "     Клиент отправляет боту: /start $code"
                    [ -n "$un" ] && echo "     Или по ссылке: https://t.me/${un}?start=${code}"
                else
                    echo "  ❌ Пользователь не найден."
                fi
                pause ;;
            8)
                BOT_TOKEN=$(bot_token)
                if [ -n "$BOT_TOKEN" ]; then
                    bot_notify_admins "✅ Тест: менеджер на «$(tg_esc "$(node_name 2>/dev/null || hostname -s)")» видит бота."
                    echo "  📨 Отправлено (если админы верны и бот запущен /start-ом у них)."
                else
                    echo "  ❌ Токен не задан."
                fi
                pause ;;
            9)
                echo ""
                tail -n 25 "$BOT_LOG" 2>/dev/null | sed 's/^/  /' || echo "  (лог пуст)"
                pause ;;
            0) return ;;
            *) echo "  ❌ Неверный выбор!"; sleep 1 ;;
        esac
    done
}

# Подменю тарифов.
bot_tariffs_menu() {
    while true; do
        clear
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  💰 Тарифы бота (что видит клиент в /buy)"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        local i=0 code title days devices price cur
        local -a t_codes=()
        while IFS='|' read -r code title days devices price cur; do
            [ -n "$code" ] || continue
            i=$((i+1)); t_codes[$i]="$code"
            printf "    %d. [%s] %s — %s дн., устройств: %s, цена: %s\n" \
                "$i" "$code" "$title" "$days" "$devices" "$(tariff_price_str "$price" "$cur")"
        done < <(tariff_list)
        [ "$i" -eq 0 ] && echo "    (тарифов нет — клиенты не смогут купить доступ)"
        echo ""
        echo "  Валюта XTR = Telegram Stars (работают сразу). RUB/USD/… — нужен"
        echo "  платёжный токен провайдера (меню бота, пункт 5). У одного тарифа"
        echo "  можно задать НЕСКОЛЬКО цен (напр. XTR и RUB) — клиент выберет способ."
        echo ""
        echo "  1. ➕ Добавить тариф"
        echo "  2. ✏️  Редактировать тариф (цены/название/дни/устройства/валюты/код)"
        echo "  3. ↕️  Переместить тариф (вверх/вниз или на позицию N)"
        echo "  4. ➖ Удалить тариф (по номеру)"
        echo "  5. 🧩 Создать типовые тарифы-примеры (Stars: 30/90/365 дней)"
        echo "  0. ↩  Назад"
        echo ""
        local ch; ask ch "  Выберите: "
        case "$ch" in
            1)
                echo ""
                local c t d dv p cu
                ask c  "  Код (латиница, напр. m1): "
                [[ "$c" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "  ❌ Код: латиница/цифры."; pause; continue; }
                ask t  "  Название (видит клиент, напр. «1 месяц»): "
                [ -n "$t" ] || { echo "  ❌ Название пустое."; pause; continue; }
                t=$(printf '%s' "$t" | tr -d '|')
                ask d  "  Дней доступа: "
                [[ "$d" =~ ^[0-9]+$ ]] && [ "$d" -gt 0 ] || { echo "  ❌ Дни — число > 0."; pause; continue; }
                ask dv "  Лимит устройств (0 — не менять при покупке): "
                [[ "$dv" =~ ^[0-9]+$ ]] || dv=0
                tariff_ask_prices || { pause; continue; }
                if printf '%s' "$_TCUR" | tr '/' '\n' | grep -qvx 'XTR' && [ -z "$(bot_get PAY_PROVIDER_TOKEN)" ]; then
                    echo "  ⚠️  Провайдер не настроен — не-XTR цены не будут продаваться, пока не зададите токен (меню бота → 5)."
                fi
                tariff_add "$c" "$t" "$d" "$dv" "$_TPRICE" "$_TCUR"
                echo "  ✅ Тариф [$c] сохранён ($(tariff_price_str "$_TPRICE" "$_TCUR"))."
                bot_restart
                pause ;;
            2)
                local sel; ask sel "  Номер тарифа для редактирования: "
                if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ -z "${t_codes[$sel]:-}" ]; then
                    echo "  ❌ Неверный номер."; pause; continue
                fi
                local ocode="${t_codes[$sel]}" ec et ed edv ep ecu
                IFS='|' read -r ec et ed edv ep ecu <<<"$(tariff_get "$ocode")"
                echo ""
                echo "  Редактирование [$ocode]. Enter — оставить текущее значение."
                local nc nt nd ndv np ncu
                ask nc  "  Код [$ec]: ";        nc="${nc:-$ec}"
                [[ "$nc" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "  ❌ Код: латиница/цифры."; pause; continue; }
                if [ "$nc" != "$ec" ] && [ -n "$(tariff_get "$nc")" ]; then
                    echo "  ❌ Код [$nc] уже занят другим тарифом."; pause; continue
                fi
                ask nt  "  Название [$et]: ";   nt="${nt:-$et}"; nt=$(printf '%s' "$nt" | tr -d '|')
                [ -n "$nt" ] || { echo "  ❌ Название пустое."; pause; continue; }
                ask nd  "  Дней доступа [$ed]: "; nd="${nd:-$ed}"
                [[ "$nd" =~ ^[0-9]+$ ]] && [ "$nd" -gt 0 ] || { echo "  ❌ Дни — число > 0."; pause; continue; }
                ask ndv "  Лимит устройств [$edv] (0 — не менять при покупке): "; ndv="${ndv:-$edv}"
                [[ "$ndv" =~ ^[0-9]+$ ]] || ndv=0
                echo "  Текущие цены: $(tariff_price_str "$ep" "$ecu")"
                tariff_ask_prices "$ecu" "$ep" || { pause; continue; }
                if printf '%s' "$_TCUR" | tr '/' '\n' | grep -qvx 'XTR' && [ -z "$(bot_get PAY_PROVIDER_TOKEN)" ]; then
                    echo "  ⚠️  Провайдер не настроен — не-XTR цены не будут продаваться, пока не зададите токен (меню бота → 5)."
                fi
                tariff_update "$ocode" "$nc" "$nt" "$nd" "$ndv" "$_TPRICE" "$_TCUR"
                echo "  ✅ Тариф [$nc] обновлён ($(tariff_price_str "$_TPRICE" "$_TCUR"))."
                bot_restart
                pause ;;
            3)
                local sel; ask sel "  Номер тарифа для перемещения: "
                if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ -z "${t_codes[$sel]:-}" ]; then
                    echo "  ❌ Неверный номер."; pause; continue
                fi
                local dir; ask dir "  Куда: u — вверх, d — вниз, или НОМЕР позиции (напр. 1): "
                if [[ "$dir" =~ ^[0-9]+$ ]]; then
                    if tariff_move_to "${t_codes[$sel]}" "$dir"; then echo "  ✅ Тариф на позиции $dir."; bot_restart; else echo "  ❌ Не удалось переместить."; fi
                elif [[ "$dir" =~ ^(u|U|up|вверх)$ ]]; then
                    if tariff_move "${t_codes[$sel]}" up;   then echo "  ✅ Перемещён вверх."; bot_restart; else echo "  ⚠️  Тариф уже первый."; fi
                elif [[ "$dir" =~ ^(d|D|down|вниз)$ ]]; then
                    if tariff_move "${t_codes[$sel]}" down; then echo "  ✅ Перемещён вниз.";  bot_restart; else echo "  ⚠️  Тариф уже последний."; fi
                else
                    echo "  ❌ Введите u, d или номер позиции."
                fi
                pause ;;
            4)
                local sel; ask sel "  Номер тарифа для удаления: "
                if [[ "$sel" =~ ^[0-9]+$ ]] && [ -n "${t_codes[$sel]:-}" ]; then
                    tariff_del "${t_codes[$sel]}"
                    echo "  ✅ Удалён."
                    bot_restart
                else
                    echo "  ❌ Неверный номер."
                fi
                pause ;;
            5)
                tariff_add m1  "1 месяц"   30  0 100  XTR
                tariff_add m3  "3 месяца"  90  0 250  XTR
                tariff_add y1  "1 год"     365 0 800  XTR
                echo "  ✅ Созданы примеры (Stars): m1/m3/y1. Отредактируйте цены под себя."
                bot_restart
                pause ;;
            0) return ;;
            *) echo "  ❌ Неверный выбор!"; sleep 1 ;;
        esac
    done
}
