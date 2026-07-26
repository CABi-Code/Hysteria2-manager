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
_required_libs=(config deps api traffic ip_tracking online expiry limits users cron migration node sub_links caddy diagnose devlimits publish protocols antiabuse perf cluster update tgbot tariffs yoomoney tgbot_client tgbot_admin tgbot_daemon tgbot_menu notify webapi freeplan demo ui ui_users ui_devices ui_perf ui_protocols ui_settings ui_subscription)
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
    # Напоминания шлёт отдельный крон --notify-sweep (каждые ~5 мин). Раньше sweep
    # звался и тут: на границе 6 часов оба крона (--check-expiry и --notify-sweep)
    # стартовали в одну минуту, два процесса bot_notify_sweep гонялись за
    # notify_state.dat и слали ОДНО напоминание дважды. Теперь тут не зовём.
    exit 0
fi

# Частый прогон только напоминаний (cron каждые ~5 мин): чтобы ловить пороги
# 30 мин / 1 час, недостижимые при 6-часовом --check-expiry.
if [ "$1" = "--notify-sweep" ]; then
    bot_notify_sweep
    exit 0
fi

if [ "$1" = "--collect" ]; then
    setup_stats_api
    collect_traffic
    proto_collect_traffic    # трафик VLESS/SS2022 из Xray StatsService в общий учёт
    collect_ips
    collect_sub_ips    # IP по токенам подписки из access-лога Caddy
    publish_ips        # разослать свежие IP по кластеру (видны на всех нодах)
    publish_subips     # разослать IP по токенам подписки
    # Убитый на полуслове публикатор (systemctl stop, kill) оставляет свой
    # «файл.tmp.<pid>». Два часа — заведомо больше любой живой записи, так что
    # под метлу попадают только осиротевшие. См. docs/MAINTENANCE.md.
    find "$DATA_DIR" "$WEBROOT" -name '*.tmp.*' -mmin +120 -delete 2>/dev/null
    exit 0
fi

if [ "$1" = "--rates-tick" ]; then
    # Тик спидометра (systemd-таймер hy2-rates, раз в RATES_TICK_SEC): пересчёт
    # своей скорости + обмен с пирами. flock -n: если предыдущий тик ещё жив
    # (тормозящий API протокола), пропускаем — очередь тиков нам не нужна.
    exec 9>"$DATA_DIR/.rates.lock"
    flock -n 9 || exit 0
    collect_rates
    # Межнодовый обмен скоростью реже сбора: локальный спидометр частит (5 с),
    # а тянуть rates у пиров каждые 5 с ради этого — лишний кластерный трафик.
    # Гейт по стенным часам (без файла-счётчика): каждый RATES_SYNC_EVERY-й тик.
    if [ "$(( ($(date +%s) / ${RATES_TICK_SEC:-5}) % ${RATES_SYNC_EVERY:-3} ))" -eq 0 ]; then
        cluster_rates_sync
    else
        publish_rates   # свою всё равно публикуем каждый тик (дешёвая копия файла)
    fi
    # Пер-IP раскладку тарифов держим свежей и здесь (раз в RATES_TICK_SEC=15с), а
    # не только в --online-sync (60с): иначе только что подключившийся клиент с
    # тарифом (особенно демо, тестирующий скорость сразу) до минуты крутится
    # НЕшейпимым в глобальном классе и спидтест показывает выше тарифа.
    # Идемпотентно и дёшево: reconcile трогает tc, только когда набор IP→тариф сменился.
    klimit_reconcile
    exit 0
fi

if [ "$1" = "--cluster-sync" ]; then
    # Периодический обмен ключами с пирами + пересборка подписок (cron).
    cluster_sync
    exit 0
fi

if [ "$1" = "--ym-poll" ]; then
    # Оплаты ЮMoney: опрос истории операций по меткам ждущих счетов.
    # Клиент может не ждать — в счёте есть кнопка «Проверить оплату» (тот же код).
    ym_poll
    exit 0
fi

