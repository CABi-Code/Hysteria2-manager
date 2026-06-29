#!/bin/bash
# ================================================
# Интерфейс: таблицы, меню пользователей, ссылки
# ================================================

declare -a USER_LIST_ARRAY
USER_LIST_PAGES=1
USER_LIST_TOTAL=0

# ====================== ОТРИСОВКА БЕЗ МИГАНИЯ ======================
# Раньше каждое автообновление делало `clear` — весь экран на миг гас, и
# интерфейс «мигал». Теперь кадр печатается поверх предыдущего: курсор в
# левый верхний угол, каждая строка дочищается до конца (\033[K), а хвост
# экрана — \033[J. Глаз видит только реально изменившиеся символы.

render_frame() {
    local frame="$1" line
    printf '\033[H'
    while IFS= read -r line; do
        printf '%s\033[K\n' "$line"
    done <<< "$frame"
    printf '\033[J'
}

# ====================== ШИРИНА И ЯЧЕЙКИ ТАБЛИЦЫ ======================
# Эмодзи (🟢🔴⚫ …) занимают 2 колонки терминала, но ${#s} в UTF-8 локали
# считает их за 1 символ — из-за этого printf "%-Ns" «кривил» столбцы.
# print_cell кладёт текст в колонку фиксированной ВИДИМОЙ ширины, зная,
# сколько в нём «широких» символов (wide).

# print_cell <текст> <ширина> [число_широких] [r]  (r — выравнивание вправо)
print_cell() {
    local text="$1" width="$2" wide="${3:-0}" align="${4:-l}"
    local dwidth=$(( ${#text} + wide )) pad
    pad=$(( width - dwidth ))
    [ "$pad" -lt 0 ] && pad=0
    if [ "$align" = "r" ]; then
        printf '%*s%s' "$pad" "" "$text"
    else
        printf '%s%*s' "$text" "$pad" ""
    fi
}

# Обрезка имени до N видимых символов (имена почти всегда ASCII).
trunc() {
    local s="$1" n="$2"
    if [ "${#s}" -gt "$n" ]; then
        printf '%s' "${s:0:$((n-1))}…"
    else
        printf '%s' "$s"
    fi
}

# ====================== ЧТЕНИЕ КЛАВИШ ======================
# Возвращает токен: LEFT/RIGHT/UP/DOWN (стрелки), ENTER, TIMEOUT, ESC
# или сам введённый символ. Позволяет листать страницы стрелками без Enter.
read_key() {
    local timeout="$1" key rest
    if [ -n "$timeout" ]; then
        IFS= read -rsn1 -t "$timeout" key || { echo "TIMEOUT"; return; }
    else
        IFS= read -rsn1 key || { echo "TIMEOUT"; return; }
    fi
    if [ -z "$key" ]; then
        echo "ENTER"; return
    fi
    if [ "$key" = $'\033' ]; then
        # Escape-последовательность стрелки: \033[A/B/C/D
        read -rsn2 -t 0.05 rest
        case "$rest" in
            '[C') echo "RIGHT" ;;
            '[D') echo "LEFT" ;;
            '[A') echo "UP" ;;
            '[B') echo "DOWN" ;;
            *)    echo "ESC" ;;
        esac
        return
    fi
    printf '%s\n' "$key"
}

