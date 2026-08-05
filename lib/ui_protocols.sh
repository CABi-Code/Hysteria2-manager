#!/bin/bash
# ================================================
# Меню протоколов: включение, параметры, диагностика (см. lib/protocols.sh)
# Часть UI (см. lib/ui.sh — снимок статистики и примитивы таблицы).
# ================================================

# ====================== ПРОТОКОЛЫ ======================
# Управление доп. протоколами рядом с Hysteria: VLESS+REALITY+XHTTP и
# Shadowsocks-2022 (Xray), TUIC v5 (sing-box). Все они попадают в подписку юзера,
# и клиент (Throne/Hiddify) выбирает тот, что проходит в его сети. См.
# lib/protocols.sh и docs/guide/MULTIPROTOCOL.md.
_proto_svc_state() {   # service -> строка со статусом
    if systemctl is-active --quiet "$1" 2>/dev/null; then echo "💚 работает"
    elif systemctl list-unit-files 2>/dev/null | grep -q "^$1"; then echo "🔴 остановлен"
    else echo "⚪ не установлен"; fi
}

protocols_menu() {
    while true; do
        clear
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  🧩 Протоколы (мультипротокольная раздача)"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        if ! sub_enabled; then
            echo "  ⚠️  Сначала настройте подписку (Настройки → 5): доп. протоколы"
            echo "     раздаются клиенту именно через единую ссылку-подписку."
            echo ""
        fi
        local vs ss ts tj
        proto_vless_enabled  && vs="💚 вкл" || vs="⚪ выкл"
        proto_ss_enabled     && ss="💚 вкл" || ss="⚪ выкл"
        proto_tuic_enabled   && ts="💚 вкл" || ts="⚪ выкл"
        proto_trojan_enabled && tj="💚 вкл" || tj="⚪ выкл"
        echo "  1. VLESS + REALITY + XHTTP   : $vs   (TCP $(proto_vless_port))"
        echo "  2. Shadowsocks-2022          : $ss   (TCP $(proto_ss_port), $(proto_ss_method))"
        echo "  3. TUIC v5                   : $ts   (UDP $(proto_tuic_port))"
        echo "  4. Trojan / WebSocket + TLS  : $tj   (TCP $(proto_trojan_port))"
        echo ""
        echo "  Сервисы: Xray $(_proto_svc_state "$XRAY_SERVICE") · sing-box $(_proto_svc_state "$SINGBOX_SERVICE")"
        echo ""
        echo "  5. ⚙  Параметры (порты, шифр SS, REALITY dest/SNI, пути XHTTP/WS)"
        echo "  6. 🔁 Переустановить/пересобрать сервисы (bootstrap)"
        echo "  7. 🔍 Диагностика (версии бинарников, статус, порты)"
        echo "  8. 🌐 Протоколы по нодам кластера"
        echo "  0. ↩  Назад"
        echo ""
        local choice
        ask choice "  Выберите: "
        case "$choice" in
            1) _proto_toggle vless  "VLESS+REALITY+XHTTP" ;;
            2) _proto_toggle ss     "Shadowsocks-2022" ;;
            3) _proto_toggle tuic   "TUIC v5" ;;
            4) _proto_toggle trojan "Trojan/WS" ;;
            5) proto_params_menu ;;
            6)
                echo ""
                if ! proto_any_enabled; then
                    echo "  Нет включённых протоколов — включать нечего."
                else
                    echo "  ⏳ Установка бинарников и пересборка конфигов..."
                    proto_bootstrap && echo "  ✅ Готово" || echo "  ⚠️  Были ошибки — см. вывод выше"
                fi
                pause
                ;;
            7) proto_diagnose_menu ;;
            8) proto_cluster_screen ;;
            0) return ;;
            *) echo "  ❌ Неверный выбор!"; sleep 1 ;;
        esac
    done
}

# Переключить протокол вкл/выкл. При включении ставит движок и поднимает сервис.
_proto_toggle() {   # name human
    local name="$1" human="$2"
    echo ""
    local enabled=0
    case "$name" in
        vless)  proto_vless_enabled  && enabled=1 ;;
        ss)     proto_ss_enabled     && enabled=1 ;;
        tuic)   proto_tuic_enabled   && enabled=1 ;;
        trojan) proto_trojan_enabled && enabled=1 ;;
    esac
    if [ "$enabled" = 1 ]; then
        local c; ask c "  Выключить $human? (да/нет): "
        if is_yes "$c"; then
            proto_disable_protocol "$name"
            echo "  ⚪ $human выключен (сервис остановлен, если больше не нужен)."
        fi
    else
        if ! sub_enabled; then
            echo "  ⚠️  Подписка не настроена — ключи некуда раздавать. Включите её сначала."
            pause; return
        fi
        local c; ask c "  Включить $human? Скачает движок и поднимет сервис. (да/нет): "
        if is_yes "$c"; then
            echo "  ⏳ Устанавливаю и настраиваю..."
            if proto_enable_protocol "$name"; then
                echo "  💚 $human включён. Ключи появятся в подписках всех юзеров."
                sub_refresh
            else
                echo "  ❌ Не удалось включить (см. вывод/лог). Флаг оставлен, повторите bootstrap."
            fi
        fi
    fi
    pause
}

