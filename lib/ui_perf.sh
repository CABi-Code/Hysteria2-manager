#!/bin/bash
# ================================================
# Производительность и лимит скорости (см. lib/perf.sh)
# Часть UI (см. lib/ui.sh — снимок статистики и примитивы таблицы).
# ================================================

# ====================== ПРОИЗВОДИТЕЛЬНОСТЬ / ЛИМИТ СКОРОСТИ ======================
# Двухуровневый лимит скорости на клиента + защита слабого сервера. См. lib/perf.sh:
#   уровень 1 — bandwidth в config.yaml (для Brutal-клиентов, нужен рестарт);
#   уровень 2 — kernel-лимит на IP клиента (для ВСЕХ, сразу): tc-ШЕЙПИНГ без потерь
#              пакетов (fallback — дроп nft/iptables, если нет tc).
# Параметры зависят от железа ноды и по кластеру НЕ синхронизируются.

# Задать лимит скорости. Механизм — kernel/tc (шейпинг на уровне ядра): действует
# СРАЗУ и на ВСЕ протоколы (Hysteria/VLESS/SS/Trojan/TUIC), переживает ребут,
# перезапуск ядер НЕ требуется. Конфиг Hysteria (Brutal-bandwidth) тут НЕ трогаем —
# именно он раньше требовал рестарт; сам лимит его не требует. Тонкую подстройку
# Brutal под слабый клиент оставили отдельным пунктом (set_bandwidth), она опциональна.
_perf_set_limit() {   # down_mbit up_mbit -> 0 если что-то применилось
    local d="$1" u="$2"
    klimit_apply "$d" "$u"; local krc=$?
    if [ "$d" -eq 0 ] && [ "$u" -eq 0 ]; then
        echo "  ✅ Лимит скорости снят (сразу, без перезапуска)."
        return 0
    elif [ "$krc" -eq 0 ]; then
        echo "  ✅ Лимит АКТИВЕН ПРЯМО СЕЙЧАС на ВСЕХ протоколах: ↓ ${d} · ↑ ${u} Мбит/с на IP клиента."
        echo "     Шейпинг ядром без потери пакетов (tc HTB+fq_codel), автозагрузка после ребута."
        echo "     Перезапуск ядер НЕ нужен."
        return 0
    elif [ "$krc" -eq 2 ]; then
        echo "  ⚠️  В системе нет ни tc, ни nft, ни iptables — kernel-потолок поставить нечем."
        return 1
    else
        echo "  ⚠️  Не удалось загрузить kernel-правила — journalctl -u hy2-limit -e"
        return 1
    fi
}