# ====================== ЗАГРУЗКА СПИСКА ПОЛЬЗОВАТЕЛЕЙ ======================
# Заполняет USER_LIST_ARRAY с сортировкой: онлайн → оффлайн → отключённые,
# внутри группы — по имени. Активные клиенты оказываются вверху списка.
load_user_list() {
    USER_LIST_ARRAY=()
    local sorted
    sorted=$(
        get_all_users | while IFS= read -r u; do
            [ -z "$u" ] && continue
            local key oc
            if is_user_disabled "$u"; then
                key=2
            else
                oc=$(get_user_online_count "$u")
                if [ "${oc:-0}" -gt 0 ] 2>/dev/null; then key=0; else key=1; fi
            fi
            printf '%s\t%s\n' "$key" "$u"
        done | sort -t$'\t' -k1,1n -k2,2
    )
    while IFS=$'\t' read -r _ u; do
        [ -n "$u" ] && USER_LIST_ARRAY+=("$u")
    done <<< "$sorted"

    USER_LIST_TOTAL=${#USER_LIST_ARRAY[@]}
    USER_LIST_PAGES=$(( (USER_LIST_TOTAL + PAGE_SIZE - 1) / PAGE_SIZE ))
    [ "$USER_LIST_PAGES" -eq 0 ] && USER_LIST_PAGES=1
}

# Короткое представление срока действия для таблицы: «30д», «истёк», «—».
expiry_cell() {
    local exp="$1" dl
    if [ -z "$exp" ]; then
        printf '—'
        return
    fi
    dl=$(expiry_days_left "$exp")
    if [ -z "$dl" ]; then
        printf '%s' "$exp"
    elif [ "$dl" -lt 0 ]; then
        printf 'истёк'
    else
        printf '%sд' "$dl"
    fi
}

# ====================== ТАБЛИЦА ПОЛЬЗОВАТЕЛЕЙ ======================
# Только печатает кадр (без clear) — вызывается внутри $(...) для render_frame.
# Перед вызовом должен быть выполнен load_user_list.
render_user_table() {
    local page=${1:-1}
    local title="$2"

    [ "$page" -gt "$USER_LIST_PAGES" ] && page=$USER_LIST_PAGES
    [ "$page" -lt 1 ] && page=1

    local start=$(( (page - 1) * PAGE_SIZE ))
    local end=$(( start + PAGE_SIZE ))
    [ "$end" -gt "$USER_LIST_TOTAL" ] && end=$USER_LIST_TOTAL

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ${title:-Пользователи} (стр. $page/$USER_LIST_PAGES, всего: $USER_LIST_TOTAL)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf '  '
    print_cell "No"       3  0 r; printf ' '
    print_cell "Имя"      14 0;   printf ' '
    print_cell "Статус"   9  0;   printf ' '
    print_cell "Скорость" 14 0;   printf ' '
    print_cell "Трафик"   16 0;   printf ' '
    print_cell "IP"       3  0 r; printf ' '
    print_cell "Срок"     6  0;   printf '\n'
    echo "  ─────────────────────────────────────────────────────────────────────────"

    if [ "$USER_LIST_TOTAL" -eq 0 ]; then
        echo "  Нет пользователей."
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        return
    fi

    local i
    for ((i=start; i<end; i++)); do
        local user="${USER_LIST_ARRAY[$i]}"
        local num=$((i + 1))
        local status status_wide

        if is_user_disabled "$user"; then
            status="🔴 ВЫКЛ"; status_wide=1
        else
            local oc
            oc=$(get_user_online_count "$user")
            if [ "${oc:-0}" -gt 0 ] 2>/dev/null; then
                status="🟢 ON(${oc})"; status_wide=1
            else
                status="⚫ OFF"; status_wide=1
            fi
        fi

        local tl tx rx traffic
        tl=$(get_user_traffic "$user")
        tx=$(echo "$tl" | cut -d'|' -f2)
        rx=$(echo "$tl" | cut -d'|' -f3)
        traffic="↑$(format_bytes "$tx") ↓$(format_bytes "$rx")"

        local sp sp_tx sp_rx speed
        sp=$(get_user_speed "$user")
        sp_tx=$(echo "$sp" | cut -d'|' -f2)
        sp_rx=$(echo "$sp" | cut -d'|' -f3)
        if [ "${sp_tx:-0}" -eq 0 ] && [ "${sp_rx:-0}" -eq 0 ] 2>/dev/null; then
            speed="—"
        else
            speed="↑$(format_speed_short "$sp_tx") ↓$(format_speed_short "$sp_rx")"
        fi

        local ipc exp
        ipc=$(get_user_ip_count "$user")
        exp=$(expiry_cell "$(get_user_expiry "$user")")

        printf '  '
        print_cell "$num"     3  0 r;           printf ' '
        print_cell "$(trunc "$user" 14)" 14 0;  printf ' '
        print_cell "$status"  9  "$status_wide"; printf ' '
        print_cell "$speed"   14 0;             printf ' '
        print_cell "$traffic" 16 0;             printf ' '
        print_cell "$ipc"     3  0 r;           printf ' '
        print_cell "$exp"     6  0;             printf '\n'
    done

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ====================== ПОДМЕНЮ ДЕЙСТВИЙ ======================

user_action_menu() {
    local user="$1"
    local need_clear=1
    while true; do
        # Живые данные: онлайн-статус, трафик и текущая скорость
        refresh_online
        collect_traffic

        local frame
        frame=$(_render_user_action "$user")
        [ "$need_clear" = 1 ] && { clear; need_clear=0; }
        render_frame "$frame"

        local act
        # Автообновление: нет ввода за REFRESH_INTERVAL сек — перерисовываем
        if ! ask act "  Действие (обновление каждые ${REFRESH_INTERVAL}с): " "$REFRESH_INTERVAL"; then
            continue
        fi

        case "$act" in
            1)
                if is_user_disabled "$user"; then
                    enable_user "$user"
                else
                    disable_user "$user"
                fi
                refresh_online
                pause
                need_clear=1
                ;;
            2)
                change_user_password "$user"
                echo "  ⚠️  Пользователю нужна новая ссылка!"
                pause
                need_clear=1
                ;;
            3)
                local confirm
                ask confirm "  ⚠️  Удалить $user ПОЛНОСТЬЮ? (да/нет): "
                if is_yes "$confirm"; then
                    delete_user "$user"
                    pause
                    return
                fi
                need_clear=1
                ;;
            4)
                local confirm
                ask confirm "  Сбросить статистику $user? (да/нет): "
                is_yes "$confirm" && reset_user_stats "$user"
                pause
                need_clear=1
                ;;
            5)
                echo ""
                local cur_exp rem new_days new_date
                cur_exp=$(get_user_expiry "$user")
                if [ -n "$cur_exp" ]; then
                    rem=$(format_remaining "$cur_exp")
                    echo "  Текущий срок: $cur_exp (осталось $rem)"
                else
                    echo "  Срок действия не установлен."
                fi
                ask new_days "  Срок в днях от сегодня (0 или 'нет' — снять): "
                if [ "$new_days" = "нет" ] || [ "$new_days" = "0" ]; then
                    remove_user_expiry "$user"
                    echo "  ✅ Срок действия снят"
                elif [[ "$new_days" =~ ^[0-9]+$ ]]; then
                    new_date=$(days_to_date "$new_days")
                    if [ -n "$new_date" ]; then
                        set_user_expiry "$user" "$new_date"
                        echo "  ✅ Срок действия: $new_date (через $new_days дн.)"
                    else
                        echo "  ❌ Не удалось вычислить дату"
                    fi
                else
                    echo "  ❌ Введите число дней"
                fi
                pause
                need_clear=1
                ;;
            6)
                collect_ips
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
                pause
                need_clear=1
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
                    local link
                    link=$(build_user_link "$user" "$pass" "$CACHED_IP" "$CACHED_PORT" "$CACHED_OBFS" "$CACHED_SNI")
                    echo ""
                    echo "  🔗 ССЫЛКА:"
                    echo "  $link"
                    echo ""
                    echo "  💡 Hiddify, Nekobox, Streisand и т.д."
                else
                    echo "  ❌ Не удалось получить пароль"
                fi
                pause
                need_clear=1
                ;;
            8)
                is_user_disabled "$user" && echo "  ⚠️  Пользователь отключён! Конфиг не будет работать."
                echo ""
                echo "  Тип конфига sing-box:"
                echo "    1. TUN — полный туннель, весь трафик (ПК/телефон)"
                echo "    2. SOCKS/mixed — локальный прокси 127.0.0.1:1080 (тест, сервер)"
                local cfgtype mode
                ask cfgtype "  Выберите (1/2, по умолчанию 1): "
                if [ "$cfgtype" = "2" ]; then mode="socks"; else mode="tun"; fi
                local cfg
                cfg=$(generate_user_config "$user" "$mode")
                if [ -n "$cfg" ]; then
                    echo ""
                    echo "  📄 sing-box JSON-КОНФИГ (${mode}) для $user:"
                    echo "  ────────────────────────────────────────────────────────"
                    cat "$cfg"
                    echo "  ────────────────────────────────────────────────────────"
                    echo "  Временный путь: $cfg"
                    echo "  💡 Установить как конфиг sing-box:"
                    echo "     cp $cfg /etc/sing-box/config.json && systemctl restart sing-box"
                    echo "  💡 Проверить: sing-box -C /etc/sing-box check"
                    if [ "$mode" = "socks" ]; then
                        echo "  💡 Проверка прокси (хост не в туннеле):"
                        echo "     curl --socks5-hostname 127.0.0.1:1080 ifconfig.me"
                    fi
                else
                    echo "  ❌ Не удалось создать конфиг"
                fi
                pause
                need_clear=1
                ;;
            9)
                if ! sub_enabled; then
                    echo "  ❌ Подписка не настроена (Настройки → Подписка / Кластер)"
                else
                    sub_refresh
                    echo ""
                    echo "  🌐 ССЫЛКА-ПОДПИСКА (ключи со всех серверов, автообновление):"
                    echo "  $(subscription_url "$user")"
                    echo ""
                    echo "  💡 Одна ссылка на все ноды. Добавьте в Hiddify/Nekobox как подписку."
                    echo "  ℹ️  Покрываются ноды, где этот юзер заведён тем же именем."
                fi
                pause
                need_clear=1
                ;;
            0) return ;;
        esac
    done
}

