#!/bin/bash
# ================================================
# Hysteria 2 Manager v2.0
# Управление пользователями, статистика, IP-трекинг
# Сроки действия, защита от утечек
# ================================================

# === КОНФИГУРАЦИЯ ===
CONFIG="/etc/hysteria/config.yaml"
SERVICE="hysteria-server.service"
DATA_DIR="/etc/hysteria/manager"
STATS_FILE="$DATA_DIR/stats.dat"
IPS_FILE="$DATA_DIR/ips.dat"
EXPIRY_FILE="$DATA_DIR/expiry.dat"
DISABLED_FILE="$DATA_DIR/disabled.dat"
LAST_LOG_TS="$DATA_DIR/last_log_ts"
API_SECRET_FILE="$DATA_DIR/api_secret"
API_PORT=25580
PAGE_SIZE=10

# === ПРОВЕРКА ЗАВИСИМОСТЕЙ ===
for cmd in pwgen jq; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "📦 Устанавливаю $cmd..."
        apt update -qq && apt install -y "$cmd" -qq
    fi
done

# === СОЗДАНИЕ ДИРЕКТОРИЙ ===
mkdir -p "$DATA_DIR"
for f in "$STATS_FILE" "$IPS_FILE" "$EXPIRY_FILE" "$DISABLED_FILE"; do
    [ -f "$f" ] || touch "$f"
done

# ====================== ЧТЕНИЕ КОНФИГА ======================

get_ip() {
    curl -4s --max-time 5 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}'
}

get_port() {
    grep -oP '(?<=listen: :)\d+' "$CONFIG" 2>/dev/null || echo "11478"
}

get_obfs_pass() {
    grep -oP '(?<=password: ")[^"]+' <(grep -A 5 "salamander:" "$CONFIG") 2>/dev/null | head -1
}

get_sni() {
    grep -oP '(?<=url: https://)[^/]+' "$CONFIG" 2>/dev/null | head -1 || echo "www.microsoft.com"
}

get_user_password() {
    grep -oP "^    ${1}:\s*\"\K[^\"]*" "$CONFIG" 2>/dev/null
}

get_active_users() {
    awk '
        /^  userpass:/ { in_block=1; next }
        in_block && /^    [a-zA-Z0-9_-]+:/ {
            sub(/^[ \t]+/, "")
            sub(/:.*/, "")
            print
        }
        in_block && /^  [a-zA-Z]/ { in_block=0 }
        in_block && /^[a-zA-Z]/ { in_block=0 }
    ' "$CONFIG" 2>/dev/null
}

get_all_users() {
    {
        get_active_users
        cut -d'|' -f1 "$DISABLED_FILE" 2>/dev/null
    } | grep -v '^$' | sort -u
}

# ====================== API ФУНКЦИИ ======================

get_api_secret() {
    [ -f "$API_SECRET_FILE" ] && cat "$API_SECRET_FILE"
}

setup_stats_api() {
    if ! grep -q '^trafficStats:' "$CONFIG" 2>/dev/null; then
        local secret
        secret=$(pwgen -s 32 1)
        echo "$secret" > "$API_SECRET_FILE"
        chmod 600 "$API_SECRET_FILE"
        {
            echo ""
            echo "trafficStats:"
            echo "  listen: 127.0.0.1:$API_PORT"
            echo "  secret: $secret"
        } >> "$CONFIG"
        systemctl restart "$SERVICE" 2>/dev/null
        sleep 2
    else
        local secret port
        secret=$(awk '/^trafficStats:/,/^[a-zA-Z]/' "$CONFIG" | grep -oP 'secret:\s*\K\S+' | tr -d '"' | head -1)
        port=$(awk '/^trafficStats:/,/^[a-zA-Z]/' "$CONFIG" | grep 'listen' | grep -oP '\d+' | tail -1)
        [ -n "$secret" ] && echo "$secret" > "$API_SECRET_FILE" && chmod 600 "$API_SECRET_FILE"
        [ -n "$port" ] && API_PORT="$port"
    fi
}

