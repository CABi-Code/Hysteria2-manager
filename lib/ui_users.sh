#!/bin/bash
# ================================================
# Меню пользователя: действия, карточка, список, ремонт данных
# Часть UI (см. lib/ui.sh — снимок статистики и примитивы таблицы).
# ================================================

# ====================== ПОДМЕНЮ ДЕЙСТВИЙ ======================

user_action_menu() {
    local user="$1"
    local need_clear=1
    while true; do
        # Живые данные: онлайн-статус, трафик и текущая скорость
        refresh_online
        collect_traffic
        cluster_stats_live      # подтянуть свежую статистику с других нод

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
                    cstate_mark "$user" active     # точка правды: разнести «включён»
                else
                    disable_user "$user"
                    cstate_mark "$user" disabled   # точка правды: разнести «отключён»
                fi
                refresh_online
                offer_sync
                pause
                need_clear=1
                ;;
            2)
                change_user_password "$user"
                echo "  ⚠️  Пользователю нужна новая ссылка!"
                offer_sync
                pause
                need_clear=1
                ;;
            3)
                local confirm
                ask confirm "  ⚠️  Удалить $user ПОЛНОСТЬЮ? (да/нет): "
                if is_yes "$confirm"; then
                    delete_user "$user"
                    offer_sync
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
                local _changed=0
                if [ "$new_days" = "нет" ] || [ "$new_days" = "0" ]; then
                    remove_user_expiry "$user"; _changed=1
                    echo "  ✅ Срок действия снят"
                elif [[ "$new_days" =~ ^[0-9]+$ ]]; then
                    new_date=$(days_to_date "$new_days")
                    if [ -n "$new_date" ]; then
                        set_user_expiry "$user" "$new_date"; _changed=1
                        echo "  ✅ Срок действия: $new_date (через $new_days дн.)"
                    else
                        echo "  ❌ Не удалось вычислить дату"
                    fi
                else
                    echo "  ❌ Введите число дней"
                fi
                # Для кластерного юзера срок влияет на всю подписку — разносим сразу
                # через ЕДИНУЮ синхронизацию (с логом по нодам).
                if [ "$_changed" = 1 ] && sub_enabled && is_cluster_user "$user"; then
                    echo "  🌐 Юзер кластерный — синхронизирую срок на все ноды..."
                    cluster_sync_now
                    echo "  ✅ Срок применён ко всей подписке (на пирах — в течение ~1–5 мин)."
                fi
                pause
                need_clear=1
                ;;
            6)
                collect_ips
                sub_enabled && publish_ips
                echo ""
                echo "  🌐 IP-адреса пользователя $user (по всему кластеру):"
                echo "  ────────────────────────────────────────────────────────"
                # Агрегация локальных + IP с других нод (если есть подключения).
                local ips
                ips=$(cluster_user_ips "$user")
                if [ -z "$ips" ]; then
                    echo "  Нет данных об IP-адресах."
                    echo "  ℹ️  IP появляются после реальных подключений клиента к серверу."
                else
                    printf "  %-16s %-17s %-17s %4s  %s\n" "IP-адрес" "Первое" "Последнее" "Раз" "Ноды"
                    echo "$ips" | while IFS=$'\t' read -r ip fs ls cnt nodes; do
                        local fs_fmt ls_fmt
                        fs_fmt=$(date -d "@$fs" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "—")
                        ls_fmt=$(date -d "@$ls" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "—")
                        printf "  %-16s %-17s %-17s %4s  %s\n" "$ip" "$fs_fmt" "$ls_fmt" "$cnt" "$nodes"
                    done

                    local total_ips recent_ips week_ago
                    total_ips=$(echo "$ips" | grep -c '^')
                    week_ago=$(date -d '7 days ago' +%s 2>/dev/null || echo 0)
                    recent_ips=$(echo "$ips" | awk -F'\t' -v wa="$week_ago" '$3 >= wa' | grep -c '^')
                    echo ""
                    echo "  📊 Всего уникальных IP: $total_ips"
                    echo "  📊 Активных за 7 дней: $recent_ips"
                    echo "  ℹ️  Много разных IP — это НЕ признак шаринга: телефон в роуминге"
                    echo "     меняет IP постоянно, а дома у семьи несколько устройств."
                    # Реальное подозрение — ОДНОВРЕМЕННЫЙ активный трафик на разных нодах.
                    if sub_enabled; then
                        echo ""
                        echo "  🕵️  Анти-абуз (по одновременной активности): $(abuse_status_line "$user")"
                        if abuse_auto_hc_active "$user"; then
                            echo "  🚨 Похоже на шаринг: подписку активно использовали сразу на нескольких нодах —"
                            echo "     на время включена жёсткая проверка (активной остаётся одна нода)."
                        fi
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
                    # link_host, а не CACHED_IP: если настроен домен подключения или
                    # релей — в ссылке должен быть он, иначе утекает реальный IP ноды.
                    local link
                    link=$(build_user_link "$user" "$pass" "$(link_host)" "$CACHED_PORT" "$CACHED_OBFS" "$CACHED_SNI")
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
            10)
                if ! sub_enabled; then
                    echo "  ❌ Кластер не настроен (Настройки → Подписка / Кластер)"
                else
                    echo ""
                    echo "  ⏳ Помечаю $user как кластерного и рассылаю..."
                    cluster_share_user "$user"
                    echo "  ✅ Готово. На нодах, где его нет, он появится в течение ~5 мин"
                    echo "     (там сгенерируется свой пароль; в подписке соберутся ключи со всех нод)."
                    echo "  ℹ️  Условие: между нодами должен работать HTTPS (Диагностика → пункт 8)."
                fi
                pause
                need_clear=1
                ;;
            11)
                clear
                user_debug "$user"
                pause
                need_clear=1
                ;;
            12)
                user_devices_menu "$user"
                need_clear=1
                ;;
            15)
                # Обратная операция к пункту 10: профиль, помеченный кластерным
                # по ошибке, иначе было не вернуть — только удалить целиком.
                if ! sub_enabled; then
                    echo "  ❌ Кластер не настроен (Настройки → Подписка / Кластер)"
                elif ! is_cluster_user "$user"; then
                    echo "  ℹ️  Профиль и так локальный."
                else
                    roster_remove "$user"
                    publish_roster
                    echo "  ✅ Метка «кластерный» снята на этой ноде ($(node_name))."
                    echo "     Профиль и его лимиты остаются здесь, на новые ноды не поедут."
                    local _owners
                    _owners=$(grep -lxF "$user" "$PEERS_DIR"/*.roster 2>/dev/null \
                              | sed 's|.*/||; s|\.roster$||' | tr '\n' ' ')
                    if [ -n "$_owners" ]; then
                        echo "  ⚠️  Кластерным его объявляет ещё: ${_owners% }"
                        echo "     Пока метка стоит там, ноды будут заводить его снова —"
                        echo "     снимите её этим же пунктом на той ноде."
                    fi
                fi
                pause
                need_clear=1
                ;;
            13)
                cluster_sync_now
                pause
                need_clear=1
                ;;
            14)
                echo ""
                echo "  📱 Telegram-привязка для «$user»"
                echo "  ────────────────────────────────────────────────────────"
                local bound_ids ntg
                bound_ids=$(tg_user_chats "$user")
                if [ -n "$bound_ids" ]; then
                    echo "  Привязанные tg_id: $(echo "$bound_ids" | tr '\n' ' ' | sed 's/ *$//')"
                else
                    echo "  Пока не привязан ни один Telegram."
                fi
                echo ""
                echo "  • Введите Telegram ID — привязать этот аккаунт к «$user»."
                echo "    (свой ID клиент узнаёт у @userinfobot; перепривязка с другого"
                echo "     пользователя выполняется автоматически)."
                echo "  • «0» или «нет» — отвязать все Telegram от «$user»."
                echo "  • Enter — назад."
                ask ntg "  Telegram ID: "
                if [ -z "$ntg" ]; then
                    :
                elif [ "$ntg" = "0" ] || [ "$ntg" = "нет" ]; then
                    if [ -n "$bound_ids" ]; then
                        while IFS= read -r _id; do
                            [ -n "$_id" ] && tg_unbind "$_id"
                        done <<< "$bound_ids"
                        echo "  ✅ Все Telegram отвязаны от «$user»."
                        sub_enabled && offer_sync
                    else
                        echo "  Нечего отвязывать."
                    fi
                elif [[ "$ntg" =~ ^[0-9]+$ ]]; then
                    local prev
                    prev=$(tg_bound_user "$ntg")
                    tg_bind "$ntg" "$user"
                    if [ -n "$prev" ] && [ "$prev" != "$user" ]; then
                        echo "  ✅ tg:$ntg перепривязан с «$prev» на «$user»."
                    else
                        echo "  ✅ tg:$ntg привязан к «$user» — веб-апп покажет его профиль."
                    fi
                    sub_enabled && offer_sync
                else
                    echo "  ❌ Telegram ID — это число (например, 123456789)."
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

    local oc
    if is_user_disabled "$user"; then
        echo "  Статус:        🔴 ОТКЛЮЧЁН"
        oc=0
    else
        oc=$(get_user_online_count "$user")
        if [ "${oc:-0}" -gt 0 ] 2>/dev/null; then
            echo "  Статус:        💚 ОНЛАЙН ($oc на этой ноде)"
        else
            echo "  Статус:        ⚫ ОФФЛАЙН (на этой ноде)"
        fi
    fi

    # Статус и статистика в МАСШТАБЕ КЛАСТЕРА.
    if sub_enabled; then
        local cc lim warn="" nodes_online
        cc=$(cluster_user_connections "$user")
        nodes_online=$(cluster_user_breakdown "$user" | awk -F'\t' '$2>0' | wc -l | tr -dc '0-9')
        if [ "${cc:-0}" -gt 0 ] 2>/dev/null; then
            echo "  Статус кластера: 💚 ОНЛАЙН — $cc подключений на ${nodes_online:-0} нод(ах)"
        else
            echo "  Статус кластера: ⚫ оффлайн во всём кластере"
        fi
        local dev pc nc hc hce
        dev=$(get_user_devices "$user"); pc=$(pool_cap "$user"); nc=$(node_cap "$user")
        hc=$(get_user_hardcheck "$user"); hce=$(get_user_hardcheck_effective "$user")
        user_over_limit "$user" "$cc" "$oc" && warn="  ⚠️ превышение!"
        echo "  Устройств (лимит): $dev$([ "$dev" = "0" ] && echo " → глоб.")"
        echo "  Подключений: $cc / pool $([ "$pc" -gt 0 ] && echo "$pc" || echo "∞") · node $([ "$nc" -gt 0 ] && echo "$nc" || echo "∞")$warn"
        if [ "$hc" = "1" ]; then echo "  Жёсткая проверка: 🛡 ВКЛ (вручную)"
        elif [ "$hce" = "1" ]; then echo "  Жёсткая проверка: 🛡 ВКЛ (авто, анти-абуз)"
        else echo "  Жёсткая проверка: выкл"; fi
        echo "  Ссылок подписки: $(sub_tokens_cluster "$user" | grep -c .)"

        # Трафик и скорость — суммарно по кластеру.
        local ct cs ctx crx cstx csrx
        ct=$(cluster_user_traffic "$user"); ctx=${ct%% *}; crx=${ct##* }
        cs=$(cluster_user_speed "$user");   cstx=${cs%% *}; csrx=${cs##* }
        echo "  Трафик (всего): ↑$(format_bytes "$ctx") / ↓$(format_bytes "$crx")"
        echo "  Скорость(всего):↑$(format_speed "$cstx") / ↓$(format_speed "$csrx")"

        # Разбивка по нодам, где юзер сейчас онлайн.
        local any_online=0 bn bo btx brx bstx bsrx
        while IFS=$'\t' read -r bn bo btx brx bstx bsrx; do
            [ "${bo:-0}" -gt 0 ] 2>/dev/null || continue
            [ "$any_online" -eq 0 ] && echo "  Онлайн по нодам:"
            any_online=1
            echo "    • $bn: ${bo} подкл · ↑$(format_bytes "$btx")/↓$(format_bytes "$brx") · ↑$(format_speed_short "$bstx")/↓$(format_speed_short "$bsrx")"
        done < <(cluster_user_breakdown "$user")
    else
        local tl tx rx
        IFS='|' read -r _ tx rx <<< "$(get_user_traffic "$user")"
        echo "  Трафик:        ↑$(format_bytes "$tx") / ↓$(format_bytes "$rx")"
        local sp sp_tx sp_rx
        IFS='|' read -r _ sp_tx sp_rx <<< "$(get_user_speed "$user")"
        echo "  Скорость:      ↑$(format_speed "$sp_tx") / ↓$(format_speed "$sp_rx")"
        local dev nc hc warn=""
        dev=$(get_user_devices "$user"); nc=$(node_cap "$user"); hc=$(get_user_hardcheck "$user")
        user_over_limit "$user" "$oc" "$oc" && warn="  ⚠️ превышение!"
        echo "  Устройств (лимит): $dev · подключений $oc / $([ "$nc" -gt 0 ] && echo "$nc" || echo "∞")$warn"
        echo "  Жёсткая проверка: $([ "$hc" = "1" ] && echo "🛡 ВКЛ" || echo "выкл")"
    fi

    local urate
    urate=$(get_user_rate "$user")
    if [ "$urate" -gt 0 ] 2>/dev/null; then
        echo "  Тариф скорости: 🚀 ${urate} Мбит/с (на IP клиента)"
    fi

    local ipc
    ipc=$(get_user_ip_count "$user")
    echo "  Уникальных IP: $ipc  (роуминг/смена IP — это норма, не признак шаринга)"
    # Подозрение на шаринг теперь считается по ОДНОВРЕМЕННОМУ активному трафику на
    # разных нодах (балл анти-абуза), а не по числу IP (оно ложно срабатывало у
    # роуминга и семьи). См. lib/antiabuse.sh.
    if sub_enabled; then
        echo "  Анти-абуз: $(abuse_status_line "$user")"
        if abuse_auto_hc_active "$user"; then
            echo "  🚨 Похоже на шаринг: активный трафик подписки шёл сразу на нескольких нодах."
        fi
    fi

    local exp rem
    exp=$(get_user_expiry "$user")
    if declare -F freeplan_has >/dev/null 2>&1 && freeplan_has "$user"; then
        # На бесплатном тарифе платный срок в прошлом ПО ЗАМЫСЛУ — писать
        # «истёк» поверх работающего доступа было прямой ложью.
        echo "  Срок действия: 🆓 бесплатный тариф$(freeplan_limits_line)"
        echo "                 (платный был до $exp, состояние: $(freeplan_field "$user" 2))"
    elif [ -n "$exp" ]; then
        rem=$(format_remaining "$exp")
        if [ "$rem" = "истёк" ]; then
            echo "  Срок действия: $exp (истёк)"
        else
            echo "  Срок действия: $exp (осталось $rem)"
        fi
    else
        echo "  Срок действия: бессрочно (срок не задан)"
    fi

    local _tgids
    _tgids=$(tg_user_chats "$user" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')
    if [ -n "$_tgids" ]; then
        echo "  Telegram: 📱 $_tgids"
    else
        echo "  Telegram: не привязан"
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
    if sub_enabled; then
        echo "  9. 🌐 Ссылка-подписка (все серверы кластера)"
        if roster_has "$user"; then
            echo " 10. 🔄 Синхронизировать на все ноды (уже кластерный ✓)"
        else
            echo " 10. 🔄 Завести на всех нодах кластера"
        fi
        is_cluster_user "$user" && echo " 15. 🔒 Вернуть в локальные (снять метку «кластерный»)"
        echo " 11. 🩺 Диагностика профиля (по кластеру)"
    fi
    echo " 12. 🔢 Устройства и ссылки подписки"
    echo " 14. 📱 Привязать/отвязать Telegram (для веб-аппа и бота)"
    sub_enabled && echo " 13. 🔄 Получить синхронизацию (локально)"
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
        cluster_stats_live      # свежая статистика с других нод (троттлинг внутри)
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
                echo "  [1-${USER_LIST_TOTAL}] действия  |  ←/→ страницы  |  $(sub_enabled && echo '[s] синхронизация  |  ')[0] назад"
            else
                echo "  [1-${USER_LIST_TOTAL}] действия  |  $(sub_enabled && echo '[s] синхронизация  |  ')[0] назад"
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
            s|S) clear; cluster_sync_now; pause; need_clear=1 ;;
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

    # Чиним подписку/Caddy, если настроена.
    if sub_enabled; then
        echo "  🌐 Подписка: открываю порты, пересобираю Caddy, проверяю сертификат..."
        ensure_ports_open
        if setup_caddy >/dev/null 2>&1; then
            if cert_ready "$(node_host)"; then
                echo "  ✅ Caddy работает, сертификат валиден до $(cert_expiry "$(node_host)")"
            else
                echo "  ⚠️  Caddy работает, но сертификат ещё не выпущен (проверьте DNS/порт 80)."
            fi
        else
            echo "  ❌ Caddy не запустился — journalctl -u caddy -e | tail -n 30"
        fi
    fi
    echo "  ✅ Готово."
}

