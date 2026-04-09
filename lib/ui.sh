#!/bin/bash
# ================================================
# Интерфейс: таблицы, меню пользователей, ссылки
# ================================================

declare -a USER_LIST_ARRAY
USER_LIST_PAGES=1
USER_LIST_TOTAL=0

# ====================== ТАБЛИЦА ПОЛЬЗОВАТЕЛЕЙ ======================

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