api_get() {
    local secret
    secret=$(get_api_secret)
    curl -s --max-time 3 -H "Authorization: $secret" "http://127.0.0.1:${API_PORT}${1}" 2>/dev/null
}

api_post() {
    local secret
    secret=$(get_api_secret)
    curl -s --max-time 3 -X POST -H "Authorization: $secret" \
        -H "Content-Type: application/json" -d "$2" \
        "http://127.0.0.1:${API_PORT}${1}" 2>/dev/null
}

# ====================== СБОР ТРАФИКА ======================

collect_traffic() {
    local response
    response=$(api_get "/traffic?clear=1")
    [ -z "$response" ] || [ "$response" = "null" ] && return

    echo "$response" | jq -r 'to_entries[] | "\(.key)|\(.value.tx // 0)|\(.value.rx // 0)"' 2>/dev/null | \
    while IFS='|' read -r user tx rx; do
        [ -z "$user" ] && continue
        tx=${tx:-0}; rx=${rx:-0}
        [[ "$tx" =~ ^[0-9]+$ ]] || tx=0
        [[ "$rx" =~ ^[0-9]+$ ]] || rx=0
        [ "$tx" -eq 0 ] && [ "$rx" -eq 0 ] && continue

        if grep -q "^${user}|" "$STATS_FILE"; then
            local old_tx old_rx new_tx new_rx
            old_tx=$(grep "^${user}|" "$STATS_FILE" | head -1 | cut -d'|' -f2)
            old_rx=$(grep "^${user}|" "$STATS_FILE" | head -1 | cut -d'|' -f3)
            new_tx=$(( ${old_tx:-0} + tx ))
            new_rx=$(( ${old_rx:-0} + rx ))
            sed -i "s#^${user}|.*#${user}|${new_tx}|${new_rx}#" "$STATS_FILE"
        else
            echo "${user}|${tx}|${rx}" >> "$STATS_FILE"
        fi
    done
}

get_user_traffic() {
    local line
    line=$(grep "^${1}|" "$STATS_FILE" 2>/dev/null | head -1)
    if [ -n "$line" ]; then
        echo "$line"
    else
        echo "${1}|0|0"
    fi
}