perf_menu() {
    local changed=0
    while true; do
        clear
        local bu bd icb kd ku
        bu=$(bw_up_get); bd=$(bw_down_get); icb=$(icbw_get)
        kd=$(klimit_down); ku=$(klimit_up)
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  ⚡ Производительность / лимит скорости — нода «$(node_name 2>/dev/null || echo local)»"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Лимит скорости НА КЛИЕНТА (kernel/tc — сразу, все протоколы, без перезапуска):"
        if [ "${kd:-0}" -gt 0 ] || [ "${ku:-0}" -gt 0 ]; then
            if klimit_active; then
                echo "   • Kernel (все клиенты):  💚 ↓ ${kd} · ↑ ${ku} Мбит/с на IP — работает сейчас"
            else
                echo "   • Kernel (все клиенты):  🔴 настроен ↓ ${kd} · ↑ ${ku}, но правила НЕ загружены (пункт 7)"
            fi
        else
            echo "   • Kernel (все клиенты):  ⚪ выключен"
        fi
        if [ -n "$bu" ] || [ -n "$bd" ]; then
            echo "   • Hysteria Brutal-hint:  💚 ↓ ${bu:-∞} · ↑ ${bd:-∞} (опц., подстройка Brutal; смена требует рестарта Hysteria)"
        else
            echo "   • Hysteria Brutal-hint:  ⚪ не задан (лимит и без него работает через ядро)"
        fi
        if [ "$icb" = "true" ]; then
            echo "  Режим перегрузки: BBR — деление канала поровну (лимит Hysteria в этом режиме НЕ действует)"
        else
            echo "  Режим перегрузки: Brutal / по заявке клиента (лимит Hysteria действует)"
        fi
        echo "  QUIC recv-окна: stream $(format_bytes "$(quic_get initStreamReceiveWindow)")/$(format_bytes "$(quic_get maxStreamReceiveWindow)") · conn $(format_bytes "$(quic_get initConnReceiveWindow)")/$(format_bytes "$(quic_get maxConnReceiveWindow)")"
        if perf_tune_active; then
            echo "  Системный тюнинг: 🛡 «Слабый сервер» ($(grep -oP 'CPUQuota=\K\S+' "$PERF_DROPIN" 2>/dev/null), GOMEMLIMIT $(grep -oP 'GOMEMLIMIT=\K\S+' "$PERF_DROPIN" 2>/dev/null))"
        else
            echo "  Системный тюнинг: обычный (без ограничений CPU/RAM)"
        fi
        is_restart_pending && echo "  ⚠️  изменения конфига ожидают перезапуска Hysteria (пункт 8)"
        echo ""
        echo "  1. 🚦 Задать лимит скорости на клиента (сразу, без перезапуска)"
        echo "  2. ♾  Снять лимит скорости полностью"
        echo "  3. ⚖  Режим перегрузки: $([ "$icb" = "true" ] && echo "переключить на Brutal (потолок)" || echo "переключить на BBR (честное деление)")"
        echo "  4. 🛡 Профиль «Слабый сервер» (QUIC-окна + CPUQuota/GOMEMLIMIT + лимит)"
        echo "  5. 🚀 Профиль «Обычный сервер» (снять системные ограничения)"
        echo "  6. 🔧 Тонкая настройка QUIC-окон вручную"
        echo "  7. 🩺 Проверить, применились ли лимиты (диагностика)"
        echo "  8. 🔄 Перезапустить Hysteria (применить конфиг)"
        echo "  0. ↩  Назад"
        echo ""
        local ch; ask ch "  Выберите: "
        case "$ch" in
            1)
                echo ""
                echo "  Лимит применяется НА КАЖДОГО клиента (по IP). 0 = сторона без лимита."
                local d u
                ask d "  ↓ скачивание клиента, Мбит/с: "
                ask u "  ↑ отдача клиента, Мбит/с (Enter = как скачивание): "
                [ -z "$u" ] && u="$d"
                if [[ "$d" =~ ^[0-9]+$ ]] && [[ "$u" =~ ^[0-9]+$ ]]; then
                    _perf_set_limit "$d" "$u" && changed=1
                else
                    echo "  ❌ Нужны целые числа (Мбит/с)."
                fi
                pause ;;
            2)
                _perf_set_limit 0 0 && changed=1
                pause ;;
            3)
                if [ "$icb" = "true" ]; then
                    if set_ignore_client_bw false; then
                        echo "  ✅ Режим: Brutal/по клиенту — лимит из конфига снова действует."
                    else echo "  ❌ Ошибка записи конфига."; fi
                else
                    if set_ignore_client_bw true; then
                        echo "  ✅ Режим: BBR — канал делится честно между клиентами."
                        [ -n "$bu$bd" ] && echo "  ⓘ Лимит Hysteria в BBR-режиме не действует, но kernel-лимит (если включён) продолжает работать."
                    else echo "  ❌ Ошибка записи конфига."; fi
                fi
                changed=1; pause ;;
            4)
                echo ""
                if apply_quic_profile weak; then
                    echo "  ✅ QUIC-окна: профиль «Слабый сервер» (щадящие буферы)."
                else
                    echo "  ❌ Не удалось записать QUIC-окна — откат."
                fi
                perf_tune_weak
                echo "  ✅ Системный тюнинг: CPUQuota $(grep -oP 'CPUQuota=\K\S+' "$PERF_DROPIN" 2>/dev/null) + GOMEMLIMIT $(grep -oP 'GOMEMLIMIT=\K\S+' "$PERF_DROPIN" 2>/dev/null) + UDP-буферы."
                echo "     Hysteria больше не сможет съесть 100% CPU и повесить сервер."
                changed=1
                local sc
                ask sc "  Задать лимит скорости на клиента, Мбит/с (Enter — пропустить, рекомендую 20–50): "
                if [[ "$sc" =~ ^[0-9]+$ ]] && [ "$sc" -gt 0 ]; then
                    _perf_set_limit "$sc" "$sc"
                fi
                pause ;;
            5)
                if apply_quic_profile normal; then
                    echo "  ✅ QUIC-окна: профиль «Обычный сервер»."
                else
                    echo "  ❌ Не удалось записать QUIC-окна — откат."
                fi
                perf_tune_normal
                echo "  ✅ Системные ограничения CPU/RAM сняты."
                changed=1; pause ;;
            6)
                echo "  Enter — оставить текущее значение. Размеры окон — в БАЙТАХ (напр. 33554432 = 32 MiB)."
                local a b c e f g cur
                cur=$(quic_get initStreamReceiveWindow); ask a "  initStreamReceiveWindow [${cur:-${QUIC_NORMAL[0]}}]: "; [ -z "$a" ] && a="${cur:-${QUIC_NORMAL[0]}}"
                cur=$(quic_get maxStreamReceiveWindow);  ask b "  maxStreamReceiveWindow  [${cur:-${QUIC_NORMAL[1]}}]: "; [ -z "$b" ] && b="${cur:-${QUIC_NORMAL[1]}}"
                cur=$(quic_get initConnReceiveWindow);   ask c "  initConnReceiveWindow   [${cur:-${QUIC_NORMAL[2]}}]: "; [ -z "$c" ] && c="${cur:-${QUIC_NORMAL[2]}}"
                cur=$(quic_get maxConnReceiveWindow);    ask e "  maxConnReceiveWindow    [${cur:-${QUIC_NORMAL[3]}}]: "; [ -z "$e" ] && e="${cur:-${QUIC_NORMAL[3]}}"
                cur=$(quic_get maxIdleTimeout);          ask f "  maxIdleTimeout          [${cur:-${QUIC_NORMAL[4]}}]: "; [ -z "$f" ] && f="${cur:-${QUIC_NORMAL[4]}}"
                cur=$(quic_get keepAlivePeriod);         ask g "  keepAlivePeriod         [${cur:-${QUIC_NORMAL[5]}}]: "; [ -z "$g" ] && g="${cur:-${QUIC_NORMAL[5]}}"
                if [[ "$a" =~ ^[0-9]+$ ]] && [[ "$b" =~ ^[0-9]+$ ]] && [[ "$c" =~ ^[0-9]+$ ]] && [[ "$e" =~ ^[0-9]+$ ]]; then
                    if set_quic "$a" "$b" "$c" "$e" "$f" "$g"; then changed=1; echo "  ✅ QUIC-окна обновлены."; else echo "  ❌ Ошибка записи — откат."; fi
                else
                    echo "  ❌ Размеры окон должны быть целыми числами (байты)."
                fi
                pause ;;
            7)
                clear
                perf_report
                pause ;;
            8)
                restart_hysteria; changed=0
                echo ""
                perf_report
                pause ;;
            0)
                if [ "$changed" = 1 ] && is_restart_pending; then
                    echo ""
                    local ans; ask ans "  Есть изменения конфига. Перезапустить Hysteria сейчас? (да/нет): "
                    is_yes "$ans" && restart_hysteria
                fi
                return ;;
            *) echo "  ❌ Неверный выбор!"; sleep 1 ;;
        esac
    done
}

