#!/bin/bash
# ================================================
# Интерфейс: таблицы, меню пользователей, ссылки
# ================================================

declare -a USER_LIST_ARRAY
USER_LIST_PAGES=1
USER_LIST_TOTAL=0

# ====================== СНИМОК СТАТИСТИКИ ДЛЯ СПИСКА ======================
# Раньше таблица на КАЖДУЮ перерисовку (раз в 2с) для КАЖДОГО юзера дёргала
# jq/awk/grep по многу раз (online, трафик, скорость, суммы по пирам, IP, срок),
# плюс _peer_stat_sum гонял awk по всем файлам пиров на каждого юзера и каждую
# колонку. При 15 юзерах это сотни процессов на кадр — отсюда «подвисания».
# build_user_stats_snapshot читает каждый источник РОВНО ОДИН раз в ассоциативные
# массивы; рендер берёт готовые значения без новых процессов.
declare -gA SNAP_ON SNAP_DIS SNAP_LTX SNAP_LRX SNAP_LSTX SNAP_LSRX
declare -gA PEER_ON PEER_TX PEER_RX PEER_STX PEER_SRX
declare -gA SNAP_IPC SNAP_EXP SNAP_DEV SNAP_HC
declare -g SNAP_POOL SNAP_NODE

build_user_stats_snapshot() {
    SNAP_ON=();  SNAP_DIS=(); SNAP_LTX=(); SNAP_LRX=(); SNAP_LSTX=(); SNAP_LSRX=()
    PEER_ON=();  PEER_TX=();  PEER_RX=();  PEER_STX=(); PEER_SRX=()
    SNAP_IPC=(); SNAP_EXP=(); SNAP_DEV=(); SNAP_HC=()
    local u a b c d e cnt

    # Персональные лимиты устройств + глобальные лимиты (для символа ⚠️ и карточки).
    while IFS='|' read -r u a b; do [ -n "$u" ] && { SNAP_DEV["$u"]=$a; SNAP_HC["$u"]=$b; }; done < "$USERLIMITS_FILE" 2>/dev/null
    SNAP_POOL=$(get_device_limit); SNAP_NODE=$(get_node_limit)

    # Онлайн — один проход jq по кэшу /online.
    while IFS=$'\t' read -r u a; do
        [ -n "$u" ] && SNAP_ON["$u"]="$a"
    done < <(printf '%s' "${CACHED_ONLINE:-{}}" | jq -r 'to_entries[]|"\(.key)\t\(.value)"' 2>/dev/null)

    # Отключённые.
    while IFS='|' read -r u _; do [ -n "$u" ] && SNAP_DIS["$u"]=1; done < "$DISABLED_FILE"
    # Локальные трафик и скорость.
    while IFS='|' read -r u a b; do [ -n "$u" ] && { SNAP_LTX["$u"]=$a; SNAP_LRX["$u"]=$b; }; done < "$STATS_FILE"
    while IFS='|' read -r u a b; do [ -n "$u" ] && { SNAP_LSTX["$u"]=$a; SNAP_LSRX["$u"]=$b; }; done < "$SPEED_FILE"
    # Срок действия.
    while IFS='|' read -r u a; do [ -n "$u" ] && SNAP_EXP["$u"]=$a; done < "$EXPIRY_FILE"

    # Суммы по пирам — ОДИН awk на все *.stats (а не на каждого юзера × колонку).
    if [ -d "$PEERS_DIR" ] && compgen -G "$PEERS_DIR/*.stats" >/dev/null 2>&1; then
        while IFS=$'\t' read -r u a b c d e; do
            [ -n "$u" ] || continue
            PEER_ON["$u"]=$a; PEER_TX["$u"]=$b; PEER_RX["$u"]=$c; PEER_STX["$u"]=$d; PEER_SRX["$u"]=$e
        done < <(awk -F'\t' '{on[$1]+=$2; tx[$1]+=$3; rx[$1]+=$4; stx[$1]+=$5; srx[$1]+=$6}
                             END{for(k in on) printf "%s\t%s\t%s\t%s\t%s\t%s\n",k,on[k],tx[k],rx[k],stx[k],srx[k]}' \
                             "$PEERS_DIR"/*.stats 2>/dev/null)
    fi

    # Уникальные IP по кластеру (локально + кэши пиров) — один проход awk.
    while read -r cnt u; do [ -n "$u" ] && SNAP_IPC["$u"]=$cnt; done < <(
        { cut -d'|' -f1,2 "$IPS_FILE" 2>/dev/null
          [ -d "$PEERS_DIR" ] && compgen -G "$PEERS_DIR/*.ips" >/dev/null 2>&1 && cut -d'|' -f1,2 "$PEERS_DIR"/*.ips 2>/dev/null; } \
        | awk -F'|' 'NF>=2 && $1!="" && !seen[$1"|"$2]++{cnt[$1]++} END{for(k in cnt) print cnt[k], k}'
    )
}

# Аксессоры снимка (без процессов). Кластерные = локальные + суммы по пирам.
snap_disabled() { [ -n "${SNAP_DIS[$1]:-}" ]; }
snap_online()   { echo "${SNAP_ON[$1]:-0}"; }
snap_conn()     { echo $(( ${SNAP_ON[$1]:-0}   + ${PEER_ON[$1]:-0} )); }
snap_tx()       { echo $(( ${SNAP_LTX[$1]:-0}  + ${PEER_TX[$1]:-0} )); }
snap_rx()       { echo $(( ${SNAP_LRX[$1]:-0}  + ${PEER_RX[$1]:-0} )); }
snap_stx()      { echo $(( ${SNAP_LSTX[$1]:-0} + ${PEER_STX[$1]:-0} )); }
snap_srx()      { echo $(( ${SNAP_LSRX[$1]:-0} + ${PEER_SRX[$1]:-0} )); }

# Эффективные лимиты из снимка (только builtins, без внешних процессов).
snap_devices()  { local d=${SNAP_DEV[$1]:-1}; [[ "$d" =~ ^[0-9]+$ ]] && echo "$d" || echo 1; }
snap_pool_cap() { local d; d=$(snap_devices "$1"); if [ "$d" -gt 0 ]; then echo "$d"; else echo "${SNAP_POOL:-0}"; fi; }
snap_node_cap() {
    local nl=${SNAP_NODE:-0} pc; pc=$(snap_pool_cap "$1")
    [[ "$nl" =~ ^[0-9]+$ ]] || nl=0
    if [ "$nl" -le 0 ]; then echo "$pc"; elif [ "$pc" -le 0 ]; then echo "$nl"
    elif [ "$nl" -lt "$pc" ]; then echo "$nl"; else echo "$pc"; fi
}
# Превышен ли лимит: cluster_conn > pool_cap ИЛИ local_conn > node_cap.
snap_over_limit() {   # user cluster_conn local_conn
    local pc nc; pc=$(snap_pool_cap "$1"); nc=$(snap_node_cap "$1")
    { [ "$pc" -gt 0 ] && [ "${2:-0}" -gt "$pc" ]; } 2>/dev/null && return 0
    { [ "$nc" -gt 0 ] && [ "${3:-0}" -gt "$nc" ]; } 2>/dev/null && return 0
    return 1
}

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
    build_user_stats_snapshot          # один раз готовим данные для всей таблицы
    local sorted
    sorted=$(
        get_all_users | while IFS= read -r u; do
            [ -z "$u" ] && continue
            local key
            # Сортировка по кластерному онлайну (юзер может быть онлайн на пире).
            if snap_disabled "$u"; then
                key=2
            elif [ "$(snap_conn "$u")" -gt 0 ] 2>/dev/null; then
                key=0
            else
                key=1
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
    local _sub=0; sub_enabled && _sub=1
    printf '  '
    print_cell "No"       3  0 r; printf ' '
    print_cell "Имя"      14 0;   printf ' '
    print_cell "Статус"   9  0;   printf ' '
    [ "$_sub" = 1 ] && { print_cell "Кластер" 9 0; printf ' '; }
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

        # Все значения — из снимка (build_user_stats_snapshot), без новых процессов.
        # Превышение лимита подключений заменяет символ онлайна на ⚠️.
        local oc cc over=0
        oc=$(snap_online "$user")
        cc=$(snap_conn "$user")
        if ! snap_disabled "$user" && snap_over_limit "$user" "$cc" "$oc"; then over=1; fi

        if snap_disabled "$user"; then
            status="🔴 ВЫКЛ"; status_wide=1
        elif [ "$over" = 1 ]; then
            status="⚑ ON(${oc})"; status_wide=0   # ⚠️ = база+VS16: ${#} уже учитывает ширину
        elif [ "${oc:-0}" -gt 0 ] 2>/dev/null; then
            status="💚 ON(${oc})"; status_wide=1
        else
            status="⚫ OFF"; status_wide=1
        fi

        # Кластерный статус + суммарные трафик/скорость (если подписка включена).
        local cstatus cstatus_wide tx rx sp_tx sp_rx
        if [ "$_sub" = 1 ]; then
            if [ "$over" = 1 ]; then
                cstatus="⚑ ${cc}"; cstatus_wide=0   # ⚠️ = база+VS16: ширина уже учтена
            elif [ "${cc:-0}" -gt 0 ] 2>/dev/null; then
                cstatus="💚 ${cc}"; cstatus_wide=1
            else
                cstatus="⚫ —"; cstatus_wide=1
            fi
            tx=$(snap_tx "$user"); rx=$(snap_rx "$user")
            sp_tx=$(snap_stx "$user"); sp_rx=$(snap_srx "$user")
        else
            tx=${SNAP_LTX[$user]:-0};  rx=${SNAP_LRX[$user]:-0}
            sp_tx=${SNAP_LSTX[$user]:-0}; sp_rx=${SNAP_LSRX[$user]:-0}
        fi

        local traffic speed
        traffic="↑$(format_bytes "$tx") ↓$(format_bytes "$rx")"
        if [ "${sp_tx:-0}" -eq 0 ] && [ "${sp_rx:-0}" -eq 0 ] 2>/dev/null; then
            speed="—"
        else
            speed="↑$(format_speed_short "$sp_tx") ↓$(format_speed_short "$sp_rx")"
        fi

        local ipc exp
        ipc=${SNAP_IPC[$user]:-0}
        exp=$(expiry_cell "${SNAP_EXP[$user]:-}")

        printf '  '
        print_cell "$num"     3  0 r;           printf ' '
        print_cell "$(trunc "$user" 14)" 14 0;  printf ' '
        print_cell "$status"  9  "$status_wide"; printf ' '
        [ "$_sub" = 1 ] && { print_cell "$cstatus" 9 "$cstatus_wide"; printf ' '; }
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
            13)
                cluster_sync_now
                pause
                need_clear=1
                ;;
            0) return ;;
        esac
    done
}

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
                api_post "/kick" "[\"$user\"]" &>/dev/null
                echo "  ✅ Сессии $user на этой ноде сброшены (кик)."
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
                        echo "     Синхронизируется по всему кластеру как атрибут подписки."
                    else
                        echo "  ✅ Тариф снят — действует глобальный лимит."
                    fi
                    write_authlimits; sub_enabled && { publish_cluster_userlimits; offer_sync; }
                else echo "  ❌ Нужно число (Мбит/с)."; fi
                pause ;;
            0) return ;;
            *) echo "  ❌ Неверный выбор."; sleep 1 ;;
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
        tl=$(get_user_traffic "$user"); tx=$(echo "$tl" | cut -d'|' -f2); rx=$(echo "$tl" | cut -d'|' -f3)
        echo "  Трафик:        ↑$(format_bytes "$tx") / ↓$(format_bytes "$rx")"
        local sp sp_tx sp_rx
        sp=$(get_user_speed "$user"); sp_tx=$(echo "$sp" | cut -d'|' -f2); sp_rx=$(echo "$sp" | cut -d'|' -f3)
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
    if sub_enabled; then
        echo "  9. 🌐 Ссылка-подписка (все серверы кластера)"
        if roster_has "$user"; then
            echo " 10. 🔄 Синхронизировать на все ноды (уже кластерный ✓)"
        else
            echo " 10. 🔄 Завести на всех нодах кластера"
        fi
        echo " 11. 🩺 Диагностика профиля (по кластеру)"
    fi
    echo " 12. 🔢 Устройства и ссылки подписки"
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

# ====================== НАСТРОЙКИ ======================

# ====================== ПРОИЗВОДИТЕЛЬНОСТЬ / ЛИМИТ СКОРОСТИ ======================
# Двухуровневый лимит скорости на клиента + защита слабого сервера. См. lib/perf.sh:
#   уровень 1 — bandwidth в config.yaml (для Brutal-клиентов, нужен рестарт);
#   уровень 2 — kernel-лимит на IP клиента (для ВСЕХ, сразу): tc-ШЕЙПИНГ без потерь
#              пакетов (fallback — дроп nft/iptables, если нет tc).
# Параметры зависят от железа ноды и по кластеру НЕ синхронизируются.

# Задать лимит (общая часть для пунктов меню): пишет конфиг + kernel-правила.
_perf_set_limit() {   # down_mbit up_mbit -> 0 если что-то применилось
    local d="$1" u="$2" ok=0
    local sup="" sdn=""
    [ "$d" -gt 0 ] 2>/dev/null && sup="${d} mbps"    # up сервера = скачивание клиента
    [ "$u" -gt 0 ] 2>/dev/null && sdn="${u} mbps"    # down сервера = отдача клиента
    if set_bandwidth "$sup" "$sdn"; then
        ok=1
        if [ -n "$sup" ] || [ -n "$sdn" ]; then
            echo "  ✅ Конфиг Hysteria: лимит ↓ ${sup:-∞} · ↑ ${sdn:-∞}, режим Brutal (после перезапуска)."
        else
            echo "  ✅ Конфиг Hysteria: лимит снят (после перезапуска)."
        fi
    else
        echo "  ❌ Ошибка записи config.yaml — откат из бэкапа (лимит в конфиге не изменён)."
    fi
    klimit_apply "$d" "$u"; local krc=$?
    if [ "$d" -eq 0 ] && [ "$u" -eq 0 ]; then
        echo "  ✅ Kernel-лимит снят."
        ok=1
    elif [ "$krc" -eq 0 ]; then
        echo "  ✅ Kernel-лимит АКТИВЕН ПРЯМО СЕЙЧАС: ↓ ${d} · ↑ ${u} Мбит/с на IP клиента."
        echo "     Реальный потолок для всех клиентов (включая BBR), шейпинг БЕЗ потери пакетов"
        echo "     (tc HTB+fq_codel), + автозагрузка после ребута."
        ok=1
    elif [ "$krc" -eq 2 ]; then
        echo "  ⚠️  В системе нет ни tc, ни nft, ни iptables — kernel-потолок поставить нечем."
        echo "     Работает только лимит уровня Hysteria (для клиентов с Brutal)."
    else
        echo "  ⚠️  Не удалось загрузить kernel-правила — journalctl -u hy2-limit -e"
    fi
    [ "$ok" = 1 ]
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
        echo "  Лимит НА КЛИЕНТА (два уровня, задаются вместе пунктом 1):"
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
            echo "   • Hysteria (Brutal):     💚 ↓ ${bu:-∞} · ↑ ${bd:-∞}"
        else
            echo "   • Hysteria (Brutal):     ⚪ не задан"
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
        echo "  1. 🚦 Задать лимит скорости на клиента (kernel + Hysteria)"
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
        echo "  8. ⬆  Обновить менеджер (до последней версии с GitHub)"
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
                echo "  Обновление скачает свежие файлы менеджера с GitHub и заменит текущие."
                echo "  Hysteria, пользователи и настройки НЕ трогаются (режим «только менеджер»)."
                local confirm
                ask confirm "  Обновить сейчас? (да/нет): "
                if is_yes "$confirm"; then
                    local up_tmp
                    up_tmp=$(mktemp)
                    if curl -fsSL --max-time 30 "https://raw.githubusercontent.com/CABi-Code/Hysteria2-manager/main/install.sh" -o "$up_tmp"; then
                        echo "  ⏳ Запускаю установщик (выберите пункт 1 — обновить только менеджер)..."
                        # stderr менеджера уходит в лог-файл — вернём его на терминал,
                        # чтобы сообщения установщика были видны. exec заменяет процесс.
                        exec 2>/dev/tty
                        exec bash "$up_tmp"
                    else
                        rm -f "$up_tmp"
                        echo "  ❌ Не удалось скачать install.sh (проверьте сеть)."
                    fi
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
            caddy_st="💚 работает$(systemctl is-enabled --quiet caddy 2>/dev/null && echo ', автозапуск вкл')"
        else
            caddy_st="🔴 остановлен"
        fi

        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  🌐 Подписка / Кластер"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        if sub_enabled; then
            echo "  Состояние : 💚 включена"
            echo "  Нода      : $(node_name)  ($host)"
            # Живой статус сертификата — подтверждает, что домен реально привязан.
            if cert_ready "$host"; then
                cert_st="💚 валиден до $(cert_expiry "$host") (автопродление)"
            else
                cert_st="🔴 не подтверждён (HTTPS не работает — см. пункт 1)"
            fi
            echo "  Сертификат: $cert_st"
            local conn; conn=$(node_get CONN_HOST)
            if [ -n "$conn" ]; then
                echo "  В ссылке  : домен подключения $conn (вместо IP)"
            else
                echo "  В ссылке  : IP ноды $(node_ip) (домен не задан — пункт 9)"
            fi
        else
            echo "  Состояние : ⚪ не настроена"
        fi
        echo "  Caddy     : $caddy_st"
        echo "  Нод в кластере: $(grep -c '^' "$CLUSTER_CONF" 2>/dev/null | tr -dc '0-9' || echo 0)"
        local dlim nlim; dlim=$(get_device_limit); nlim=$(get_node_limit)
        echo "  Глоб. лимит на пул (кластер): $([ "$dlim" -gt 0 ] 2>/dev/null && echo "$dlim" || echo "∞ (выкл)")"
        echo "  Глоб. лимит на ноду         : $([ "$nlim" -gt 0 ] 2>/dev/null && echo "$nlim" || echo "∞ (выкл)")"
        echo ""
        echo "  1. 🌐 Настроить домен и включить подписку"
        echo "  2. 🔗 Создать кластер (получить join-токен)"
        echo "  3. 🔌 Подключиться к кластеру по токену"
        echo "  4. ➕ Добавить пир вручную (домен ноды)"
        echo "  5. 📋 Ноды кластера (просмотр и удаление)"
        echo "  6. 🔄 Получить синхронизацию (локально)"
        echo "  7. 🔢 Глобальные лимиты (пул + нода, синхронно)"
        echo "  8. 🩺 Диагностика подписки"
        echo "  9. 🛡  Домен подключения в ссылке (скрыть голый IP)"
        echo " 10. 🛰  Релей (реально спрятать IP ноды через фронт-VPS)"
        echo " 11. 🔢 Выбрать IP ноды (если у сервера несколько IP)"
        echo " 12. 🎨 Оформление подписки (название, метки серверов)"
        local _sm; _sm=$(node_get SYNC_MODE); [ -z "$_sm" ] && _sm=ask
        echo " 13. ⚙  Режим синхронизации после изменений (сейчас: $_sm)"
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
                local _locals; _locals=$(list_local_ips | tr '\n' ' ')
                if [ "$rc" -eq 0 ]; then
                    echo "  ✅ DNS: $domain → $(resolve_domain "$domain" | tr '\n' ' ')(этот сервер)"
                elif [ "$rc" -eq 2 ]; then
                    echo "  ❌ Домен $domain не резолвится."
                    echo "     Создайте A-запись $domain → один из IP: ${_locals}"
                    local c; ask c "  Всё равно продолжить (сертификат пока не выпустится)? (да/нет): "
                    is_yes "$c" || { echo "  Отменено."; pause; continue; }
                else
                    echo "  ⚠️  $domain резолвится НЕ на этот сервер."
                    echo "     Адрес(а) домена: $(resolve_domain "$domain" | tr '\n' ' ')"
                    echo "     Локальные IP сервера: ${_locals}"
                    echo "     Let's Encrypt не выдаст сертификат, пока A-запись не указывает на один из них."
                    local c; ask c "  Всё равно продолжить? (да/нет): "
                    is_yes "$c" || { echo "  Отменено."; pause; continue; }
                fi
                ask name "  Имя ноды (метка в клиенте, Enter — $(hostname -s 2>/dev/null || echo node)): "
                [ -z "$name" ] && name=$(hostname -s 2>/dev/null || echo node)
                echo "  ⏳ Открываю порты 80/443 в firewall (если активен)..."
                ensure_ports_open
                echo "  ⏳ Проверяю/устанавливаю Caddy..."
                if ! ensure_caddy; then
                    echo "  ❌ Не удалось установить Caddy. Установите вручную и повторите."
                    pause; continue
                fi
                node_configure "$domain" "$name"
                cluster_add_peer "$name" "$domain"
                echo "  ⏳ Настраиваю Caddy..."
                if ! setup_caddy "$domain"; then
                    echo "  ❌ Caddy не запустился с новым конфигом (откатил)."
                    echo "     Диагностика: journalctl -u caddy -e | tail -n 30"
                    pause; continue
                fi
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
                    cluster_sync_now
                    echo "  ✅ Пир $phost добавлен."
                fi
                pause
                ;;
            5)
                while true; do
                    clear
                    echo "  📋 Ноды кластера"
                    echo "  Эта нода: «$(node_name)»  ($(node_host))"
                    echo "  ──────────────────────────────────────────────────────"
                    local -a node_hosts=() node_names=()
                    local i=0 st self
                    self=$(node_host)
                    if [ -s "$CLUSTER_CONF" ]; then
                        while IFS='|' read -r pn ph; do
                            [ -n "$ph" ] || continue
                            i=$((i+1)); node_names[$i]="$pn"; node_hosts[$i]="$ph"
                            if [ "$ph" = "$self" ]; then
                                st="(эта нода)"
                            elif cluster_call "$ph" "/cluster/manifest" >/dev/null 2>&1; then
                                st="💚 на связи"
                            else
                                st="🔴 недоступна"
                            fi
                            printf "    %d. %-18s %-28s %s\n" "$i" "$pn" "$ph" "$st"
                        done < "$CLUSTER_CONF"
                    fi
                    [ "$i" -eq 0 ] && echo "    (пусто — кластер не настроен)"
                    echo ""
                    echo "    Номер — удалить ноду из реестра  |  0 — назад"
                    local sel
                    ask sel "  Выберите: "
                    [ "$sel" = "0" ] || [ -z "$sel" ] && break
                    if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "$i" ]; then
                        local dh="${node_hosts[$sel]}" dn="${node_names[$sel]}"
                        if [ "$dh" = "$self" ]; then
                            echo "  ❌ Нельзя удалить саму эту ноду здесь."; sleep 2; continue
                        fi
                        local c; ask c "  Удалить «$dn» ($dh) из реестра? (да/нет): "
                        if is_yes "$c"; then
                            cluster_remove_peer "$dh"
                            echo "  ✅ Удалено. ⚠️ Если пир ещё «живой» и есть в реестрах других нод —"
                            echo "     удалите его и там, иначе вернётся через gossip."
                            sleep 3
                        fi
                    else
                        echo "  ❌ Неверный номер."; sleep 1
                    fi
                done
                ;;
            6)
                cluster_sync_now
                pause
                ;;
            7)
                echo ""
                echo "  Глобальные лимиты подключений на ОДНУ подписку (общие для кластера,"
                echo "  синхронизируются автоматически). Персональное «кол-во устройств»"
                echo "  у юзера ПРИОРИТЕТНЕЕ этих значений."
                echo "    • Пул  — максимум одновременных подключений СУММАРНО по всем нодам."
                echo "    • Нода — максимум на ОДНУ ноду (страхует от багов синхронизации)."
                echo "  Пример: нода = 1, пул = 2. Лишние сессии отключаются (~1 мин)."
                echo ""
                echo "  Сейчас: пул $(get_device_limit) · нода $(get_node_limit)  (0 = без лимита)"
                local nlim nnode changed7=0
                ask nlim "  Лимит на пул (число, 0 — выкл, Enter — не менять): "
                if [ -n "$nlim" ]; then
                    if [[ "$nlim" =~ ^[0-9]+$ ]]; then set_device_limit "$nlim"; changed7=1
                    else echo "  ❌ Пул: нужно число — пропущено."; fi
                fi
                ask nnode "  Лимит на ноду (число, 0 — выкл, Enter — не менять): "
                if [ -n "$nnode" ]; then
                    if [[ "$nnode" =~ ^[0-9]+$ ]]; then set_node_limit "$nnode"; changed7=1
                    else echo "  ❌ Нода: нужно число — пропущено."; fi
                fi
                if [ "$changed7" = 1 ]; then
                    echo "  ✅ Лимиты: пул $(get_device_limit) · нода $(get_node_limit)."
                    publish_cluster_settings
                    [ -n "$(cluster_peers 2>/dev/null)" ] && cluster_sync_now
                    echo "     Применяются в течение ~1 мин (cron --online-sync) на каждой ноде."
                fi
                pause
                ;;
            8)
                clear
                subscription_diagnose
                # Если Caddy не поднялся из-за занятого порта — предлагаем освободить.
                if [ -n "$DIAG_CONFLICT_UNIT" ]; then
                    echo ""
                    echo "  Порт $DIAG_CONFLICT_PORT занимает сервис «$DIAG_CONFLICT_UNIT»."
                    local c
                    ask c "  Остановить его и запустить Caddy? (да/нет): "
                    if is_yes "$c"; then
                        systemctl stop "$DIAG_CONFLICT_UNIT" 2>/dev/null
                        ask c "  Отключить «$DIAG_CONFLICT_UNIT» из автозапуска (чтобы не вернулся после ребута)? (да/нет): "
                        is_yes "$c" && systemctl disable "$DIAG_CONFLICT_UNIT" 2>/dev/null
                        ensure_ports_open
                        setup_caddy >/dev/null 2>&1
                        sleep 2
                        if systemctl is-active --quiet caddy 2>/dev/null; then
                            echo "  ✅ Caddy запущен. Жду сертификат..."
                            if wait_cert "$(node_host)" 15; then
                                echo "  ✅ Сертификат выдан (до $(cert_expiry "$(node_host)")). Подписка работает."
                            else
                                echo "  ⚠️  Caddy поднялся, но сертификат пока не подтверждён — проверьте DNS/порт 80."
                            fi
                        else
                            echo "  ❌ Caddy всё ещё не запускается — journalctl -u caddy -e | tail -n 30"
                        fi
                    fi
                fi
                pause
                ;;
            9)
                echo ""
                local cur_conn; cur_conn=$(node_get CONN_HOST)
                [ -z "$cur_conn" ] && cur_conn="нет, используется IP $(get_ip)"
                echo "  Домен подключения подставляется в ссылку вместо голого IP"
                echo "  (host у hysteria2://...@host:port). Текущий: $cur_conn"
                echo ""
                echo "  ⚠️ ВАЖНО: домен должен быть DNS-only (A-запись прямо на IP ноды),"
                echo "     БЕЗ оранжевого облака Cloudflare — Hysteria работает по UDP,"
                echo "     а CF-прокси UDP не пропускает, и подключение сломается."
                echo ""
                local nd
                ask nd "  Домен подключения (Enter — оставить, '-' — убрать и вернуть IP): "
                if [ "$nd" = "-" ]; then
                    node_set CONN_HOST ""
                    sed -i '/^CONN_HOST=$/d' "$NODE_CONF" 2>/dev/null
                    echo "  ✅ Убрано — в ссылке снова IP $(get_ip)."
                    sub_refresh
                elif [ -z "$nd" ]; then
                    echo "  Без изменений."
                elif ! valid_domain "$nd"; then
                    echo "  ❌ «$nd» не похоже на домен."
                else
                    local ph
                    ph=$(resolve_domain "$nd")
                    if domain_points_here "$nd"; then
                        echo "  ✅ DNS: $nd → $(printf '%s' "$ph" | tr '\n' ' ')(этот сервер, DNS-only — то, что нужно)."
                    elif [ -z "$ph" ]; then
                        echo "  ⚠️ $nd пока не резолвится. Создайте A-запись $nd → один из: $(list_local_ips | tr '\n' ' ')(DNS-only)."
                    else
                        echo "  ⚠️ $nd резолвится на $(printf '%s' "$ph" | tr '\n' ' ')— НЕ на этот сервер."
                        echo "     Локальные IP: $(list_local_ips | tr '\n' ' '). Если это IP Cloudflare (оранжевое облако) — VPN не подключится."
                    fi
                    node_set CONN_HOST "$nd"
                    sub_refresh
                    echo "  ✅ В ссылках теперь домен $nd. Раздайте пользователям новую подписку/ссылку."
                fi
                pause
                ;;
            10)
                clear
                echo "  🛰  РЕЛЕЙ — реально прячет IP ноды"
                echo "  ──────────────────────────────────────────────────────"
                echo "  Релей — отдельный дешёвый VPS. Клиенты видят IP РЕЛЕЯ, он"
                echo "  форвардит трафик на эту (скрытую) ноду $(node_ip)."
                echo "  В ссылке будет адрес релея; dig покажет релей, не ноду."
                echo ""
                echo "  ⚠️ Минус: нода будет видеть всех клиентов с одного IP (релея) —"
                echo "     детектор утечки по IP перестанет различать устройства."
                echo ""
                local rh
                ask rh "  Адрес релея (IP или домен, который видит клиент; '-' убрать): "
                if [ "$rh" = "-" ]; then
                    node_set RELAY_HOST ""
                    sed -i '/^RELAY_HOST=$/d' "$NODE_CONF" 2>/dev/null
                    node_set CONN_HOST ""
                    sed -i '/^CONN_HOST=$/d' "$NODE_CONF" 2>/dev/null
                    sub_refresh
                    echo "  ✅ Релей убран — в ссылке снова прямой адрес ноды."
                    pause; continue
                fi
                [ -z "$rh" ] && { echo "  Отменено."; pause; continue; }
                node_set RELAY_HOST "$rh"
                node_set CONN_HOST "$rh"     # ссылки указывают на релей
                local rscript
                rscript=$(generate_relay_script)
                sub_refresh
                echo ""
                echo "  ✅ Ссылки теперь указывают на релей «$rh»."
                echo ""
                echo "  📋 ДАЛЬШЕ — НА РЕЛЕЙ-СЕРВЕРЕ (от root) выполните скрипт:"
                echo "  Скрипт сохранён здесь: $rscript"
                echo "  Скопируйте его на релей и запустите, например:"
                echo "     scp $rscript root@$rh:/root/relay-setup.sh"
                echo "     ssh root@$rh 'bash /root/relay-setup.sh'"
                echo ""
                echo "  Затем направьте DNS:"
                echo "    • домен подключения  → IP релея (A-запись, DNS-only)"
                echo "    • домен подписки ($(node_host)) → IP релея (если хотите спрятать IP и для подписки)"
                echo ""
                echo "  Показать содержимое скрипта сейчас? (да/нет): "
                local sc; ask sc ""
                if is_yes "$sc"; then echo ""; sed 's/^/    /' "$rscript"; fi
                pause
                ;;
            11)
                clear
                echo "  🔢 Выбор IP ноды (Caddy сядет на него)"
                echo "  ──────────────────────────────────────────────────────"
                echo "  Если у сервера несколько IP и на одном из них заняты порты"
                echo "  (nginx и т.п.), укажите свободный — Caddy привяжется к нему."
                echo ""
                local -a ips_arr=(); local k=0 cur
                cur=$(node_ip)
                while IFS= read -r oneip; do
                    [ -n "$oneip" ] || continue
                    k=$((k+1)); ips_arr[$k]="$oneip"
                    local mark=""; [ "$oneip" = "$cur" ] && mark="  ← сейчас"
                    local ph; ph=$(port_holder 443 "$oneip"); ph=${ph%%|*}
                    printf "    %d. %-18s %s%s\n" "$k" "$oneip" "${ph:+занят 443: $ph}" "$mark"
                done < <(list_local_ips)
                [ "$k" -eq 0 ] && { echo "    Не удалось определить локальные IP."; pause; continue; }
                echo "    0. Авто (отвязать от конкретного IP)"
                echo ""
                local pick; ask pick "  Выберите IP: "
                if [ "$pick" = "0" ]; then
                    node_set NODE_IP ""
                    sed -i '/^NODE_IP=$/d' "$NODE_CONF" 2>/dev/null
                    echo "  ✅ Авто-режим."
                elif [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "$k" ]; then
                    node_set NODE_IP "${ips_arr[$pick]}"
                    echo "  ✅ IP ноды: ${ips_arr[$pick]}"
                else
                    echo "  ❌ Неверный выбор."; pause; continue
                fi
                echo "  ⏳ Пересобираю Caddy на выбранном IP..."
                ensure_ports_open
                if setup_caddy >/dev/null 2>&1; then
                    echo "  ✅ Caddy перезапущен. Жду сертификат..."
                    if wait_cert "$(node_host)" 15; then
                        echo "  ✅ Сертификат выдан (до $(cert_expiry "$(node_host)")). Подписка работает."
                    else
                        echo "  ⚠️  Сертификат пока не подтверждён — проверьте DNS на этот IP и порт 80."
                    fi
                else
                    echo "  ❌ Caddy не поднялся — Диагностика (пункт 8) покажет причину."
                fi
                sub_refresh
                pause
                ;;
            12)
                while true; do
                    clear
                    echo "  🎨 Оформление подписки (что видит пользователь)"
                    echo "  ──────────────────────────────────────────────────────"
                    echo "  Название профиля : $(sub_title)"
                    echo "  Метка этой ноды  : $(node_label)"
                    echo "  Шаблон подписи   : $(sub_tag_tmpl)   (плейсхолдеры: {label} {user} {name} {online} — онлайн сервера)"
                    echo "  Интервал обновл. : каждые $(sub_update_hours) ч"
                    echo ""
                    echo "  Пример подписи ключа этой ноды: $(render_tag 'username')"
                    echo ""
                    echo "  1. Название профиля"
                    echo "  2. Метка ноды (можно с эмодзи/флагом, напр. «🇩🇪 Германия-1»)"
                    echo "  3. Шаблон подписи ключа"
                    echo "  4. Интервал обновления (часы)"
                    echo "  5. 🔄 Получить синхронизацию (локально)"
                    echo "  0. Назад"
                    echo "  ℹ️ Название, шаблон и интервал — ОБЩИЕ для кластера (синхронизируются)."
                    echo "     Метка ноды — своя у каждого сервера."
                    local ed glob_changed=0; ask ed "  Выберите: "
                    # Перед правкой ОБЩЕЙ настройки стягиваем свежие настройки пиров,
                    # чтобы ts правки (max+1) гарантированно превысил максимум по
                    # кластеру и синхронизация не откатила её (LWW при разных часах).
                    case "$ed" in 1|3|4) cluster_pull_settings ;; esac
                    case "$ed" in
                        1) local v; ask v "  Название профиля: "; [ -n "$v" ] && { setting_set SUB_TITLE "$v"; glob_changed=1; } ;;
                        2) local v; ask v "  Метка ноды (Enter — сбросить к «$(node_name)»): "; node_set NODE_LABEL "$v"; [ -z "$v" ] && sed -i '/^NODE_LABEL=$/d' "$NODE_CONF" 2>/dev/null ;;
                        3) echo "    Плейсхолдеры: {label} метка ноды · {user} имя · {name} имя ноды · {online} онлайн сервера"
                           echo "    Примеры: {label}   |   {label} · {user}   |   {label} [💚 {online}]"
                           echo "    ℹ️ {online} — сколько юзеров сейчас онлайн на КОНКРЕТНОМ сервере (индикатор"
                           echo "       загрузки: клиент видит, к какому серверу лучше подключиться). У ключа каждой"
                           echo "       ноды — онлайн своей ноды. Обновляется ~1 мин; видно после обновления подписки."
                           local v; ask v "  Шаблон (Enter — по умолчанию {label}): "; setting_set SUB_TAG_TMPL "$v"; glob_changed=1 ;;
                        4) local v; ask v "  Интервал обновления, часов (напр. 12): "; if [[ "$v" =~ ^[0-9]+$ ]]; then setting_set SUB_UPDATE_HOURS "$v"; glob_changed=1; else echo "  ❌ Нужно число"; fi ;;
                        5) cluster_sync_now; pause; continue ;;
                        0) break ;;
                        *) echo "  ❌ Неверный выбор"; sleep 1; continue ;;
                    esac
                    # Применяем: метки → пересборка подписок; заголовки → перенастройка Caddy.
                    sub_refresh
                    setup_caddy >/dev/null 2>&1
                    # Общие настройки — публикуем и разносим по кластеру через ЕДИНУЮ синхронизацию.
                    if [ "$glob_changed" = 1 ]; then
                        publish_cluster_settings
                        echo "  ✅ Применено."
                        if [ -n "$(cluster_peers 2>/dev/null)" ]; then cluster_sync_now; pause; else sleep 1; fi
                    else
                        echo "  ✅ Применено."; sleep 1
                    fi
                done
                ;;
            13)
                clear
                echo "  ⚙  Режим синхронизации после любых изменений"
                echo "  ──────────────────────────────────────────────────────"
                echo "  Текущий: $(node_get SYNC_MODE || echo ask)"
                echo ""
                echo "  1. ask  — спрашивать каждый раз (сразу или по расписанию)"
                echo "  2. auto — синхронизировать сразу, без вопроса"
                echo "  3. cron — только по расписанию (каждые 5 мин), не спрашивать"
                local sm; ask sm "  Выберите (1/2/3): "
                case "$sm" in
                    1) node_set SYNC_MODE ask;  echo "  ✅ Спрашивать каждый раз." ;;
                    2) node_set SYNC_MODE auto; echo "  ✅ Синхронизировать сразу." ;;
                    3) node_set SYNC_MODE cron; echo "  ✅ Только по расписанию." ;;
                    *) echo "  Без изменений." ;;
                esac
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
                        # Единый генератор ссылки (учитывает домен подключения/релей).
                        local link
                        link=$(build_user_link "$sel_user" "$pass" "$(link_host)" "$CACHED_PORT" "$CACHED_OBFS" "$CACHED_SNI")
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
