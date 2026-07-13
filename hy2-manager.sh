#!/bin/bash
# ================================================
# Hysteria 2 Manager
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

# === ВЕРСИЯ МЕНЕДЖЕРА ===
# Единый источник версии — файл VERSION в каталоге со скриптом. Так номер
# версии задаётся в одном месте и подставляется везде через $MANAGER_VERSION.
MANAGER_VERSION="$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null | head -1 | tr -d '[:space:]')"
MANAGER_VERSION="${MANAGER_VERSION:-unknown}"

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
_required_libs=(config deps api traffic ip_tracking online expiry limits users cron migration subscription antiabuse perf cluster ui)
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
    migrate_auth
    migrate_to_command_auth
    setup_stats_api
    check_expired_users
    exit 0
fi

if [ "$1" = "--collect" ]; then
    setup_stats_api
    collect_traffic
    collect_ips
    collect_sub_ips    # IP по токенам подписки из access-лога Caddy
    publish_ips        # разослать свежие IP по кластеру (видны на всех нодах)
    publish_subips     # разослать IP по токенам подписки
    exit 0
fi

if [ "$1" = "--cluster-sync" ]; then
    # Периодический обмен ключами с пирами + пересборка подписок (cron).
    cluster_sync
    exit 0
fi

if [ "$1" = "--online-sync" ]; then
    # Частый обмен онлайном + применение лимита устройств по кластеру (cron, 1 мин).
    setup_stats_api
    migrate_device_limit    # на случай, если меню ещё не открывали после апгрейда
    cluster_online_sync
    write_authlimits    # снимок для жёсткой проверки (работает и на одиночной ноде)
    exit 0
fi

if [ "$1" = "--antiabuse" ]; then
    # Часовая коррекция балла анти-абуза + авто-жёсткая проверка (cron, 1 час).
    setup_stats_api
    abuse_correct
    exit 0
fi

# === ИНИЦИАЛИЗАЦИЯ ===

migrate_auth
migrate_to_command_auth
migrate_device_limit        # старый device_limit -> общекластерный POOL_LIMIT
setup_stats_api
collect_traffic
collect_ips
collect_sub_ips
check_expired_users
write_authlimits            # снимок лимитов для скрипта аутентификации
setup_cron

# Самовосстановление подписки: если она настроена, но Caddy лежит или его конфиг
# битый — открываем порты и пересобираем конфиг автоматически (без действий юзера).
if sub_enabled; then
    ensure_ports_open
    if ! systemctl is-active --quiet caddy 2>/dev/null \
       || ! caddy validate --config "$CADDYFILE" --adapter caddyfile &>/dev/null; then
        setup_caddy >/dev/null 2>&1
    fi