# Печатает «карточку» пользователя (кадр для render_frame).
_render_user_action() {
    local user="$1"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Пользователь: $user"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if is_user_disabled "$user"; then
        echo "  Статус:        🔴 ОТКЛЮЧЁН"
    else
        local oc
        oc=$(get_user_online_count "$user")
        if [ "${oc:-0}" -gt 0 ] 2>/dev/null; then
            echo "  Статус:        🟢 ОНЛАЙН ($oc на этой ноде)"
        else
            echo "  Статус:        ⚫ ОФФЛАЙН (на этой ноде)"
        fi
    fi

    # Подключения по подписке СУММАРНО по кластеру (а не только на этой ноде).
    if sub_enabled; then
        local cc lim warn=""
        cc=$(cluster_user_connections "$user")
        lim=$(get_device_limit)
        if [ "$lim" -gt 0 ] 2>/dev/null; then
            [ "$cc" -gt "$lim" ] 2>/dev/null && warn="  ⚠️ превышение!"
            echo "  Подписка:      🌐 $cc подключений по кластеру / лимит $lim$warn"
        else
            echo "  Подписка:      🌐 $cc подключений по кластеру (лимит выкл)"
        fi
    fi

    local tl tx rx
    tl=$(get_user_traffic "$user")
    tx=$(echo "$tl" | cut -d'|' -f2)
    rx=$(echo "$tl" | cut -d'|' -f3)
    echo "  Трафик:        ↑$(format_bytes "$tx") / ↓$(format_bytes "$rx")"

    local sp sp_tx sp_rx
    sp=$(get_user_speed "$user")
    sp_tx=$(echo "$sp" | cut -d'|' -f2)
    sp_rx=$(echo "$sp" | cut -d'|' -f3)
    echo "  Скорость:      ↑$(format_speed "$sp_tx") / ↓$(format_speed "$sp_rx")"

    local ipc
    ipc=$(get_user_ip_count "$user")
    echo "  Уникальных IP: $ipc"
    if [ "$ipc" -gt 3 ] 2>/dev/null; then
        echo "  ⚠️  Подозрительно много IP — возможна утечка!"
    fi

    local exp rem
    exp=$(get_user_expiry "$user")
    if [ -n "$exp" ]; then
        rem=$(format_remaining "$exp")
        if [ "$rem" = "истёк" ]; then
            echo "  Срок действия: $exp (истёк)"
        else
            echo "  Срок действия: $exp (осталось $rem)"
        fi
    else
        echo "  Срок действия: не установлен"
    fi

    is_restart_pending && echo "  ⚠️  Есть изменения, ожидающие перезапуска Hysteria"

    echo ""
    if is_user_disabled "$user"; then
        echo "  1. ✅ Включить"
    else
        echo "  1. 🔴 Отключить"
    fi
    echo "  2. 🔑 Сменить пароль"
    echo "  3. 🗑  Удалить полностью"
    echo "  4. 📊 Сбросить статистику"
    echo "  5. ⏰ Установить срок действия (в днях)"
    echo "  6. 🌐 Просмотр IP-адресов"
    echo "  7. 🔗 Получить ссылку"
    echo "  8. 📄 Конфиг для sing-box"
    sub_enabled && echo "  9. 🌐 Ссылка-подписка (все серверы кластера)"
    echo "  0. ↩  Назад"
    echo ""
}

