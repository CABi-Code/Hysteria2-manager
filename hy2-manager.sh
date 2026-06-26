#!/bin/bash
# ================================================
# Hysteria 2 Manager v2.1
# Управление пользователями, статистика, IP-трекинг
# Сроки действия, защита от утечек
# ================================================

# Разрешаем симлинк, чтобы при запуске через /usr/local/bin/hy2-manager
# мы корректно нашли каталог с lib/. Без readlink -f скрипт пытался
# подгружать модули из /usr/local/bin/lib и все функции терялись.
_self="${BASH_SOURCE[0]}"
_resolved="$(readlink -f "$_self" 2>/dev/null || echo "$_self")"
SCRIPT_DIR="$(cd "$(dirname "$_resolved")" && pwd)"
unset _self _resolved

# === ЛОГИ ===
LOG_DIR="/var/log/hy2-manager"
LOG_FILE="$LOG_DIR/error.log"
mkdir -p "$LOG_DIR" 2>/dev/null || true
# stderr перенаправляем в лог-файл НИЖЕ — после загрузки модулей и проверки
# зависимостей (чтобы критичные ошибки старта были видны на экране).
#
# ВАЖНО: ранее stderr дублировался на экран через `exec 2> >(...)`
# (process substitution). Это ломало интерактив: промпт `read -p` пишется
# в stderr без перевода строки и застревал в построчном буфере подстановки —
# пользователь не видел ни «Enter для продолжения…», ни запроса
# подтверждения удаления и вводил вслепую. Теперь промпты печатаются в
# stdout (хелперы ask/pause в lib/config.sh), а stderr тихо уходит в лог.

# === ЗАГРУЗКА МОДУЛЕЙ ===
_required_libs=(config deps api traffic ip_tracking online expiry users cron migration ui)
for _lib in "${_required_libs[@]}"; do
    _libpath="$SCRIPT_DIR/lib/${_lib}.sh"
    if [ ! -f "$_libpath" ]; then
        echo "❌ Модуль не найден: $_libpath" >&2
        echo "   Переустановите менеджер:" >&2
        echo "   sudo bash <(curl -fsSL https://raw.githubusercontent.com/CABi-Code/Hysteria2-manager/main/install.sh)" >&2
        exit 1
    fi
    # shellcheck disable=SC1090
    source "$_libpath"
done
unset _required_libs _lib _libpath

# === ПРОВЕРКА ЗАВИСИМОСТЕЙ ===
check_deps
init_data_dir

# === ЛОГ stderr ===
# С этого момента ошибки (sed/systemctl/curl и т.п.) пишем в лог-файл, чтобы
# они не затирали интерактивный интерфейс. Промпты идут в stdout (ask/pause).
if [ -w "$LOG_DIR" ] || mkdir -p "$LOG_DIR" 2>/dev/null; then
    exec 2>>"$LOG_FILE"
fi

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

