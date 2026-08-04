#!/bin/bash
# ================================================
# Устройства и дополнительные ссылки подписки пользователя
# Часть UI (см. lib/ui.sh — снимок статистики и примитивы таблицы).
# ================================================

# ====================== УСТРОЙСТВА И ССЫЛКИ ПОДПИСКИ ======================
# Персональный лимит устройств (приоритетнее глобальных), жёсткая проверка,
# доп. ссылки подписки со статистикой IP за неделю, ручной кик сессии.
user_devices_menu() {
    local user="$1"
    while true; do
        clear
        refresh_online
        local dev hc oc cc pc nc rate
        dev=$(get_user_devices "$user"); hc=$(get_user_hardcheck "$user")
        rate=$(get_user_rate "$user")
        oc=$(get_user_online_count "$user")
        pc=$(pool_cap "$user"); nc=$(node_cap "$user")
        if sub_enabled; then cc=$(cluster_user_connections "$user"); else cc=$oc; fi

        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  🔢 Устройства и ссылки — $user"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Кол-во устройств (лимит): $dev$([ "$dev" = "0" ] && echo "  (0 = глобальный POOL_LIMIT)")"
        echo "  Эффективно: pool $([ "$pc" -gt 0 ] && echo "$pc" || echo "∞") · node $([ "$nc" -gt 0 ] && echo "$nc" || echo "∞")"
        echo "  Подключений сейчас: $cc$(sub_enabled && echo " (кластер)")$([ "$oc" != "$cc" ] && echo " · $oc на этой ноде")"
        user_over_limit "$user" "$cc" "$oc" && echo "  ⚠️  ПРЕВЫШЕНИЕ ЛИМИТА ПОДКЛЮЧЕНИЙ!"
        if [ "$hc" = "1" ]; then
            echo "  Жёсткая проверка: 🛡 ВКЛючена вручную (активный трафик — только на 1 ноде за раз)"
        elif sub_enabled && abuse_auto_hc_active "$user"; then
            echo "  Жёсткая проверка: 🛡 АВТО-ВКЛ (анти-абуз: замечен шаринг)"
        else
            echo "  Жёсткая проверка: выключена"
        fi
        sub_enabled && echo "  Анти-абуз: $(abuse_status_line "$user")"
        if [ "$rate" -gt 0 ] 2>/dev/null; then
            echo "  Тариф скорости: 🚀 ${rate} Мбит/с (на IP клиента, обе стороны)"
        else
            echo "  Тариф скорости: — (без тарифа → глобальный лимит)"
        fi
        echo ""
        if sub_enabled; then
            echo "  🔗 Ссылки подписки (IP за 7 дней — уникальные скачивания):"
            local -a LINK_TOKENS=(); local li=0 tok primary
            primary=$(sub_token_for "$user")
            while IFS= read -r tok; do
                [ -n "$tok" ] || continue
                li=$((li+1)); LINK_TOKENS[$li]="$tok"
                local mark=""; [ "$tok" = "$primary" ] && mark=" (основная)"
                printf "    %d. …%s%s  ·  IP/нед: %s\n" "$li" "${tok: -8}" "$mark" "$(link_week_ip_count "$tok")"
            done < <(sub_tokens_all "$user")
            [ "$li" -eq 0 ] && echo "    (нет — будет создана основная)"
            echo ""
        fi
        echo "  1. ➕ Добавить устройство (лимит +1)"
        echo "  2. ➖ Убрать устройство (лимит −1)"
        echo "  3. #  Задать кол-во устройств числом"
        echo "  4. 🛡 $([ "$hc" = "1" ] && echo "Выключить" || echo "Включить") жёсткую проверку"
        echo "  5. ✂  Прервать сессию на ЭТОЙ ноде (кик)"
        echo "  9. 🚀 Тариф скорости (100 / 200 / 500 / свой / выкл)"
        if sub_enabled; then
            echo "  6. 🔗 Получить новую доп. ссылку подписки"
            echo "  7. 🗑  Удалить доп. ссылку подписки"
            echo "  8. 🔄 Получить синхронизацию (локально)"
        fi
        echo "  0. ↩  Назад"
        echo ""
        local ch; ask ch "  Выберите: "
        case "$ch" in
            1)
                set_user_devices "$user" $(( dev + 1 ))
                echo "  ✅ Кол-во устройств: $((dev+1))"
                write_authlimits; sub_enabled && { publish_cluster_userlimits; offer_sync; }
                pause ;;
            2)
                if [ "$dev" -le 0 ]; then echo "  Уже 0 (глобальный лимит)."; else
                    set_user_devices "$user" $(( dev - 1 ))
                    echo "  ✅ Кол-во устройств: $((dev-1))"
                    write_authlimits; sub_enabled && { publish_cluster_userlimits; offer_sync; }
                fi
                pause ;;
            3)
                local nd; ask nd "  Кол-во устройств (0 = глобальный лимит): "
                if [[ "$nd" =~ ^[0-9]+$ ]]; then
                    set_user_devices "$user" "$nd"
                    echo "  ✅ Кол-во устройств: $nd"
                    write_authlimits; sub_enabled && { publish_cluster_userlimits; offer_sync; }
                else echo "  ❌ Нужно число."; fi
                pause ;;
            4)
                if [ "$hc" = "1" ]; then set_user_hardcheck "$user" 0; echo "  ✅ Жёсткая проверка выключена."
                else set_user_hardcheck "$user" 1; echo "  ✅ Жёсткая проверка включена — активный трафик подписки допускается только на $([ "$(pool_cap "$user")" -gt 0 ] && pool_cap "$user" || echo 1) ноде(-ах) одновременно (по реальной скорости, не по пингам)."; fi
                write_authlimits; sub_enabled && { publish_cluster_userlimits; offer_sync; }
                pause ;;
            5)
                hy_kick_user "$user" &>/dev/null
                proto_kick_user "$user" 2>/dev/null
                echo "  ✅ Сессии $user на этой ноде сброшены (кик, все протоколы)."
                pause ;;
            6)
                if sub_enabled; then
                    local newtok
                    newtok=$(sub_link_add "$user")
                    if [ -n "$newtok" ]; then
                        sub_refresh
                        echo "  ✅ Новая ссылка подписки:"
                        echo "  https://$(node_host)/sub/$newtok"
                        offer_sync
                    else
                        echo "  ❌ Лимит ссылок исчерпан (= кол-во устройств: $dev)."
                        echo "     Сначала добавьте устройство (пункт 1)."
                    fi
                fi
                pause ;;
            7)
                if sub_enabled; then
                    if [ "${#LINK_TOKENS[@]}" -le 1 ]; then
                        echo "  Нет доп. ссылок для удаления (основную удалить нельзя)."
                    else
                        local dsel; ask dsel "  Номер ссылки для удаления: "
                        if [[ "$dsel" =~ ^[0-9]+$ ]] && [ -n "${LINK_TOKENS[$dsel]:-}" ]; then
                            sub_link_remove "$user" "${LINK_TOKENS[$dsel]}"
                            case $? in
                                0) sub_refresh; echo "  ✅ Ссылка удалена."; offer_sync ;;
                                2) echo "  ❌ Основную ссылку удалить нельзя." ;;
                                *) echo "  ❌ Ссылка не найдена." ;;
                            esac
                        else echo "  ❌ Неверный номер."; fi
                    fi
                fi
                pause ;;
            8) sub_enabled && cluster_sync_now; pause ;;
            9)
                echo ""
                echo "  Текущий тариф: $([ "$rate" -gt 0 ] 2>/dev/null && echo "${rate} Мбит/с" || echo "нет (глобальный лимит)")"
                echo "  Пресеты: 100 · 200 · 500 Мбит/с. Можно ввести своё число."
                local nt; ask nt "  Скорость Мбит/с (0 = снять тариф, Enter — не менять): "
                if [ -z "$nt" ]; then :
                elif [[ "$nt" =~ ^[0-9]+$ ]]; then
                    set_user_rate "$user" "$nt"
                    # Гарантируем HTB-класс под назначенную скорость + мгновенная раскладка IP.
                    klimit_apply "$(klimit_down)" "$(klimit_up)" >/dev/null 2>&1
                    if [ "$nt" -gt 0 ]; then
                        echo "  ✅ Тариф: ${nt} Мбит/с — применится к активным IP клиента (обе стороны)."
                    else
                        echo "  ✅ Тариф снят — действует глобальный лимит."
                    fi
                    # Область действия говорим честно: у локального профиля тариф
                    # никуда не уезжает (и синхронизацию предлагать незачем).
                    write_authlimits
                    if sub_enabled && is_cluster_user "$user"; then
                        echo "     Профиль кластерный — тариф разъедется по всем нодам."
                        publish_cluster_userlimits; offer_sync
                    else
                        echo "     Профиль локальный — тариф действует только на этой ноде ($(node_name))."
                    fi
                else echo "  ❌ Нужно число (Мбит/с)."; fi
                pause ;;
            0) return ;;
            *) echo "  ❌ Неверный выбор."; sleep 1 ;;
        esac
    done
}

