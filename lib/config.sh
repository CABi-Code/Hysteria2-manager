#!/bin/bash
# ================================================
# Конфигурация и чтение данных из config.yaml
# ================================================

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

get_user_password() {
    grep -oP "^\s+${1}:\s*\"\K[^\"]*" "$CONFIG" 2>/dev/null
}

get_active_users() {
    awk '
        /^[[:space:]]*userpass:/ { in_block=1; next }
        in_block && /^[[:space:]]+[a-zA-Z0-9_-]+:/ {
            name=$0
            sub(/^[[:space:]]+/, "", name)
            sub(/:.*/, "", name)
            print name
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