fi

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

    _title="Hysteria 2 Manager v${MANAGER_VERSION}"
    # Центрируем заголовок во внутренней ширине рамки (62 символа), чтобы
    # правая граница ║ оставалась на месте при любой длине версии.
    _inner=62; _tlen=${#_title}
    _lpad=$(( (_inner - _tlen) / 2 )); _rpad=$(( _inner - _tlen - _lpad ))
    main_frame=$(
        echo "╔══════════════════════════════════════════════════════════════╗"
        printf "║%*s%s%*s║\n" "$_lpad" "" "$_title" "$_rpad" ""
        echo "╠══════════════════════════════════════════════════════════════╣"
        echo "║ Статус Hysteria : $hy_status (автозапуск: $hy_autostart)"
        echo "║ IP сервера      : $CACHED_IP"
        echo "║ Порт            : $CACHED_PORT"
        echo "║ SNI / Маскировка: $CACHED_SNI"
        echo "║ OBFS-пароль     : $(echo "$CACHED_OBFS" | cut -c1-10)..."
        echo "║ Пользователей   : $total_count (активных: $active_count, онлайн: $online_count)"
        if sub_enabled; then
            cluster_nodes=$(grep -c '^' "$CLUSTER_CONF" 2>/dev/null | tr -dc '0-9'); cluster_nodes=${cluster_nodes:-1}
            dev_limit=$(get_device_limit)
            [ "$dev_limit" -gt 0 ] 2>/dev/null && limit_str=", лимит устройств: $dev_limit" || limit_str=""
            echo "║ Подписка        : 🟢 нода «$(node_name)», нод в кластере: $cluster_nodes$limit_str"
        else
            echo "║ Подписка        : ⚪ не настроена (Настройки → 4)"
        fi
        echo "╚══════════════════════════════════════════════════════════════╝"
        if is_restart_pending; then
            echo "  ⚠️  Есть изменения, ожидающие перезапуска Hysteria (Настройки → 2)"
        fi
        echo ""
        echo "  1. ➕ Добавить нового пользователя"
        echo "  2. 👥 Пользователи (статистика, IP, действия)"
        echo "  3. 🔗 Получить ссылку"
        echo "  4. ⚙  Настройки"
        sub_enabled && echo "  5. 🔄 Получить синхронизацию (локально)"
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

            if db_user_exists "$USERNAME"; then
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

            db_add_user "$USERNAME" "$PASSWORD"

            if ! db_user_exists "$USERNAME"; then
                echo "  ❌ Ошибка! Пользователь не добавлен в базу."
                echo "  Проверьте $USERS_DB"
                sleep 3
                continue
            fi

            echo "  ✅ Пользователь $USERNAME добавлен (применено сразу, без перезапуска)"

            # Локально или на весь кластер? (только если подписка/кластер настроены)
            if sub_enabled; then
                echo ""
                echo "  Где завести пользователя?"
                echo "    1. Только на этой ноде (по умолчанию)"
                echo "    2. На всех нодах кластера (появится на остальных автоматически)"
                ask SCOPE "  Выбор (1/2): "
                if [ "$SCOPE" = "2" ]; then
                    cluster_share_user "$USERNAME"
                    echo "  🌐 Помечен как кластерный. На других нодах появится в течение ~5 мин"
                    echo "     (с собственным паролем там; в подписке соберутся ключи со всех нод)."
                fi
            fi

            ask EXP_DAYS "  Срок действия в днях от сегодня (Enter — без срока): "
            if [[ "$EXP_DAYS" =~ ^[0-9]+$ ]] && [ "$EXP_DAYS" -gt 0 ]; then
                EXP_DATE=$(days_to_date "$EXP_DAYS")
                if [ -n "$EXP_DATE" ]; then
                    set_user_expiry "$USERNAME" "$EXP_DATE"
                    echo "  ⏰ Срок действия: $EXP_DATE (через $EXP_DAYS дн.)"
                fi
            fi

            LINK=$(build_user_link "$USERNAME" "$PASSWORD" "$(link_host)" "$CACHED_PORT" "$CACHED_OBFS" "$CACHED_SNI")
            echo ""
            echo "  🔗 ГОТОВАЯ ССЫЛКА:"
            echo "  $LINK"
            echo ""
            echo "  💡 Hiddify, Nekobox, Streisand и т.д."
            echo "  ✅ Клиент может подключаться прямо сейчас."

            # Если настроена подписка — обновляем её и показываем единую ссылку,
            # которая соберёт ключи этого юзера со всех серверов кластера.
            if sub_enabled; then
                sub_refresh
                echo ""
                echo "  🌐 ССЫЛКА-ПОДПИСКА (все серверы, автообновление):"
                echo "  $(subscription_url "$USERNAME")"
                echo "  ℹ️  Заведите этого юзера тем же именем на других нодах —"
                echo "      их ключи появятся в этой подписке автоматически."
            fi
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

        5)
            main_need_clear=1
            if sub_enabled; then
                cluster_sync_now
                pause "  Enter для возврата..."
            fi
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