format_bytes() {
    local bytes=${1:-0}
    [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
    if [ "$bytes" -ge 1073741824 ]; then
        awk "BEGIN {printf \"%.1fG\", $bytes / 1073741824}"
    elif [ "$bytes" -ge 1048576 ]; then
        awk "BEGIN {printf \"%.1fM\", $bytes / 1048576}"
    elif [ "$bytes" -ge 1024 ]; then
        awk "BEGIN {printf \"%.1fK\", $bytes / 1024}"
    else
        echo "${bytes}B"
    fi
}

# ====================== IP-ТРЕКИНГ ======================

collect_ips() {
    local since_opt=""
    if [ -f "$LAST_LOG_TS" ]; then
        since_opt="--since=$(cat "$LAST_LOG_TS")"
    else
        since_opt="--since=30 days ago"
    fi
    date '+%Y-%m-%d %H:%M:%S' > "$LAST_LOG_TS"

    journalctl -u "$SERVICE" --no-pager -o cat $since_opt 2>/dev/null | \
    grep -E '"(addr|remote|client)"' | grep -E '"username"' | \
    while read -r line; do
        local ip user
        ip=$(echo "$line" | grep -oP '"(?:addr|remote|client)"\s*:\s*"\K[\d.]+' | head -1)
        user=$(echo "$line" | grep -oP '"username"\s*:\s*"\K[^"]+' | head -1)
        [ -z "$ip" ] || [ -z "$user" ] || [ "$ip" = "127.0.0.1" ] && continue

        local now
        now=$(date +%s)
        if grep -q "^${user}|${ip}|" "$IPS_FILE"; then
            local old_line first_seen old_count new_count
            old_line=$(grep "^${user}|${ip}|" "$IPS_FILE" | head -1)
            first_seen=$(echo "$old_line" | cut -d'|' -f3)
            old_count=$(echo "$old_line" | cut -d'|' -f5)
            new_count=$(( ${old_count:-0} + 1 ))
            sed -i "s#^${user}|${ip}|.*#${user}|${ip}|${first_seen}|${now}|${new_count}#" "$IPS_FILE"
        else
            echo "${user}|${ip}|${now}|${now}|1" >> "$IPS_FILE"
        fi
    done
}

get_user_ip_count() {
    grep -c "^${1}|" "$IPS_FILE" 2>/dev/null || echo "0"
}

get_user_ips() {
    grep "^${1}|" "$IPS_FILE" 2>/dev/null
}

# ====================== ОНЛАЙН СТАТУС ======================

refresh_online() {
    CACHED_ONLINE=$(api_get "/online")
}

get_user_online_count() {
    echo "${CACHED_ONLINE:-{}}" | jq -r ".[\"${1}\"] // 0" 2>/dev/null || echo "0"
}

# ====================== УПРАВЛЕНИЕ СРОКАМИ ======================

set_user_expiry() {
    local user="$1" date="$2"
    sed -i "/^${user}|/d" "$EXPIRY_FILE"
    echo "${user}|${date}" >> "$EXPIRY_FILE"
}

get_user_expiry() {
    grep "^${1}|" "$EXPIRY_FILE" 2>/dev/null | head -1 | cut -d'|' -f2
}

remove_user_expiry() {
    sed -i "/^${1}|/d" "$EXPIRY_FILE"
}

check_expired_users() {
    local today changed=false
    today=$(date +%Y-%m-%d)
    while IFS='|' read -r user exp_date; do
        [ -z "$user" ] || [ -z "$exp_date" ] && continue
        if [[ "$exp_date" < "$today" || "$exp_date" == "$today" ]]; then
            if ! is_user_disabled "$user" && grep -q "^    ${user}: " "$CONFIG"; then
                disable_user "$user" silent
                echo "⏰ Автоотключение: $user (срок: $exp_date)"
                changed=true
            fi
        fi
    done < "$EXPIRY_FILE"
    if $changed; then
        systemctl restart "$SERVICE" 2>/dev/null
        sleep 2
    fi
}

# ====================== УПРАВЛЕНИЕ ПОЛЬЗОВАТЕЛЯМИ ======================

is_user_disabled() {
    grep -q "^${1}|" "$DISABLED_FILE" 2>/dev/null
}

get_disabled_password() {
    grep "^${1}|" "$DISABLED_FILE" 2>/dev/null | head -1 | cut -d'|' -f2
}

disable_user() {
    local user="$1" silent="$2"
    local password
    password=$(get_user_password "$user")
    if [ -z "$password" ]; then
        [ "$silent" != "silent" ] && echo "  ❌ Пользователь $user не найден в конфиге"
        return 1
    fi
    grep -q "^${user}|" "$DISABLED_FILE" || echo "${user}|${password}" >> "$DISABLED_FILE"
    sed -i "/^    ${user}: \"/d" "$CONFIG"
    api_post "/kick" "[\"$user\"]" &>/dev/null
    [ "$silent" != "silent" ] && echo "  ✅ Пользователь $user отключён"
}

enable_user() {
    local user="$1"
    if ! is_user_disabled "$user"; then
        echo "  ❌ $user не в списке отключённых"
        return 1
    fi
    local password
    password=$(get_disabled_password "$user")
    sed -i "/^  userpass:/a\\    ${user}: \"${password}\"" "$CONFIG"
    sed -i "/^${user}|/d" "$DISABLED_FILE"
    echo "  ✅ Пользователь $user включён"
}

delete_user() {
    local user="$1"
    sed -i "/^    ${user}: \"/d" "$CONFIG"
    sed -i "/^${user}|/d" "$DISABLED_FILE" "$STATS_FILE" "$IPS_FILE" "$EXPIRY_FILE"
    api_post "/kick" "[\"$user\"]" &>/dev/null
    echo "  ✅ Пользователь $user полностью удалён"
}

reset_user_stats() {
    local user="$1"
    sed -i "/^${user}|/d" "$STATS_FILE" "$IPS_FILE"
    echo "  ✅ Статистика $user сброшена"
}

change_user_password() {
    local user="$1"
    local new_pass
    new_pass=$(pwgen -s 64 1)
    if is_user_disabled "$user"; then
        sed -i "s#^${user}|.*#${user}|${new_pass}#" "$DISABLED_FILE"
    else
        if ! grep -q "^    ${user}: " "$CONFIG"; then
            echo "  ❌ Пользователь не найден"
            return 1
        fi
        sed -i "/^    ${user}: \"/d" "$CONFIG"
        sed -i "/^  userpass:/a\\    ${user}: \"${new_pass}\"" "$CONFIG"
    fi
    echo "  ✅ Пароль $user обновлён"
    echo "  🔑 Новый: ${new_pass}"
}

# ====================== CRON АВТОМАТИЗАЦИЯ ======================

setup_cron() {
    local script_path
    script_path=$(realpath "$0" 2>/dev/null || readlink -f "$0" 2>/dev/null || echo "$0")
    if ! crontab -l 2>/dev/null | grep -q "hy2-manager.*--collect"; then
        (crontab -l 2>/dev/null; echo "*/30 * * * * /bin/bash \"$script_path\" --collect >/dev/null 2>&1") | crontab -
    fi
    if ! crontab -l 2>/dev/null | grep -q "hy2-manager.*--check-expiry"; then
        (crontab -l 2>/dev/null; echo "0 */6 * * * /bin/bash \"$script_path\" --check-expiry >/dev/null 2>&1") | crontab -
    fi
}

# ====================== АВТОМИГРАЦИЯ AUTH ======================

migrate_auth() {
    if grep -q 'type: password' "$CONFIG" 2>/dev/null; then
        echo "⚠️  Обнаружен старый тип auth: password"
        echo "   Переключаю на userpass..."
        sed -i 's/type: password/type: userpass/' "$CONFIG"
        sed -i '/^  password:/d' "$CONFIG"
        if ! grep -q '^  userpass:' "$CONFIG"; then
            sed -i '/^auth:/a \  userpass:' "$CONFIG"
        fi
        echo "✅ Переключено на userpass."
    fi
    # Убедимся что userpass блок существует
    if ! grep -q '^  userpass:' "$CONFIG" 2>/dev/null; then
        if grep -q '^auth:' "$CONFIG"; then
            sed -i '/^auth:/a \  userpass:' "$CONFIG"
        fi
    fi
}

# ====================== CLI АРГУМЕНТЫ ======================

if [ "$1" = "--check-expiry" ]; then
    setup_stats_api
    check_expired_users
    exit 0
fi

if [ "$1" = "--collect" ]; then
    setup_stats_api
    collect_traffic
    collect_ips
    exit 0
fi

# ====================== ИНИЦИАЛИЗАЦИЯ ======================

migrate_auth
setup_stats_api
collect_traffic
collect_ips
check_expired_users
setup_cron

CACHED_IP=$(get_ip)
CACHED_PORT=$(get_port)
CACHED_OBFS=$(get_obfs_pass)
CACHED_SNI=$(get_sni)
refresh_online

# ====================== ОТОБРАЖЕНИЕ ТАБЛИЦЫ ======================

declare -a USER_LIST_ARRAY
USER_LIST_PAGES=1
USER_LIST_TOTAL=0

show_user_table() {
    local page=${1:-1}
    local title="$2"

    USER_LIST_ARRAY=()
    while IFS= read -r u; do
        [ -n "$u" ] && USER_LIST_ARRAY+=("$u")
    done <<< "$(get_all_users)"

    USER_LIST_TOTAL=${#USER_LIST_ARRAY[@]}
    USER_LIST_PAGES=$(( (USER_LIST_TOTAL + PAGE_SIZE - 1) / PAGE_SIZE ))
    [ "$USER_LIST_PAGES" -eq 0 ] && USER_LIST_PAGES=1
    [ "$page" -gt "$USER_LIST_PAGES" ] && page=$USER_LIST_PAGES
    [ "$page" -lt 1 ] && page=1

    local start=$(( (page - 1) * PAGE_SIZE ))
    local end=$(( start + PAGE_SIZE ))
    [ "$end" -gt "$USER_LIST_TOTAL" ] && end=$USER_LIST_TOTAL

    clear
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ${title:-Пользователи} (стр. $page/$USER_LIST_PAGES, всего: $USER_LIST_TOTAL)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "  %-4s %-18s %-11s %-20s %-6s %-12s\n" "No" "Имя" "Статус" "Трафик" "IPs" "Истекает"
    echo "  ──────────────────────────────────────────────────────────────────────────────"

    if [ "$USER_LIST_TOTAL" -eq 0 ]; then
        echo "  Нет пользователей."
        return 1
    fi

    for ((i=start; i<end; i++)); do
        local user="${USER_LIST_ARRAY[$i]}"
        local num=$((i + 1))
        local status traffic ipc expiry

        if is_user_disabled "$user"; then
            status="🔴 ВЫКЛ"
        else
            local oc
            oc=$(get_user_online_count "$user")
            if [ "${oc:-0}" -gt 0 ] 2>/dev/null; then
                status="🟢 ON(${oc})"
            else
                status="⚫ OFF"
            fi
        fi

        local tl tx rx
        tl=$(get_user_traffic "$user")
        tx=$(echo "$tl" | cut -d'|' -f2)
        rx=$(echo "$tl" | cut -d'|' -f3)
        traffic="↑$(format_bytes "$tx") ↓$(format_bytes "$rx")"

        ipc=$(get_user_ip_count "$user")

        expiry=$(get_user_expiry "$user")
        [ -z "$expiry" ] && expiry="—"

        printf "  %-4s %-18s %-11s %-20s %-6s %-12s\n" "$num" "$user" "$status" "$traffic" "$ipc" "$expiry"
    done

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    return 0
}

# ====================== ПОДМЕНЮ ДЕЙСТВИЙ ======================

user_action_menu() {
    local user="$1"
    while true; do
        clear
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Пользователь: $user"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        if is_user_disabled "$user"; then
            echo "  Статус:       🔴 ОТКЛЮЧЁН"
        else
            local oc
            oc=$(get_user_online_count "$user")
            if [ "${oc:-0}" -gt 0 ] 2>/dev/null; then
                echo "  Статус:       🟢 ОНЛАЙН ($oc подключений)"
            else
                echo "  Статус:       ⚫ ОФФЛАЙН"
            fi
        fi

        local tl tx rx
        tl=$(get_user_traffic "$user")
        tx=$(echo "$tl" | cut -d'|' -f2)
        rx=$(echo "$tl" | cut -d'|' -f3)
        echo "  Трафик:       ↑$(format_bytes "$tx") / ↓$(format_bytes "$rx")"

        local ipc
        ipc=$(get_user_ip_count "$user")
        echo "  Уникальных IP: $ipc"
        if [ "$ipc" -gt 3 ] 2>/dev/null; then
            echo "  ⚠️  Подозрительно много IP — возможна утечка!"
        fi

        local exp
        exp=$(get_user_expiry "$user")
        echo "  Срок действия: ${exp:-не установлен}"

        echo ""
        if is_user_disabled "$user"; then
            echo "  1. ✅ Включить"
        else
            echo "  1. 🔴 Отключить"
        fi
        echo "  2. 🔑 Сменить пароль"
        echo "  3. 🗑  Удалить полностью"
        echo "  4. 📊 Сбросить статистику"
        echo "  5. ⏰ Установить срок действия"
        echo "  6. 🌐 Просмотр IP-адресов"
        echo "  7. 🔗 Получить ссылку"
        echo "  8. ↩  Назад"
        echo ""
        read -p "  Действие: " act

        case "$act" in
            1)
                if is_user_disabled "$user"; then
                    enable_user "$user"
                else
                    disable_user "$user"
                fi
                systemctl restart "$SERVICE" 2>/dev/null
                sleep 2
                refresh_online
                read -p "  Enter для продолжения..."
                ;;
            2)
                change_user_password "$user"
                if ! is_user_disabled "$user"; then
                    systemctl restart "$SERVICE" 2>/dev/null
                    sleep 2
                fi
                echo "  ⚠️  Пользователю нужна новая ссылка!"
                read -p "  Enter для продолжения..."
                ;;
            3)
                read -p "  ⚠️  Удалить $user ПОЛНОСТЬЮ? (да/нет): " confirm
                if [ "$confirm" = "да" ]; then
                    local was_active=false
                    grep -q "^    ${user}: " "$CONFIG" && was_active=true
                    delete_user "$user"
                    if $was_active; then
                        systemctl restart "$SERVICE" 2>/dev/null
                        sleep 2
                    fi
                    read -p "  Enter для продолжения..."
                    return
                fi
                ;;
            4)
                read -p "  Сбросить статистику $user? (да/нет): " confirm
                [ "$confirm" = "да" ] && reset_user_stats "$user"
                read -p "  Enter для продолжения..."
                ;;
            5)
                echo ""
                local cur_exp
                cur_exp=$(get_user_expiry "$user")
                [ -n "$cur_exp" ] && echo "  Текущий срок: $cur_exp"
                read -p "  Новая дата (ГГГГ-ММ-ДД, или 'нет' для снятия): " new_exp
                if [ "$new_exp" = "нет" ]; then
                    remove_user_expiry "$user"
                    echo "  ✅ Срок действия снят"
                elif [[ "$new_exp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
                    set_user_expiry "$user" "$new_exp"
                    echo "  ✅ Срок действия: $new_exp"
                else
                    echo "  ❌ Неверный формат даты"
                fi
                read -p "  Enter для продолжения..."
                ;;
            6)
                echo ""
                echo "  🌐 IP-адреса пользователя $user:"
                echo "  ────────────────────────────────────────────────────────"
                local ips
                ips=$(get_user_ips "$user")
                if [ -z "$ips" ]; then
                    echo "  Нет данных об IP-адресах."
                else
                    printf "  %-16s %-20s %-20s %s\n" "IP-адрес" "Первое подкл." "Последнее" "Раз"
                    echo "$ips" | while IFS='|' read -r _ ip fs ls cnt; do
                        local fs_fmt ls_fmt
                        fs_fmt=$(date -d "@$fs" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "—")
                        ls_fmt=$(date -d "@$ls" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "—")
                        printf "  %-16s %-20s %-20s %s\n" "$ip" "$fs_fmt" "$ls_fmt" "$cnt"
                    done

                    local total_ips recent_ips week_ago
                    total_ips=$(echo "$ips" | wc -l)
                    week_ago=$(date -d '7 days ago' +%s 2>/dev/null || echo 0)
                    recent_ips=$(echo "$ips" | awk -F'|' -v wa="$week_ago" '$4 >= wa' | wc -l)
                    echo ""
                    echo "  📊 Всего уникальных IP: $total_ips"
                    echo "  📊 Активных за 7 дней: $recent_ips"

                    if [ "$total_ips" -gt 5 ]; then
                        echo ""
                        echo "  🚨 ВНИМАНИЕ: $total_ips уникальных IP!"
                        echo "  Высокая вероятность шаринга аккаунта."
                    elif [ "$total_ips" -gt 3 ]; then
                        echo ""
                        echo "  ⚠️  Обнаружено $total_ips уникальных IP."
                        echo "  Возможна утечка учётных данных."
                    fi
                fi
                echo ""
                read -p "  Enter для продолжения..."
                ;;
            7)
                local pass
                if is_user_disabled "$user"; then
                    pass=$(get_disabled_password "$user")
                    echo "  ⚠️  Пользователь отключён! Ссылка не будет работать."
                else
                    pass=$(get_user_password "$user")
                fi
                if [ -n "$pass" ]; then
                    local link="hysteria2://${user}:${pass}@${CACHED_IP}:${CACHED_PORT}/?obfs=salamander&obfs-password=${CACHED_OBFS}&sni=${CACHED_SNI}&insecure=1#${user}"
                    echo ""
                    echo "  🔗 ССЫЛКА:"
                    echo "  $link"
                    echo ""
                    echo "  💡 Hiddify, Nekobox, Streisand и т.д."
                else
                    echo "  ❌ Не удалось получить пароль"
                fi
                read -p "  Enter для продолжения..."
                ;;
            8) return ;;
        esac
    done
}