if [ "$1" = "--online-sync" ]; then
    # Частый обмен онлайном + применение лимита устройств по кластеру (cron, 1 мин).
    setup_stats_api
    migrate_device_limit    # на случай, если меню ещё не открывали после апгрейда
    rates_timer_ensure      # таймер спидометра ставится сам после обновления ноды
    # TUIC-трафик считаем ЗДЕСЬ (раз в минуту): по дельтам соединений, иначе они
    # успеют закрыться между снимками. До cluster_online_sync — чтобы publish_stats
    # уже включил свежие байты. Xray/Hysteria учитываются в --collect (30 мин).
    declare -F proto_collect_tuic_traffic >/dev/null 2>&1 && proto_collect_tuic_traffic
    cluster_online_sync
    # Бесплатный тариф: расход по окнам считается минутно — на этой ноде байты
    # видны сразу, а отключение по исчерпанию не должно ждать 30-мин сбора.
    freeplan_tick
    demo_tick           # выдохшиеся демо-профили: TTL в минутах, а не в сутках
    write_authlimits    # снимок для жёсткой проверки (работает и на одиночной ноде)
    klimit_sync_port    # перегенерировать лимит, если сменился порт ИЛИ набор протоколов (SHAPE-дрейф)
    klimit_reconcile    # разложить активные IP по тарифным классам скорости (tc)
    exit 0
fi

if [ "$1" = "--antiabuse" ]; then
    # Часовая коррекция балла анти-абуза + авто-жёсткая проверка (cron, 1 час).
    setup_stats_api
    abuse_correct
    exit 0
fi

if [ "$1" = "--bot-daemon" ]; then
    # Демон Telegram-бота (systemd-юнит hy2-bot.service). Работает без TTY:
    # long-polling Telegram API, самообслуживание клиентов + админ-действия.
    setup_stats_api
    tgbot_daemon
    exit 0
fi

# === ИНИЦИАЛИЗАЦИЯ ===

migrate_auth
migrate_to_command_auth
migrate_device_limit        # старый device_limit -> общекластерный POOL_LIMIT
rates_timer_ensure          # таймер тика скорости (спидометр мини-аппа)
setup_stats_api
collect_traffic
collect_ips
collect_sub_ips
check_expired_users
write_authlimits            # снимок лимитов для скрипта аутентификации
setup_cron
klimit_sync_port            # kernel-лимит: перегенерировать правила, если порт сменился

# Самовосстановление подписки: если она настроена, но Caddy лежит или его конфиг
# битый — открываем порты и пересобираем конфиг автоматически (без действий юзера).
if sub_enabled; then
    ensure_ports_open
    if ! systemctl is-active --quiet caddy 2>/dev/null \
       || ! caddy validate --config "$CADDYFILE" --adapter caddyfile &>/dev/null; then
        setup_caddy >/dev/null 2>&1
    fi
fi

# Самовосстановление доп. протоколов: если что-то включено, но сервис лежит или
# конфиг устарел — переустановим/пересоберём и поднимем (идемпотентно, быстро,
# если движки уже стоят). При выключенных протоколах — no-op.
if declare -F proto_any_enabled >/dev/null 2>&1 && proto_any_enabled; then
    proto_bootstrap >/dev/null 2>&1 || true
fi

CACHED_IP=$(get_ip)
CACHED_PORT=$(get_port)
CACHED_OBFS=$(get_obfs_pass)
CACHED_SNI=$(get_sni)
refresh_online

# === ГЛАВНОЕ МЕНЮ ===