# Параметры протоколов (порты, шифр, REALITY, XHTTP).
proto_params_menu() {
    while true; do
        clear
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  ⚙  Параметры протоколов"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  1. Порт VLESS (TCP)     : $(proto_vless_port)"
        echo "  2. Порт Shadowsocks(TCP): $(proto_ss_port)"
        echo "  3. Порт TUIC (UDP)      : $(proto_tuic_port)"
        echo "  4. Шифр Shadowsocks-2022: $(proto_ss_method)"
        echo "  5. REALITY dest         : $(proto_reality_dest)"
        echo "  6. REALITY SNI          : $(proto_reality_sni)"
        echo "  7. Путь XHTTP           : $(proto_xhttp_path)"
        echo "  8. Порт Trojan (TCP)    : $(proto_trojan_port)"
        echo "  9. Путь WS Trojan       : $(proto_trojan_ws_path)"
        echo ""
        echo "  ⚠️  После смены параметров нужно пересобрать сервисы (Протоколы → 5)."
        echo "  0. ↩  Назад"
        echo ""
        local c v
        ask c "  Что изменить: "
        case "$c" in
            1) ask v "  Новый порт VLESS (TCP): "; [[ "$v" =~ ^[0-9]+$ ]] && proto_set PROTO_VLESS_PORT "$v" ;;
            2) ask v "  Новый порт Shadowsocks (TCP): "; [[ "$v" =~ ^[0-9]+$ ]] && proto_set PROTO_SS_PORT "$v" ;;
            3) ask v "  Новый порт TUIC (UDP): "; [[ "$v" =~ ^[0-9]+$ ]] && proto_set PROTO_TUIC_PORT "$v" ;;
            4)
                echo "  Варианты: 2022-blake3-aes-128-gcm (быстрее) / 2022-blake3-aes-256-gcm"
                ask v "  Шифр: "
                case "$v" in 2022-blake3-aes-128-gcm|2022-blake3-aes-256-gcm) proto_set PROTO_SS_METHOD "$v" ;; *) echo "  ❌ Неизвестный шифр"; sleep 1 ;; esac
                ;;
            5) ask v "  REALITY dest (host:443, реальный TLS1.3-сайт): "; [ -n "$v" ] && proto_set PROTO_REALITY_DEST "$v" ;;
            6) ask v "  REALITY SNI (обычно host из dest): "; [ -n "$v" ] && proto_set PROTO_REALITY_SNI "$v" ;;
            7) ask v "  Путь XHTTP (например /dl): "; [ -n "$v" ] && proto_set PROTO_XHTTP_PATH "$v" ;;
            8) ask v "  Новый порт Trojan (TCP): "; [[ "$v" =~ ^[0-9]+$ ]] && proto_set PROTO_TROJAN_PORT "$v" ;;
            9) ask v "  Путь WS Trojan (например /ws): "; [ -n "$v" ] && proto_set PROTO_TROJAN_WS_PATH "$v" ;;
            0) return ;;
            *) echo "  ❌ Неверный выбор!"; sleep 1 ;;
        esac
    done
}

# Диагностика доп. протоколов.
# Состояние протоколов на всех нодах кластера (данные с пиров — из кэша
# синхронизации, см. lib/cluster.sh и docs/guide/CLUSTER-PROTOCOLS.md).
proto_cluster_screen() {
    clear
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🌐 Протоколы по нодам кластера"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  💚 работает · 🔴 включён, но не слушает · ⚪ выключен"
    echo ""
    local data
    data=$(cluster_protocols 2>/dev/null)
    if [ -z "$data" ]; then
        echo "  Данных нет: кластер не настроен."
    else
        printf '%s\n' "$data" | awk -F'|' '
            { st = ($3 != 1) ? "⚪" : ($4 == 1 ? "💚" : "🔴")
              line[$1] = line[$1] sprintf("%s %s %s/%s   ", toupper($2), st, toupper($6), $5)
              age[$1] = $7
              if (!($1 in seen)) { seen[$1] = 1; order[++n] = $1 } }
            END {
              for (i = 1; i <= n; i++) {
                node = order[i]
                a = age[node] + 0
                fresh = (a == 0) ? "сейчас" : (a < 90 ? a " с назад" : int(a/60) " мин назад")
                printf "  🖥  %s   (данные: %s)\n     %s\n\n", node, fresh, line[node]
              } }'
        echo "  ⚠️  Состояние ЛОКАЛЬНОЕ: 💚 значит «порт слушается на самой ноде»."
        echo "     Снаружи он всё ещё может быть закрыт файрволом или не проброшен"
        echo "     фронтом/релеем — это видно только проверкой с клиента."
    fi
    echo ""
    pause
}

proto_diagnose_menu() {
    clear
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🔍 Диагностика протоколов"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Xray бинарник : $( [ -x "$XRAY_BIN" ] && "$XRAY_BIN" version 2>/dev/null | head -1 || echo 'не установлен' )"
    echo "  sing-box      : $( [ -x "$SINGBOX_BIN" ] && "$SINGBOX_BIN" version 2>/dev/null | head -1 || echo 'не установлен' )"
    echo "  Сервис Xray   : $(_proto_svc_state "$XRAY_SERVICE")"
    echo "  Сервис sing-box: $(_proto_svc_state "$SINGBOX_SERVICE")"
    echo ""
    echo "  REALITY pubkey: $(proto_reality_pubkey | cut -c1-20)…  shortId: $(proto_reality_shortid)"
    echo ""
    echo "  Прослушиваемые порты:"
    local p
    for p in $(proto_vless_port) $(proto_ss_port) $(proto_trojan_port); do
        proto_xray_needed || break
        if ss -ltn 2>/dev/null | grep -q ":$p "; then echo "    TCP $p : 💚 слушается"; else echo "    TCP $p : 🔴 нет"; fi
    done
    if proto_tuic_enabled; then
        p=$(proto_tuic_port)
        if ss -lun 2>/dev/null | grep -q ":$p "; then echo "    UDP $p : 💚 слушается"; else echo "    UDP $p : 🔴 нет"; fi
    fi
    echo ""
    echo "  Логи сервисов: journalctl -u $XRAY_SERVICE -e   |   journalctl -u $SINGBOX_SERVICE -e"
    pause
}