# ====================== СПИСОК ПОЛЬЗОВАТЕЛЕЙ ======================

user_list_menu() {
    local page=1 need_clear=1
    while true; do
        # Живые данные таблицы: онлайн-статус, трафик и скорость
        refresh_online
        collect_traffic
        load_user_list

        if [ "$USER_LIST_TOTAL" -eq 0 ]; then
            clear
            echo "  Нет пользователей."
            echo ""
            pause "  Enter для возврата..."
            return
        fi

        [ "$page" -gt "$USER_LIST_PAGES" ] && page=$USER_LIST_PAGES
        [ "$page" -lt 1 ] && page=1

        local frame
        frame=$(
            render_user_table "$page" "Пользователи — статистика и действия"
            echo ""
            if [ "$USER_LIST_PAGES" -gt 1 ]; then
                echo "  [1-${USER_LIST_TOTAL}] действия  |  ←/→ страницы  |  [0] назад"
            else
                echo "  [1-${USER_LIST_TOTAL}] действия  |  [0] назад"
            fi
            is_restart_pending && echo "  ⚠️  Есть изменения, ожидающие перезапуска (Настройки → Перезапустить)"
        )
        [ "$need_clear" = 1 ] && { clear; need_clear=0; }
        render_frame "$frame"

        printf '  Ввод (← / → — страницы, обновление %sс): ' "$REFRESH_INTERVAL"
        local key
        key=$(read_key "$REFRESH_INTERVAL")

        case "$key" in
            TIMEOUT|ENTER|ESC) ;;                       # просто перерисуем
            LEFT|UP)    ((page--)); [ "$page" -lt 1 ] && page=1 ;;
            RIGHT|DOWN) ((page++)); [ "$page" -gt "$USER_LIST_PAGES" ] && page=$USER_LIST_PAGES ;;
            0) return ;;
            [1-9])
                # Первая цифра уже нажата — показываем её и дочитываем остаток номера
                printf '%s' "$key"
                local rest input
                read -r rest
                input="${key}${rest}"
                if [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 1 ] && [ "$input" -le "$USER_LIST_TOTAL" ] 2>/dev/null; then
                    user_action_menu "${USER_LIST_ARRAY[$((input - 1))]}"
                fi
                need_clear=1
                ;;
        esac
    done
}

