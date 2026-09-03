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
        local vs vx ss ts tj
        proto_vless_enabled  && vs="💚 вкл" || vs="⚪ выкл"
        proto_vlessx_enabled && vx="💚 вкл" || vx="⚪ выкл"
        proto_ss_enabled     && ss="💚 вкл" || ss="⚪ выкл"
        proto_tuic_enabled   && ts="💚 вкл" || ts="⚪ выкл"
        proto_trojan_enabled && tj="💚 вкл" || tj="⚪ выкл"
        echo "  1. VLESS + REALITY (TCP+Vision): $vs   (TCP $(proto_vless_port))"
        echo "  2. Shadowsocks-2022            : $ss   (TCP $(proto_ss_port), $(proto_ss_method))"
        echo "  3. TUIC v5                     : $ts   (UDP $(proto_tuic_port))"
        echo "  4. Trojan / WebSocket + TLS    : $tj   (TCP $(proto_trojan_port))"
        echo "  5. VLESS + REALITY + XHTTP     : $vx   (TCP $(proto_vlessx_port))  — резерв к п.1"
        echo ""
        echo "  Сервисы: Xray $(_proto_svc_state "$XRAY_SERVICE") · sing-box $(_proto_svc_state "$SINGBOX_SERVICE")"
        echo ""
        echo "  6. ⚙  Параметры (порты, шифр SS, REALITY dest/SNI, пути XHTTP/WS)"
        echo "  7. 🔁 Переустановить/пересобрать сервисы (bootstrap)"
        echo "  8. 🔍 Диагностика (версии бинарников, статус, порты)"
        echo "  9. 🌐 Протоколы по нодам кластера"
        echo "  0. ↩  Назад"
        echo ""
        local choice
        ask choice "  Выберите: "
        case "$choice" in
            1) _proto_toggle vless  "VLESS+REALITY (TCP+Vision)" ;;
            2) _proto_toggle ss     "Shadowsocks-2022" ;;
            3) _proto_toggle tuic   "TUIC v5" ;;
            4) _proto_toggle trojan "Trojan/WS" ;;
            5) _proto_toggle vlessx "VLESS+REALITY+XHTTP" ;;
            6) proto_params_menu ;;
            7)
                echo ""
                if ! proto_any_enabled; then
                    echo "  Нет включённых протоколов — включать нечего."
                else
                    echo "  ⏳ Установка бинарников и пересборка конфигов..."
                    proto_bootstrap && echo "  ✅ Готово" || echo "  ⚠️  Были ошибки — см. вывод выше"
                fi
                pause
                ;;
            8) proto_diagnose_menu ;;
            9) proto_cluster_screen ;;
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
        vlessx) proto_vlessx_enabled && enabled=1 ;;
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