# Добавление пользователя (вынесено из цикла меню, чтобы главный цикл был читаем).
add_user_flow() {
    clear
    local USERNAME PASSWORD SCOPE EXP_DAYS EXP_DATE LINK
    ask USERNAME "  Имя пользователя (латиница, цифры, _): "
    [ -z "$USERNAME" ] && echo "  ❌ Имя не может быть пустым!" && sleep 2 && return

    if [[ ! "$USERNAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo "  ❌ Допустимы: латиница, цифры, _ и -"
        sleep 2
        return
    fi

    if is_reserved_username "$USERNAME"; then
        echo "  ❌ Имя '$USERNAME' зарезервировано (конфликт с YAML-ключами)"
        sleep 2
        return
    fi

    if db_user_exists "$USERNAME"; then
        echo "  ❌ $USERNAME уже существует!"
        sleep 2
        return
    fi

    if is_user_disabled "$USERNAME"; then
        echo "  ❌ $USERNAME существует (отключён). Включите или удалите."
        sleep 2
        return
    fi

    PASSWORD=$(pwgen -s 64 1)
    echo "  🔑 Сгенерирован 64-символьный пароль"

    db_add_user "$USERNAME" "$PASSWORD"

    if ! db_user_exists "$USERNAME"; then
        echo "  ❌ Ошибка! Пользователь не добавлен в базу."
        echo "  Проверьте $USERS_DB"
        sleep 3
        return
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
}

main_need_clear=1
while true; do
    refresh_online

    active_count=$(get_active_users | grep -c '^' 2>/dev/null | tr -dc '0-9'); active_count=${active_count:-0}
    disabled_count=$(grep -c '^' "$DISABLED_FILE" 2>/dev/null | tr -dc '0-9'); disabled_count=${disabled_count:-0}
    total_count=$((active_count + disabled_count))
    online_count=$(echo "${CACHED_ONLINE:-{}}" | jq 'to_entries | map(select(.value > 0)) | length' 2>/dev/null | tr -dc '0-9')
    online_count=${online_count:-?}; [ -z "$online_count" ] && online_count="?"

    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        hy_status="💚 Работает"
    else
        hy_status="🔴 Остановлен"
    fi
    if systemctl is-enabled --quiet "$SERVICE" 2>/dev/null; then
        hy_autostart="автозапуск ✅"
    else
        hy_autostart="автозапуск ❌"
    fi

    # Рамка без правой границы на строках с данными: эмодзи/кириллица имеют
    # «плавающую» ширину в терминалах, и закрытый бокс всегда разъезжался.
    main_frame=$(
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Hysteria 2 Manager v${MANAGER_VERSION}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Hysteria      : $hy_status ($hy_autostart)"
        echo "  Сервер        : $CACHED_IP · порт $CACHED_PORT/udp"
        echo "  SNI/маскировка: $CACHED_SNI · OBFS: $(echo "$CACHED_OBFS" | cut -c1-10)…"
        echo "  Пользователи  : $total_count (активных $active_count · онлайн $online_count)"
        if declare -F klimit_down >/dev/null && { [ "$(klimit_down)" -gt 0 ] || [ "$(klimit_up)" -gt 0 ]; } 2>/dev/null; then
            echo "  Лимит скорости: ↓$(klimit_down)/↑$(klimit_up) Мбит на клиента $(klimit_active && echo '💚' || echo '🔴 (не загружен!)')"
        fi
        if sub_enabled; then
            cluster_nodes=$(grep -c '^' "$CLUSTER_CONF" 2>/dev/null | tr -dc '0-9'); cluster_nodes=${cluster_nodes:-1}
            dev_limit=$(get_device_limit)
            [ "$dev_limit" -gt 0 ] 2>/dev/null && limit_str=" · лимит устройств $dev_limit" || limit_str=""
            echo "  Подписка      : 💚 нода «$(node_name)» · нод в кластере: $cluster_nodes$limit_str"
        else
            echo "  Подписка      : ⚪ не настроена (Настройки → 5)"
        fi
        if declare -F bot_enabled >/dev/null && bot_enabled; then
            echo "  Telegram-бот  : $(bot_running && echo '💚 работает' || echo '🔴 остановлен (Настройки → 6)')"
        fi
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        if is_restart_pending; then
            echo "  ⚠️  Есть изменения, ожидающие перезапуска Hysteria (Настройки → 2)"
        fi
        if declare -F manager_update_banner >/dev/null 2>&1; then
            _upd_banner=$(manager_update_banner 2>/dev/null)
            [ -n "$_upd_banner" ] && echo "  🔔 $_upd_banner — обновить: Настройки → 8"
        fi
        echo ""
        echo "  1. ➕ Добавить нового пользователя"
        echo "  2. 👥 Пользователи (статистика, IP, действия)"
        echo "  3. 🔗 Получить ссылку"
        echo "  4. ⚙  Настройки"
        sub_enabled && echo "  5. 🔄 Получить синхронизацию (локально)"
        echo "  6. 🌐 Web API для приложений $(webapi_enabled && echo '💚' || echo '⚪')"
        echo "  0. 🚪 Выход"
        echo ""
    )
    [ "$main_need_clear" = 1 ] && { clear; main_need_clear=0; }
    render_frame "$main_frame"

    # Одна клавиша = действие (без Enter). Нет нажатия за REFRESH_INTERVAL сек —
    # перерисовываем экран (обновление статуса/онлайна).
    printf '  Клавиша 1-6, 0 — выход (экран обновляется каждые %sс): ' "$REFRESH_INTERVAL"
    choice=$(read_key "$REFRESH_INTERVAL")

    case $choice in
        1)
            main_need_clear=1
            add_user_flow
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

        6)
            main_need_clear=1
            webapi_menu
            ;;

        0|q|Q)
            echo ""
            echo "  👋 Выход..."
            exit 0
            ;;

        TIMEOUT|ENTER|ESC)
            # Нет ввода/Enter — просто обновляем экран
            ;;

        *)
            :   # неизвестная клавиша — тихо перерисуем
            ;;
    esac
done