main_need_clear=1
while true; do
    refresh_online

    active_count=$(get_active_users | grep -c '^' 2>/dev/null | tr -dc '0-9' || echo 0)
    disabled_count=$(grep -c '^' "$DISABLED_FILE" 2>/dev/null | tr -dc '0-9' || echo 0)
    total_count=$((active_count + disabled_count))
    online_count=$(echo "${CACHED_ONLINE:-{}}" | jq 'to_entries | map(select(.value > 0)) | length' 2>/dev/null | tr -dc '0-9' || echo "?")

    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        hy_status="🟢 Работает"
    else
        hy_status="🔴 Остановлен"
    fi
    if systemctl is-enabled --quiet "$SERVICE" 2>/dev/null; then
        hy_autostart="✅ включён"
    else
        hy_autostart="❌ отключён"
    fi

    main_frame=$(
        echo "╔══════════════════════════════════════════════════════════════╗"
        echo "║              Hysteria 2 Manager v2.1                       ║"
        echo "╠══════════════════════════════════════════════════════════════╣"
        echo "║ Статус Hysteria : $hy_status (автозапуск: $hy_autostart)"
        echo "║ IP сервера      : $CACHED_IP"
        echo "║ Порт            : $CACHED_PORT"
        echo "║ SNI / Маскировка: $CACHED_SNI"
        echo "║ OBFS-пароль     : $(echo "$CACHED_OBFS" | cut -c1-10)..."
        echo "║ Пользователей   : $total_count (активных: $active_count, онлайн: $online_count)"
        echo "╚══════════════════════════════════════════════════════════════╝"
        if is_restart_pending; then
            echo "  ⚠️  Есть изменения, ожидающие перезапуска Hysteria (Настройки → 2)"
        fi
        echo ""
        echo "  1. ➕ Добавить нового пользователя"
        echo "  2. 👥 Пользователи (статистика, IP, действия)"
        echo "  3. 🔗 Получить ссылку"
        echo "  4. ⚙  Настройки"
        echo "  0. 🚪 Выход"
        echo ""
    )
    [ "$main_need_clear" = 1 ] && { clear; main_need_clear=0; }
    render_frame "$main_frame"

    # Автообновление: если за REFRESH_INTERVAL сек ввода нет — перерисовываем меню
    if ! ask choice "  Выберите (обновление каждые ${REFRESH_INTERVAL}с): " "$REFRESH_INTERVAL"; then
        continue
    fi

    case $choice in
        1)
            main_need_clear=1
            clear
            ask USERNAME "  Имя пользователя (латиница, цифры, _): "
            [ -z "$USERNAME" ] && echo "  ❌ Имя не может быть пустым!" && sleep 2 && continue

            if [[ ! "$USERNAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                echo "  ❌ Допустимы: латиница, цифры, _ и -"
                sleep 2
                continue
            fi

            if is_reserved_username "$USERNAME"; then
                echo "  ❌ Имя '$USERNAME' зарезервировано (конфликт с YAML-ключами)"
                sleep 2
                continue
            fi

            if grep -q "^[[:space:]]*${USERNAME}:[[:space:]]" "$CONFIG"; then
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

            if ! grep -q '^[[:space:]]*userpass:' "$CONFIG"; then
                echo "  ❌ Секция userpass не найдена в конфиге!"
                echo "  Проверьте $CONFIG"
                sleep 3
                continue
            fi

            sed -i "/^[[:space:]]*userpass:/a\\    $USERNAME: \"$PASSWORD\"" "$CONFIG"

            if ! grep -q "^    ${USERNAME}: " "$CONFIG"; then
                echo "  ❌ Ошибка! Пользователь не добавлен в конфиг."
                echo "  Проверьте формат $CONFIG"
                sleep 3
                continue
            fi

            echo "  ✅ Пользователь $USERNAME добавлен"

            ask EXP_DAYS "  Срок действия в днях от сегодня (Enter — без срока): "
            if [[ "$EXP_DAYS" =~ ^[0-9]+$ ]] && [ "$EXP_DAYS" -gt 0 ]; then
                EXP_DATE=$(days_to_date "$EXP_DAYS")
                if [ -n "$EXP_DATE" ]; then
                    set_user_expiry "$USERNAME" "$EXP_DATE"
                    echo "  ⏰ Срок действия: $EXP_DATE (через $EXP_DAYS дн.)"
                fi
            fi

            LINK="hysteria2://${USERNAME}:${PASSWORD}@${CACHED_IP}:${CACHED_PORT}/?obfs=salamander&obfs-password=${CACHED_OBFS}&sni=${CACHED_SNI}&insecure=1#${USERNAME}"
            echo ""
            echo "  🔗 ГОТОВАЯ ССЫЛКА:"
            echo "  $LINK"
            echo ""
            echo "  💡 Hiddify, Nekobox, Streisand и т.д."
            # Перезапуск нужен, чтобы новый пользователь смог подключиться.
            # Делаем его осознанно (с предупреждением), а не молча.
            prompt_apply_restart
            pause "  Enter для возврата..."
            ;;

        2)
            main_need_clear=1
            collect_traffic
            collect_ips
            user_list_menu
            ;;

        3)
            main_need_clear=1
            get_link_menu
            ;;

        4)
            main_need_clear=1
            settings_menu
            ;;

        0)
            echo "  👋 Выход..."
            exit 0
            ;;

        "")
            # Пустой ввод (Enter) — просто обновляем экран
            ;;

        *)
            echo "  ❌ Неверный выбор!"
            sleep 1.5
            ;;
    esac
done