# Все настраиваемые параметры протоколов ОДНОЙ таблицей.
# Поля: ключ | функция-геттер | подпись | тип | подсказка
# Тип задаёт и проверку ввода, и текст приглашения:
#   port          — 1..65535
#   hostport      — «хост:порт» (REALITY dest)
#   domain        — имя хоста
#   path          — путь, обязан начинаться с «/»
#   choice:a,b,c  — одно из перечисленного
#   text          — что угодно непустое
#
# Раньше это был список из десяти `echo` и такого же `case`, где номера
# приходилось держать в голове в двух местах: добавление одного параметра уже
# заставило вклинить пункт «a», потому что цифры кончились. Теперь новый
# параметр — ОДНА строка здесь, и он сразу и показывается, и правится, и
# проверяется.
_proto_params_table() {
    cat <<'TBL'
PROTO_VLESS_PORT|proto_vless_port|VLESS TCP+Vision — порт|port|443/80 заняты Caddy
PROTO_VLESS_FP|proto_vless_fp|VLESS TCP — отпечаток ClientHello|choice:chrome,firefox,safari,ios,edge,random,randomized|маскировка под браузер (uTLS)
PROTO_VLESSX_PORT|proto_vlessx_port|VLESS XHTTP (резерв) — порт|port|свой порт, рядом с основным
PROTO_VLESSX_FP|proto_vlessx_fp|VLESS XHTTP — отпечаток ClientHello|choice:chrome,firefox,safari,ios,edge,random,randomized|XHTTP похож на HTTP/2, chrome частотнее
PROTO_XHTTP_PATH|proto_xhttp_path|XHTTP — путь|path|например /dl
PROTO_XHTTP_MODE|proto_xhttp_mode|XHTTP — режим в ссылке|choice:stream-one,stream-up,packet-up,auto|stream-one: без отдельного стрима выгрузки
PROTO_REALITY_DEST|proto_reality_dest|REALITY — dest (куда ходит сам сервер)|hostport|ОБЯЗАТЕЛЬНО с портом; штатно 127.0.0.1:443
PROTO_REALITY_SNI|proto_reality_sni|REALITY — SNI (имя в ключе клиента)|domain|A-запись обязана вести на ЭТУ ноду
PROTO_SPX|proto_spx|REALITY — spiderX|path|дефолт /, меняют редко
PROTO_TROJAN_PORT|proto_trojan_port|Trojan/WS — порт|port|
PROTO_TROJAN_WS_PATH|proto_trojan_ws_path|Trojan/WS — путь|path|например /ws
PROTO_SS_PORT|proto_ss_port|Shadowsocks-2022 — порт|port|
PROTO_SS_METHOD|proto_ss_method|Shadowsocks-2022 — шифр|choice:2022-blake3-aes-128-gcm,2022-blake3-aes-256-gcm|128 быстрее
PROTO_TUIC_PORT|proto_tuic_port|TUIC v5 — порт (UDP)|port|
PROTO_TUIC_CC|proto_tuic_cc|TUIC — контроль перегрузки|choice:bbr,cubic,new_reno|на потерях обычно bbr
PROTO_TUIC_URM|proto_tuic_urm|TUIC — режим UDP|choice:native,quic|
PROTO_TUIC_ALPN|proto_tuic_alpn|TUIC — ALPN|text|обычно h3
TBL
}

# Проверка значения по типу. Печатает причину отказа, возвращает 1.
_proto_param_valid() {   # тип значение
    case "$1" in
        port)
            [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" -ge 1 ] && [ "$2" -le 65535 ] && return 0
            echo "  ❌ Порт — число 1..65535." ;;
        hostport)
            # Отсутствие порта — самая частая и самая незаметная ошибка: REALITY
            # молча не сможет дозвониться до dest и будет рвать КАЖДОЕ соединение,
            # причём порт при этом слушается и выглядит живым.
            [[ "$2" =~ ^[A-Za-z0-9._-]+:[0-9]+$ ]] && return 0
            echo "  ❌ Нужен «хост:порт», например 127.0.0.1:443. Без порта REALITY не дозвонится." ;;
        domain)
            [[ "$2" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$ ]] && return 0
            echo "  ❌ Похоже, это не имя хоста." ;;
        path)
            [ "${2:0:1}" = "/" ] && return 0
            echo "  ❌ Путь начинается со «/»." ;;
        choice:*)
            # Разбор по ЗАПЯТОЙ, а не словами: варианты хранятся как в таблице,
            # чтобы список в подсказке и список в проверке были одной строкой.
            local o; local -a opts; IFS=',' read -ra opts <<< "${1#choice:}"
            for o in "${opts[@]}"; do [ "$o" = "$2" ] && return 0; done
            echo "  ❌ Допустимо: ${1#choice:}" ;;
        *) [ -n "$2" ] && return 0; echo "  ❌ Пустое значение." ;;
    esac
    return 1
}

