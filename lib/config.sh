#!/bin/bash
# ================================================
# Конфигурация и чтение данных из config.yaml
# ================================================

# UTF-8 локаль нужна, чтобы ${#str} считал символы (а не байты) — иначе
# выравнивание таблицы «плывёт» на эмодзи и кириллице. Выбираем доступную.
if [ -z "${LC_ALL:-}" ] || ! printf '%s' "$LC_ALL" | grep -qi 'utf-\?8'; then
    if locale -a 2>/dev/null | grep -qiE '^C\.utf-?8$'; then
        export LC_ALL=C.UTF-8
    elif locale -a 2>/dev/null | grep -qiE '^en_US\.utf-?8$'; then
        export LC_ALL=en_US.UTF-8
    fi
fi

CONFIG="/etc/hysteria/config.yaml"
SERVICE="hysteria-server.service"
DATA_DIR="/etc/hysteria/manager"
STATS_FILE="$DATA_DIR/stats.dat"
IPS_FILE="$DATA_DIR/ips.dat"
EXPIRY_FILE="$DATA_DIR/expiry.dat"
DISABLED_FILE="$DATA_DIR/disabled.dat"
LAST_LOG_TS="$DATA_DIR/last_log_ts"
API_SECRET_FILE="$DATA_DIR/api_secret"
# Текущая скорость (B/s) за последний интервал сбора и метка времени этого интервала
SPEED_FILE="$DATA_DIR/speed.dat"
SPEED_TS_FILE="$DATA_DIR/speed_ts"
# Маркер «есть изменения конфига, ожидающие перезапуска Hysteria».
# Используется только для правок, которые реально требуют рестарта (порт,
# SNI и т.п.). Управление пользователями работает БЕЗ перезапуска — см. ниже.
RESTART_PENDING_FILE="$DATA_DIR/restart_pending"
# База пользователей для внешней аутентификации (auth.type: command).
# Формат строки: «username:password». Hysteria дергает AUTH_SCRIPT на каждое
# подключение и проверяет пару по этому файлу — поэтому добавление/удаление
# пользователя применяется МГНОВЕННО, без рестарта сервера.
USERS_DB="$DATA_DIR/users.db"
AUTH_SCRIPT="$DATA_DIR/hysteria-auth.sh"

# ====================== ПОДПИСКА / КЛАСТЕР ======================
# Единая подписка: клиент добавляет ссылку https://<домен>/sub/<token>, а нода
# отдаёт base64-список всех ключей hysteria2:// этого юзера со всех серверов
# кластера. Раздаёт статику Caddy (авто-HTTPS), менеджер лишь перегенерирует
# файлы. См. lib/subscription.sh и lib/cluster.sh.
NODE_CONF="$DATA_DIR/node.conf"            # NODE_NAME / NODE_HOST(домен) / WEBROOT
CLUSTER_CONF="$DATA_DIR/cluster.conf"      # реестр пиров: строки «name|host»
CLUSTER_SECRET_FILE="$DATA_DIR/cluster.secret"  # общий секрет кластера (chmod 600)
SUBTOKENS_DB="$DATA_DIR/subtokens.db"      # «user:token» — секрет подписки юзера
CLUSTER_USERS_FILE="$DATA_DIR/cluster_users"    # имена «кластерных» юзеров
WEBROOT="/var/www/hy2sub"                   # корень статики Caddy (sub/ и cluster/)
                                            # отдельно от DATA_DIR: его читает caddy, не hysteria
PEERS_DIR="$DATA_DIR/peers"                 # кэш манифестов пиров
CADDYFILE="/etc/caddy/Caddyfile"

API_PORT=25580
PAGE_SIZE=10
# Интервал автообновления интерактивных меню (секунды)
REFRESH_INTERVAL=2

# ====================== ВВОД / ПРОМПТЫ ======================
# ВАЖНО: stderr перенаправлен в лог-файл (см. hy2-manager.sh), поэтому
# обычный `read -p` не годится — его промпт пишется в stderr и ушёл бы
# в лог, оставаясь невидимым для пользователя. Эти хелперы печатают
# промпт в stdout, поэтому он всегда виден.

# ask <имя_переменной> "<промпт>" [таймаут_сек]
# Возвращает код read (важно: при таймауте read -t код != 0 — это
# используется циклами меню как сигнал «обнови экран»).
ask() {
    local __ask_var="$1" __ask_msg="$2" __ask_to="${3:-}"
    printf '%s' "$__ask_msg"
    if [ -n "$__ask_to" ]; then
        read -r -t "$__ask_to" "$__ask_var"
    else
        read -r "$__ask_var"
    fi
}

