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
declare -gA SNAP_CONN PEER_TX PEER_RX PEER_STX PEER_SRX
declare -gA SNAP_IPC SNAP_EXP SNAP_DEV SNAP_HC
declare -g SNAP_POOL SNAP_NODE

build_user_stats_snapshot() {
    SNAP_ON=();  SNAP_DIS=(); SNAP_LTX=(); SNAP_LRX=(); SNAP_LSTX=(); SNAP_LSRX=()
    SNAP_CONN=(); PEER_TX=(); PEER_RX=(); PEER_STX=(); PEER_SRX=()
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
    # %.0f, а НЕ %s: mawk отдаёт числа > 2^31 в виде «2.15506e+11» (CONVFMT), и
    # bash-арифметика ниже на таком падает — трафик по пирам терялся.
    # Устройства (кол. 1 вывода) — НЕ сумма счётчиков, а число РАЗНЫХ адресов по
    # всему кластеру, включая локальные: одно устройство видно сразу нескольким
    # нодам, и сложение показывало ⚠️ тем, кто лимит не превышал (P-45). Адреса
    # пиров — кол. 9 их stats; нода, которая её ещё не публикует, считается
    # по-старому. Неизвестный адрес («?») делаем пер-нодовым, чтобы не схлопнуть
    # разные устройства в одно.
    if [ -d "$PEERS_DIR" ] && compgen -G "$PEERS_DIR/*.stats" >/dev/null 2>&1; then
        while IFS=$'\t' read -r u a b c d e; do
            [ -n "$u" ] || continue
            SNAP_CONN["$u"]=$a; PEER_TX["$u"]=$b; PEER_RX["$u"]=$c; PEER_STX["$u"]=$d; PEER_SRX["$u"]=$e
        done < <(awk -F'\t' -v loc="${CACHED_ONLINE_IPS:-}" '
                     BEGIN {
                         n = split(loc, L, "\n")
                         for (i = 1; i <= n; i++) {
                             p = index(L[i], "|"); if (p < 2) continue
                             u = substr(L[i], 1, p - 1); ip = substr(L[i], p + 1)
                             if (ip == "" ) continue
                             if (ip == "?") ip = "self#?"
                             if (!seen[u "|" ip]++) on[u]++
                         }
                     }
                     { tx[$1]+=$3; rx[$1]+=$4; stx[$1]+=$5; srx[$1]+=$6
                       if (NF >= 9 && $9 != "") {
                           m = split($9, A, ",")
                           for (j = 1; j <= m; j++) {
                               ip = A[j]; if (ip == "") continue
                               if (ip == "?") ip = FILENAME "#?"
                               if (!seen[$1 "|" ip]++) on[$1]++
                           }
                       } else on[$1] += $2
                       have[$1] = 1 }
                     END { for (k in have) printf "%s\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\n",
                                              k, on[k], tx[k], rx[k], stx[k], srx[k]
                           for (k in on) if (!(k in have)) printf "%s\t%.0f\t0\t0\t0\t0\n", k, on[k] }' \
                     "$PEERS_DIR"/*.stats 2>/dev/null)
    else
        # Пиров нет — устройства это просто локальный онлайн.
        for u in "${!SNAP_ON[@]}"; do SNAP_CONN["$u"]="${SNAP_ON[$u]}"; done
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
# Устройства по кластеру: уже с учётом локальных, дедуплицировано по адресам.
snap_conn()     { echo "${SNAP_CONN[$1]:-0}"; }
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
# Эмодзи (💚🔴⚫ …) занимают 2 колонки терминала, но ${#s} в UTF-8 локали
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
expiry_cell() {   # expiry [user]
    local exp="$1" user="${2:-}" dl
    # На бесплатном тарифе платный срок в прошлом по замыслу — «истёк» в
    # таблице читалось как «доступа нет», хотя он работает.
    if [ -n "$user" ] && declare -F freeplan_has >/dev/null 2>&1 && freeplan_has "$user"; then
        printf 'free'
        return
    fi
    if [ -z "$exp" ]; then
        printf '∞'
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
            status="⚑  ON(${oc})"; status_wide=0   # ⚠️ = база+VS16: ${#} уже учитывает ширину
        elif [ "${oc:-0}" -gt 0 ] 2>/dev/null; then
            status="💚 ON(${oc})"; status_wide=1
        else
            status="⚫ OFF"; status_wide=1
        fi

        # Кластерный статус + суммарные трафик/скорость (если подписка включена).
        local cstatus cstatus_wide tx rx sp_tx sp_rx
        if [ "$_sub" = 1 ]; then
            if [ "$over" = 1 ]; then
                cstatus="⚑  ${cc}"; cstatus_wide=0   # ⚠️ = база+VS16: ширина уже учтена
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
        exp=$(expiry_cell "${SNAP_EXP[$user]:-}" "$user")

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

