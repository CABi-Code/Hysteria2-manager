#!/bin/bash
# ================================================
# Telegram-бот, привязанный к менеджеру.
#
# Возможности:
#   • Клиент (после привязки по коду или после покупки):
#       — получить свою ссылку hysteria2:// и ссылку-подписку;
#       — посмотреть статус (трафик, срок, устройства, онлайн);
#       — купить/продлить доступ (Telegram Stars, провайдер BotFather —
#         ЮKassa, Stripe и т.д. — или личный кошелёк ЮMoney без провайдера,
#         docs/guide/YOOMONEY.md) — доступ выдаётся/продлевается автоматически.
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
#   bot.conf      BOT_TOKEN / ADMIN_IDS / PAY_PROVIDER_TOKEN / PAY_CURRENCY /
#                 YM_* (кошелёк ЮMoney, см. docs/guide/YOOMONEY.md) / ...
#   tariffs.conf  тарифы: «код|Название|дней|устройств|цена|валюта» (XTR = Stars;
#                 цена/валюта могут быть '/'-списками — несколько цен на тариф)
#   tgusers.dat   привязки: «tg_id|username|ts»
#   botcodes.dat  одноразовые коды привязки: «код|username|expires_ts»
#   payments.log  журнал оплат
#   ympay.dat     ждущие оплаты счета ЮMoney (см. lib/yoomoney.sh)
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
bot_get() { conf_get "$BOT_CONF" "$1"; }
bot_set() {   # key value
    local key="$1" val="$2" tmp
    mkdir -p "$DATA_DIR"; touch "$BOT_CONF"; chmod 600 "$BOT_CONF" 2>/dev/null
    tmp=$(mktemp) || return 1
    grep -v "^${key}=" "$BOT_CONF" > "$tmp" 2>/dev/null
    printf '%s=%s\n' "$key" "$val" >> "$tmp"
    cat "$tmp" > "$BOT_CONF"
    rm -f "$tmp"
}

# ---------- модули бота ----------
# BOT_MODULES — какие части бота включены (через запятую из sales/notify/admin).
# Ключа нет → включено ВСЁ: свежая установка продаёт из коробки, старые конфиги
# не меняют поведение. Смысл модулей и границу «модуль или ядро» см.
# docs/design/SALES/README.md. Ядро (привязка, фулфилмент пополнений мини-аппа,
# делегирование /start мини-аппу) не выключается — на нём держится надстройка.
bot_mod_on() {   # sales|notify|admin
    local v; v=$(bot_get BOT_MODULES)
    [ -n "$v" ] || return 0
    case ",$(printf '%s' "$v" | tr -d '[:space:]')," in *",$1,"*) return 0 ;; esac
    return 1
}

# Продаёт ли бот сам: модуль включён И есть что продавать. Тем же условием
# решается, упоминать ли /buy в уведомлениях.
bot_sales_on() { bot_mod_on sales && [ "$(tariff_count 2>/dev/null || echo 0)" -gt 0 ] 2>/dev/null; }

bot_token()    { bot_get BOT_TOKEN; }
bot_enabled()  { [ -n "$(bot_token)" ] && [ -f "$BOT_UNIT" ]; }
bot_running()  { systemctl is-active --quiet hy2-bot.service 2>/dev/null; }

# Является ли chat_id админом (список через запятую/пробел). При выключенном
# модуле admin админов для бота нет вообще — иначе гейт пришлось бы дублировать
# в каждой из восьми админ-команд демона, и новая забыла бы его.
bot_is_admin() {
    local id="$1" a
    bot_mod_on admin || return 1
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

# Разослать всем админам (модуль notify — с ним выключаются и алерты об оплатах).
bot_notify_admins() {
    local a
    bot_mod_on notify || return 0
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