# ====================== СПИСОК ПОЛЬЗОВАТЕЛЕЙ ======================

user_list_menu() {
    local page=1
    while true; do
        refresh_online
        show_user_table "$page" "Пользователи — статистика и действия"
        local ret=$?
        if [ $ret -ne 0 ]; then
            echo ""
            read -p "  Enter для возврата..."
            return
        fi

        echo "  [n] след. стр. | [p] пред. | [номер] действия | [q] назад"
        echo ""
        read -p "  Ввод: " input

        case "$input" in
            q|Q) return ;;
            n|N) ((page++)); [ "$page" -gt "$USER_LIST_PAGES" ] && page=$USER_LIST_PAGES ;;
            p|P) ((page--)); [ "$page" -lt 1 ] && page=1 ;;
            *)
                if [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 1 ] && [ "$input" -le "$USER_LIST_TOTAL" ] 2>/dev/null; then
                    user_action_menu "${USER_LIST_ARRAY[$((input - 1))]}"
                fi
                ;;
        esac
    done
}

# ====================== ПОЛУЧЕНИЕ ССЫЛКИ ======================

get_link_menu() {
    local page=1
    while true; do
        show_user_table "$page" "Выберите пользователя для получения ссылки"
        local ret=$?
        if [ $ret -ne 0 ]; then
            echo ""
            read -p "  Enter для возврата..."
            return
        fi

        echo "  [n] след. стр. | [p] пред. | [номер] ссылка | [q] назад"
        echo ""
        read -p "  Номер: " input

        case "$input" in
            q|Q) return ;;
            n|N) ((page++)); [ "$page" -gt "$USER_LIST_PAGES" ] && page=$USER_LIST_PAGES ;;
            p|P) ((page--)); [ "$page" -lt 1 ] && page=1 ;;
            *)
                if [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 1 ] && [ "$input" -le "$USER_LIST_TOTAL" ] 2>/dev/null; then
                    local sel_user="${USER_LIST_ARRAY[$((input - 1))]}"
                    local pass
                    if is_user_disabled "$sel_user"; then
                        pass=$(get_disabled_password "$sel_user")
                        echo ""
                        echo "  ⚠️  $sel_user отключён! Ссылка не будет работать."
                    else
                        pass=$(get_user_password "$sel_user")
                    fi
                    if [ -n "$pass" ]; then
                        local link="hysteria2://${sel_user}:${pass}@${CACHED_IP}:${CACHED_PORT}/?obfs=salamander&obfs-password=${CACHED_OBFS}&sni=${CACHED_SNI}&insecure=1#${sel_user}"
                        echo ""
                        echo "  🔗 ССЫЛКА для $sel_user:"
                        echo "  $link"
                        echo ""
                        echo "  💡 Hiddify, Nekobox, Streisand и т.д."
                    else
                        echo "  ❌ Ошибка получения пароля"
                    fi
                    read -p "  Enter для продолжения..."
                fi
                ;;
        esac
    done
}