# pause ["<сообщение>"] — «нажмите Enter», промпт виден в stdout
pause() {
    local __pause_msg="${1:-  Enter для продолжения...}"
    printf '%s' "$__pause_msg"
    read -r _
}

# is_yes <ответ> — подтверждение (принимаем да/yes/y в разных регистрах)
is_yes() {
    case "$1" in
        да|Да|ДА|д|Д|yes|Yes|YES|y|Y) return 0 ;;
        *) return 1 ;;
    esac
}

# ====================== ПЕРЕЗАПУСК HYSTERIA ======================
# Перезапуск ненадолго отключает ВСЕХ клиентов, поэтому делаем его явно,
# а не как побочный эффект каждой правки конфига.

mark_restart_pending()  { touch "$RESTART_PENDING_FILE" 2>/dev/null; }
clear_restart_pending() { rm -f "$RESTART_PENDING_FILE" 2>/dev/null; }
is_restart_pending()    { [ -f "$RESTART_PENDING_FILE" ]; }

# Перезапускает сервис Hysteria и снимает маркер ожидающих изменений.
restart_hysteria() {
    echo "  🔄 Перезапуск Hysteria 2 (всех клиентов кратковременно отключит)..."
    systemctl restart "$SERVICE" 2>/dev/null
    sleep 2
    clear_restart_pending
    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        echo "  ✅ Hysteria перезапущена, изменения применены"
    else
        echo "  ⚠️  Hysteria НЕ запустилась! journalctl -u $SERVICE -e"
    fi
}

# Помечает изменения как ожидающие и предлагает перезапустить сейчас.
# Вызывается после правок конфига (add/delete/disable/enable/смена пароля).
prompt_apply_restart() {
    mark_restart_pending
    echo ""
    echo "  ⚠️  Изменения вступят в силу только после перезапуска Hysteria."
    local __ans
    ask __ans "  Перезапустить сейчас? (отключит всех на пару секунд) (да/нет): "
    if is_yes "$__ans"; then
        restart_hysteria
    else
        echo "  ⏸  Перезапуск отложен. Применить позже: Настройки → Перезапустить Hysteria."
    fi
}

get_ip() {
    curl -4s --max-time 5 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}'
}

get_port() {
    grep -oP '(?<=listen: :)\d+' "$CONFIG" 2>/dev/null || echo "11478"
}

get_obfs_pass() {
    local result
    result=$(grep -oP '(?<=password: ")[^"]+' <(grep -A 5 "salamander:" "$CONFIG") 2>/dev/null | head -1)
    echo "${result:-}"
}

get_sni() {
    local result
    result=$(grep -oP '(?<=url: https://)[^/]+' "$CONFIG" 2>/dev/null | head -1)
    echo "${result:-www.twitch.tv}"
}

# Пароль активного пользователя берём из базы users.db (а не из config.yaml).
get_user_password() {
    awk -F: -v u="$1" '$1==u { print substr($0, length($1)+2); exit }' "$USERS_DB" 2>/dev/null
}

# Активные пользователи = строки users.db (отключённые тут не значатся).
get_active_users() {
    cut -d: -f1 "$USERS_DB" 2>/dev/null | grep -v '^$'
}

# Пары «user|pass» из секции userpass конфига — нужно ТОЛЬКО при разовой
# миграции со старого формата (auth.type: userpass) на users.db.
config_userpass_pairs() {
    awk '
        /^[[:space:]]*userpass:/ { in_block=1; next }
        in_block && /^[[:space:]]+[a-zA-Z0-9_-]+:/ {
            name=$0; sub(/^[[:space:]]+/, "", name); sub(/:.*/, "", name)
            pass=$0; sub(/^[^:]*:[[:space:]]*/, "", pass); gsub(/"/, "", pass); sub(/[[:space:]]+$/, "", pass)
            print name "|" pass
            next
        }
        in_block && /^[[:space:]]*[a-zA-Z]/ && !/^[[:space:]]+[a-zA-Z0-9_-]+:/ { in_block=0 }
        in_block && /^[a-zA-Z]/ { in_block=0 }
    ' "$CONFIG" 2>/dev/null
}

get_all_users() {
    {
        get_active_users
        cut -d'|' -f1 "$DISABLED_FILE" 2>/dev/null
    } | grep -v '^$' | sort -u
}
