#!/bin/bash
# ================================================
# Hysteria 2 Manager v2.0
# Управление пользователями, статистика, IP-трекинг
# Сроки действия, защита от утечек
# ================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# === ЗАГРУЗКА МОДУЛЕЙ ===
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/deps.sh"
source "$SCRIPT_DIR/lib/api.sh"
source "$SCRIPT_DIR/lib/traffic.sh"
source "$SCRIPT_DIR/lib/ip_tracking.sh"
source "$SCRIPT_DIR/lib/online.sh"
source "$SCRIPT_DIR/lib/expiry.sh"
source "$SCRIPT_DIR/lib/users.sh"
source "$SCRIPT_DIR/lib/cron.sh"
source "$SCRIPT_DIR/lib/migration.sh"
source "$SCRIPT_DIR/lib/ui.sh"

# === ПРОВЕРКА ЗАВИСИМОСТЕЙ ===
check_deps
init_data_dir

# === CLI АРГУМЕНТЫ ===

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

# === ИНИЦИАЛИЗАЦИЯ ===

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

# === ГЛАВНОЕ МЕНЮ ===

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