# ====================== ИСПРАВЛЕНИЕ / ОБНОВЛЕНИЕ ДАННЫХ ======================
# Чинит типовые проблемы: недоступный API, слетевшие права, рассинхрон базы и
# «нулевую» статистику у работающего клиента. Заодно показывает диагностику —
# каких клиентов Hysteria видит, но менеджер о них не знает.
repair_data() {
    echo ""
    echo "  🔧 Проверка и восстановление данных..."
    echo "  ──────────────────────────────────────────────"

    # 1. Аутентификация и API: пересоздаём скрипт, чиним права, проверяем секрет.
    install_auth_script
    secure_auth_files
    setup_stats_api
    echo "  ✅ Скрипт аутентификации и права восстановлены, API-секрет проверен"

    # 2. Принудительный свежий сбор статистики и IP.
    refresh_online
    collect_traffic
    collect_ips
    echo "  ✅ Онлайн, трафик и IP пересобраны"

    # 3. Диагностика расхождений между Hysteria и базой менеджера.
    local online traffic
    online=$(api_get "/online")
    if [ -z "$online" ] || ! echo "$online" | jq empty 2>/dev/null; then
        echo "  ⚠️  API Hysteria не отвечает — проверьте секцию trafficStats и сервис."
        echo "      journalctl -u $SERVICE -e"
        return
    fi
    echo "  ✅ API Hysteria отвечает"

    traffic=$(api_get "/traffic")
    local seen id ghost=0
    seen=$(
        { echo "$online"  | jq -r 'keys[]?' 2>/dev/null
          echo "$traffic" | jq -r 'keys[]?' 2>/dev/null; } | sort -u
    )
    while IFS= read -r id; do
        [ -z "$id" ] && continue
        if ! db_user_exists "$id" && ! is_user_disabled "$id"; then
            echo "  ⚠️  Hysteria знает клиента «$id», которого НЕТ в базе менеджера!"
            echo "      Добавьте его заново тем же именем или удалите подключение."
            ghost=$((ghost + 1))
        fi
    done <<< "$seen"
    [ "$ghost" -eq 0 ] && echo "  ✅ Все активные клиенты присутствуют в базе менеджера"

    local total
    total=$(grep -c '^' "$USERS_DB" 2>/dev/null | tr -dc '0-9')
    echo "  ℹ️  Пользователей в базе: ${total:-0}"
    echo "  ✅ Готово."
}

