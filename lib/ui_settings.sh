#!/bin/bash
# ================================================
# Меню настроек менеджера
# Часть UI (см. lib/ui.sh — снимок статистики и примитивы таблицы).
# ================================================


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
            hy_status="💚 Работает"
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
        echo "  3. ⚡ Производительность / лимит скорости (защита слабого сервера)"
        echo "  4. 🔧 Исправить / обновить данные (если статистика не сходится)"
        echo "  5. 🌐 Подписка / Кластер (единая ссылка на все серверы)"
        echo "  6. 🤖 Telegram-бот (управление и продажа доступа)"
        echo "  7. 🔄 Получить синхронизацию (локально)"
        local _upd; _upd=$(manager_update_available 2>/dev/null)
        if [ -n "$_upd" ]; then
            echo "  8. ⬆  Обновить менеджер  🔔 доступна v$_upd (у вас v$(manager_local_version))"
        else
            echo "  8. ⬆  Обновить менеджер (проверить и установить с GitHub) · v$(manager_local_version)"
        fi
        echo "  9. 🧩 Протоколы: VLESS+REALITY+XHTTP · Shadowsocks-2022 · TUIC v5"
        if declare -F proto_status_line >/dev/null 2>&1; then
            echo "       [ $(proto_status_line) ]"
        fi
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
                perf_menu
                ;;
            4)
                repair_data
                pause
                ;;
            5)
                subscription_menu
                ;;
            6)
                bot_menu
                ;;
            7)
                cluster_sync_now
                pause
                ;;
            8)
                echo ""
                echo "  ⏳ Проверяю обновления на GitHub..."
                local _loc _rem; _loc=$(manager_local_version); _rem=$(manager_remote_version force)
                echo "  Текущая версия  : v$_loc"
                if [ -z "$_rem" ]; then
                    echo "  Версия в репо   : не удалось получить (проверьте сеть)."
                elif _ver_gt "$_rem" "$_loc"; then
                    echo "  Версия в репо   : v$_rem  ⬆ доступно обновление!"
                elif [ "$_rem" = "$_loc" ]; then
                    echo "  Версия в репо   : v$_rem  ✅ у вас последняя версия"
                else
                    echo "  Версия в репо   : v$_rem  (у вас новее/dev)"
                fi
                echo ""
                echo "  Обновление скачает свежие файлы менеджера с GitHub и заменит текущие."
                echo "  Hysteria, пользователи и настройки НЕ трогаются (режим «только менеджер»)."
                local confirm
                ask confirm "  Обновить сейчас? (да/нет): "
                if is_yes "$confirm"; then
                    manager_do_update
                fi
                pause
                ;;
            9)
                protocols_menu
                ;;
            0) return ;;
            *)
                echo "  ❌ Неверный выбор!"
                sleep 1
                ;;
        esac
    done
}