# Параметры протоколов. Всё, что влияет на связь, — здесь и в одном месте.
proto_params_menu() {
    local -a keys getters labels types hints
    local line k g l t h i n
    while IFS='|' read -r k g l t h; do
        [ -n "$k" ] || continue
        keys+=("$k"); getters+=("$g"); labels+=("$l"); types+=("$t"); hints+=("$h")
    done < <(_proto_params_table)
    n=${#keys[@]}

    while true; do
        clear
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  ⚙  Параметры протоколов"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        for (( i=0; i<n; i++ )); do
            printf "  %2d. %-38s : %s\n" "$((i+1))" "${labels[i]}" "$(${getters[i]})"
        done
        echo ""
        echo "  ── Только для чтения (генерятся при установке) ──"
        echo "     REALITY pbk : $(proto_reality_pubkey | cut -c1-24)…"
        echo "     REALITY sid : $(proto_reality_shortid)"
        echo ""
        echo "  ⚠️  После смены параметров пересоберите сервисы (Протоколы → 7),"
        echo "     иначе конфиг ноды и ключи в подписке разъедутся."
        echo "  d. 🔍 Проверить связность прямо сейчас"
        echo "  0. ↩  Назад"
        echo ""
        local c v
        ask c "  Что изменить: "
        case "$c" in
            0) return ;;
            d|D) proto_selftest_screen ;;
            *)
                [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le "$n" ] || {
                    echo "  ❌ Неверный выбор!"; sleep 1; continue; }
                i=$((c-1))
                echo ""
                echo "  ${labels[i]}"
                [ -n "${hints[i]}" ] && echo "  ${hints[i]}"
                case "${types[i]}" in
                    choice:*) echo "  Варианты: ${types[i]#choice:}" ;;
                esac
                echo "  Сейчас: $(${getters[i]})   (пусто — оставить как есть)"
                ask v "  Новое значение: "
                [ -n "$v" ] || continue
                _proto_param_valid "${types[i]}" "$v" || { sleep 2; continue; }
                proto_set "${keys[i]}" "$v"
                # SNI отдельно: неверная A-запись стоит бана всего адреса (P-129),
                # и узнать об этом надо сразу, а не из жалоб клиентов.
                [ "${keys[i]}" = "PROTO_REALITY_SNI" ] && { proto_reality_sni_check "$v" || sleep 3; }
                echo "  ✅ Сохранено. Не забудьте пересобрать сервисы."
                sleep 1
                ;;
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

# Экран самопроверки: своя нода подробно + соседи снаружи одной пробой.
proto_selftest_screen() {
    clear
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🔍 Проверка связности протоколов"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  💚 работает · ⚠️ подозрительно · ❌ сломано"
    echo ""
    echo "  ── Эта нода ──"
    proto_selftest | while IFS=$'\t' read -r icon what verdict; do
        printf "  %s %-22s %s\n" "$icon" "$what" "$verdict"
    done
    if declare -F cluster_peers >/dev/null 2>&1 && [ -n "$(cluster_peers)" ]; then
        echo ""
        echo "  ── Соседи (проба снаружи, их файлы нам недоступны) ──"
        local h
        while read -r h; do
            [ -n "$h" ] || continue
            proto_selftest_peer "$h" | while IFS=$'\t' read -r icon what verdict; do
                printf "  %s %-30s %s\n" "$icon" "$what" "$verdict"
            done
        done < <(cluster_peers)
    fi
    echo ""
    echo "  Подсказка: «TCP принят, TLS-ответа нет» — это почти всегда REALITY dest."
    echo "  Штатное значение dest — 127.0.0.1:443 (свой же Caddy), SNI — домен ноды."
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
    for p in $(proto_vless_port) $(proto_vlessx_port) $(proto_ss_port) $(proto_trojan_port); do
        proto_xray_needed || break
        if ss -ltn 2>/dev/null | grep -q ":$p "; then echo "    TCP $p : 💚 слушается"; else echo "    TCP $p : 🔴 нет"; fi
    done
    if proto_tuic_enabled; then
        p=$(proto_tuic_port)
        if ss -lun 2>/dev/null | grep -q ":$p "; then echo "    UDP $p : 💚 слушается"; else echo "    UDP $p : 🔴 нет"; fi
    fi
    echo ""
    echo ""
    echo "  ── Связность ──"
    proto_selftest | while IFS=$'\t' read -r icon what verdict; do
        printf "  %s %-22s %s\n" "$icon" "$what" "$verdict"
    done
    echo ""
    echo "  Логи сервисов: journalctl -u $XRAY_SERVICE -e   |   journalctl -u $SINGBOX_SERVICE -e"
    pause
}