# ====================== НАСТРОЙКИ ======================

settings_menu() {
    while true; do
        clear
        local autostart_status autostart_label
        if systemctl is-enabled --quiet "$SERVICE" 2>/dev/null; then
            autostart_status="✅ включён"
            autostart_label="Отключить автозапуск Hysteria"
        else
            autostart_status="❌ отключён"
            autostart_label="Включить автозапуск Hysteria"
        fi

        local hy_status
        if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
            hy_status="🟢 Работает"
        else
            hy_status="🔴 Остановлен"
        fi

        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  ⚙  Настройки менеджера"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Состояние Hysteria : $hy_status"
        echo "  Автозапуск Hysteria: $autostart_status"
        if is_restart_pending; then
            echo "  Изменения конфига  : ⚠️  ожидают перезапуска"
        else
            echo "  Изменения конфига  : ✅ применены"
        fi
        echo ""
        echo "  1. 🔁 $autostart_label"
        if is_restart_pending; then
            echo "  2. 🔄 Перезапустить Hysteria  ⚠️ (применить изменения)"
        else
            echo "  2. 🔄 Перезапустить Hysteria"
        fi
        echo "  3. 🔧 Исправить / обновить данные (если статистика не сходится)"
        echo "  4. 🌐 Подписка / Кластер (единая ссылка на все серверы)"
        echo "  0. ↩  Назад"
        echo ""
        local choice
        ask choice "  Выберите: "

        case "$choice" in
            1)
                if systemctl is-enabled --quiet "$SERVICE" 2>/dev/null; then
                    if systemctl disable "$SERVICE" 2>/dev/null; then
                        echo "  ✅ Автозапуск Hysteria отключён"
                    else
                        echo "  ❌ Не удалось отключить автозапуск"
                    fi
                else
                    if systemctl enable "$SERVICE" 2>/dev/null; then
                        echo "  ✅ Автозапуск Hysteria включён"
                    else
                        echo "  ❌ Не удалось включить автозапуск"
                    fi
                fi
                sleep 1.5
                ;;
            2)
                echo ""
                local confirm
                ask confirm "  Перезапустить Hysteria сейчас? Всех на пару секунд отключит. (да/нет): "
                if is_yes "$confirm"; then
                    restart_hysteria
                else
                    echo "  Отменено."
                fi
                pause
                ;;
            3)
                repair_data
                pause
                ;;
            4)
                subscription_menu
                ;;
            0) return ;;
            *)
                echo "  ❌ Неверный выбор!"
                sleep 1
                ;;
        esac
    done
}