# ====================== ГЛАВНОЕ МЕНЮ ======================

while true; do
    refresh_online
    clear

    active_count=$(get_active_users | grep -c . 2>/dev/null || echo 0)
    disabled_count=$(grep -c . "$DISABLED_FILE" 2>/dev/null || echo 0)
    total_count=$((active_count + disabled_count))
    online_count=$(echo "${CACHED_ONLINE:-{}}" | jq 'to_entries | map(select(.value > 0)) | length' 2>/dev/null || echo "?")

    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║              Hysteria 2 Manager v2.0                       ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║ IP сервера      : $CACHED_IP"
    echo "║ Порт            : $CACHED_PORT"
    echo "║ SNI / Маскировка: $CACHED_SNI"
    echo "║ OBFS-пароль     : $(echo "$CACHED_OBFS" | cut -c1-20)..."
    echo "║ Пользователей   : $total_count (активных: $active_count, онлайн: $online_count)"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  1. ➕ Добавить нового пользователя"
    echo "  2. 👥 Пользователи (статистика, IP, действия)"
    echo "  3. 🔗 Получить ссылку"
    echo "  4. 🚪 Выход"
    echo ""
    read -p "  Выберите (1-4): " choice

    case $choice in
        1)
            read -p "  Имя пользователя (латиница, цифры, _): " USERNAME
            [ -z "$USERNAME" ] && echo "  ❌ Имя не может быть пустым!" && sleep 2 && continue

            if [[ ! "$USERNAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                echo "  ❌ Допустимы: латиница, цифры, _ и -"
                sleep 2
                continue
            fi

            if grep -q "^    $USERNAME: " "$CONFIG"; then
                echo "  ❌ $USERNAME уже существует!"
                sleep 2
                continue
            fi

            if is_user_disabled "$USERNAME"; then
                echo "  ❌ $USERNAME существует (отключён). Включите или удалите."
                sleep 2
                continue
            fi

            PASSWORD=$(pwgen -s 64 1)
            echo "  🔑 Сгенерирован 64-символьный пароль"

            sed -i "/^  userpass:/a\\    $USERNAME: \"$PASSWORD\"" "$CONFIG"
            echo "  ✅ Пользователь $USERNAME добавлен"

            read -p "  Установить срок действия? (ГГГГ-ММ-ДД или Enter): " EXP
            if [[ "$EXP" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
                set_user_expiry "$USERNAME" "$EXP"
                echo "  ⏰ Срок действия: $EXP"
            fi

            echo "  🔄 Перезапуск Hysteria 2..."
            systemctl restart "$SERVICE"
            sleep 2

            if systemctl is-active --quiet "$SERVICE"; then
                echo "  ✅ Сервис запущен"
            else
                echo "  ⚠️  Сервис НЕ запустился! journalctl -u $SERVICE -e"
            fi

            LINK="hysteria2://${USERNAME}:${PASSWORD}@${CACHED_IP}:${CACHED_PORT}/?obfs=salamander&obfs-password=${CACHED_OBFS}&sni=${CACHED_SNI}&insecure=1#${USERNAME}"
            echo ""
            echo "  🔗 ГОТОВАЯ ССЫЛКА:"
            echo "  $LINK"
            echo ""
            echo "  💡 Hiddify, Nekobox, Streisand и т.д."
            read -p "  Enter для возврата..."
            ;;

        2)
            collect_traffic
            collect_ips
            user_list_menu
            ;;

        3)
            get_link_menu
            ;;

        4)
            echo "  👋 Выход..."
            exit 0
            ;;

        *)
            echo "  ❌ Неверный выбор!"
            sleep 1.5
            ;;
    esac
done