# ====================== ПОДПИСКА / КЛАСТЕР ======================
# Единая подписка: клиент добавляет одну ссылку https://<домен>/sub/<token>, а
# нода отдаёт ключи юзера со ВСЕХ серверов кластера (статику раздаёт Caddy).
subscription_menu() {
    while true; do
        clear
        local host caddy_st cert_st
        host=$(node_host)
        if ! command -v caddy &>/dev/null; then
            caddy_st="не установлен"
        elif systemctl is-active --quiet caddy 2>/dev/null; then
            caddy_st="🟢 работает$(systemctl is-enabled --quiet caddy 2>/dev/null && echo ', автозапуск вкл')"
        else
            caddy_st="🔴 остановлен"
        fi

        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  🌐 Подписка / Кластер"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        if sub_enabled; then
            echo "  Состояние : 🟢 включена"
            echo "  Нода      : $(node_name)  ($host)"
            # Живой статус сертификата — подтверждает, что домен реально привязан.
            if cert_ready "$host"; then
                cert_st="🟢 валиден до $(cert_expiry "$host") (автопродление)"
            else
                cert_st="🔴 не подтверждён (HTTPS не работает — см. пункт 1)"
            fi
            echo "  Сертификат: $cert_st"
        else
            echo "  Состояние : ⚪ не настроена"
        fi
        echo "  Caddy     : $caddy_st"
        echo "  Нод в кластере: $(grep -c '^' "$CLUSTER_CONF" 2>/dev/null | tr -dc '0-9' || echo 0)"
        local dlim; dlim=$(get_device_limit)
        if [ "$dlim" -gt 0 ] 2>/dev/null; then
            echo "  Лимит устройств на подписку: $dlim (по всему кластеру)"
        else
            echo "  Лимит устройств на подписку: ∞ (выкл)"
        fi
        echo ""
        echo "  1. 🌐 Настроить домен и включить подписку"
        echo "  2. 🔗 Создать кластер (получить join-токен)"
        echo "  3. 🔌 Подключиться к кластеру по токену"
        echo "  4. ➕ Добавить пир вручную (домен ноды)"
        echo "  5. 📋 Список нод кластера"
        echo "  6. 🔄 Синхронизировать сейчас"
        echo "  7. 🔢 Лимит устройств на подписку"
        echo "  0. ↩  Назад"
        echo ""
        local choice
        ask choice "  Выберите: "

        case "$choice" in
            1)
                echo ""
                local domain name dph rc
                ask domain "  Домен этой ноды (A-запись на её IP, напр. vpn1.example.com): "
                domain=$(printf '%s' "$domain" | tr -d '[:space:]' | tr 'A-Z' 'a-z')
                if ! valid_domain "$domain"; then
                    echo "  ❌ «$domain» не похоже на домен. Нужен FQDN, напр. vpn1.example.com"
                    echo "     Сертификат на произвольную строку выдать невозможно."
                    pause; continue
                fi
                # Проверяем, что домен реально указывает на этот сервер — иначе
                # Let's Encrypt не подтвердит владение и сертификата не будет.
                echo "  ⏳ Проверяю DNS для $domain ..."
                domain_points_here "$domain"; rc=$?
                if [ "$rc" -eq 0 ]; then
                    echo "  ✅ DNS: $domain → $(get_ip) (этот сервер)"
                elif [ "$rc" -eq 2 ]; then
                    echo "  ❌ Домен $domain не резолвится."
                    echo "     Создайте A-запись $domain → $(get_ip) и дайте DNS распространиться."
                    local c; ask c "  Всё равно продолжить (сертификат пока не выпустится)? (да/нет): "
                    is_yes "$c" || { echo "  Отменено."; pause; continue; }
                else
                    echo "  ⚠️  $domain резолвится НЕ на этот сервер."
                    echo "     Адрес(а) домена: $(resolve_domain "$domain" | tr '\n' ' ')"
                    echo "     Этот сервер:     $(get_ip)"
                    echo "     Let's Encrypt не выдаст сертификат, пока A-запись не указывает сюда."
                    local c; ask c "  Всё равно продолжить? (да/нет): "
                    is_yes "$c" || { echo "  Отменено."; pause; continue; }
                fi
                ask name "  Имя ноды (метка в клиенте, Enter — $(hostname -s 2>/dev/null || echo node)): "
                [ -z "$name" ] && name=$(hostname -s 2>/dev/null || echo node)
                echo "  ⏳ Проверяю/устанавливаю Caddy..."
                if ! ensure_caddy; then
                    echo "  ❌ Не удалось установить Caddy. Установите вручную и повторите."
                    pause; continue
                fi
                node_configure "$domain" "$name"
                cluster_add_peer "$name" "$domain"
                setup_caddy "$domain"
                sub_refresh
                publish_peers_list
                # Подтверждаем РЕАЛЬНЫЙ выпуск доверенного сертификата, а не просто
                # «записали домен». Без этого подписка по HTTPS не работает.
                echo "  ⏳ Запрашиваю TLS-сертификат (Let's Encrypt), до ~45 сек..."
                if wait_cert "$domain" 15; then
                    echo "  ✅ Сертификат выдан и доверенный — подписка активна."
                    echo "     Домен      : $domain"
                    echo "     Действителен до: $(cert_expiry "$domain")"
                    echo "     🔄 Caddy продлевает сертификат автоматически (бессрочно),"
                    echo "        пока сервис caddy включён и открыт порт 80/tcp."
                else
                    echo "  ⚠️  Сертификат пока НЕ подтверждён — HTTPS-подписка ещё не работает."
                    echo "     Частые причины: A-запись не на этот сервер; закрыт 80/tcp;"
                    echo "     DNS не распространился. Диагностика:"
                    echo "        journalctl -u caddy -e | tail -n 40"
                    echo "     Когда поправите — Caddy выпустит сертификат сам, либо повторите пункт 1."
                fi
                pause
                ;;
            2)
                if ! sub_enabled; then echo "  ❌ Сначала настройте домен (пункт 1)"; sleep 2; continue; fi
                echo ""
                echo "  🔗 JOIN-ТОКЕН (вставьте его на других нодах, пункт 3):"
                echo ""
                echo "  $(cluster_init)"
                echo ""
                echo "  ℹ️  После подключения новой ноды добавьте её домен здесь (пункт 4)."
                pause
                ;;
            3)
                if ! sub_enabled; then echo "  ❌ Сначала настройте домен (пункт 1)"; sleep 2; continue; fi
                echo ""
                local token
                ask token "  Вставьте join-токен: "
                [ -z "$token" ] && { echo "  Отменено."; sleep 1; continue; }
                cluster_join "$token"
                pause
                ;;
            4)
                echo ""
                local phost
                ask phost "  Домен пира (напр. vpn2.example.com): "
                if [ -n "$phost" ]; then
                    cluster_add_peer "$phost" "$phost"
                    publish_peers_list
                    cluster_sync
                    echo "  ✅ Пир $phost добавлен и синхронизирован."
                fi
                pause
                ;;
            5)
                echo ""
                echo "  Ноды кластера (name | host):"
                echo "  ────────────────────────────────────"
                if [ -s "$CLUSTER_CONF" ]; then
                    sed 's/^/    /' "$CLUSTER_CONF"
                else
                    echo "    (пусто — кластер не настроен)"
                fi
                pause
                ;;
            6)
                echo ""
                echo "  ⏳ Синхронизация с пирами..."
                cluster_sync
                echo "  ✅ Готово."
                pause
                ;;
            7)
                echo ""
                echo "  Лимит — сколько устройств может одновременно подключаться по ОДНОЙ"
                echo "  подписке СУММАРНО по всем нодам. Лишние сессии будут отключаться."
                echo "  Текущий: $(get_device_limit)  (0 = без лимита)"
                local nlim
                ask nlim "  Новый лимит (число, 0 — выключить): "
                if [[ "$nlim" =~ ^[0-9]+$ ]]; then
                    set_device_limit "$nlim"
                    if [ "$nlim" -gt 0 ]; then
                        echo "  ✅ Лимит: $nlim устройств на подписку (по кластеру)."
                        echo "     Применяется в течение ~1 мин (cron --online-sync) на каждой ноде."
                        echo "     ⚠️ Лимит должен быть одинаковым на ВСЕХ нодах — задайте его на каждой."
                    else
                        echo "  ✅ Лимит снят (без ограничений)."
                    fi
                else
                    echo "  ❌ Нужно число."
                fi
                pause
                ;;
            0) return ;;
            *)
                echo "  ❌ Неверный выбор!"
                sleep 1
                ;;
        esac
    done
}

# ====================== ПОЛУЧЕНИЕ ССЫЛКИ ======================

get_link_menu() {
    local page=1 need_clear=1
    while true; do
        refresh_online
        load_user_list

        if [ "$USER_LIST_TOTAL" -eq 0 ]; then
            clear
            echo "  Нет пользователей."
            echo ""
            pause "  Enter для возврата..."
            return
        fi

        [ "$page" -gt "$USER_LIST_PAGES" ] && page=$USER_LIST_PAGES
        [ "$page" -lt 1 ] && page=1

        local frame
        frame=$(
            render_user_table "$page" "Выберите пользователя для получения ссылки"
            echo ""
            if [ "$USER_LIST_PAGES" -gt 1 ]; then
                echo "  [1-${USER_LIST_TOTAL}] ссылка  |  ←/→ страницы  |  [0] назад"
            else
                echo "  [1-${USER_LIST_TOTAL}] ссылка  |  [0] назад"
            fi
        )
        [ "$need_clear" = 1 ] && { clear; need_clear=0; }
        render_frame "$frame"

        printf '  Номер (← / → — страницы): '
        local key
        key=$(read_key "")

        case "$key" in
            TIMEOUT|ENTER|ESC) ;;
            LEFT|UP)    ((page--)); [ "$page" -lt 1 ] && page=1 ;;
            RIGHT|DOWN) ((page++)); [ "$page" -gt "$USER_LIST_PAGES" ] && page=$USER_LIST_PAGES ;;
            0) return ;;
            [1-9])
                printf '%s' "$key"
                local rest input
                read -r rest
                input="${key}${rest}"
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
                    pause
                fi
                need_clear=1
                ;;
        esac
    done
}
