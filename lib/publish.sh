#!/bin/bash
# ================================================
# Публикация данных ноды для остальных нод кластера и агрегация по пирам.
# cluster/stats, rates, ips, subips + cluster_user_* (сумма локального и пиров).
# ================================================

# Публикует статистику ЭТОЙ ноды для других нод (за X-Cluster-Auth). По строке на
# юзера: «user<TAB>online<TAB>tx<TAB>rx<TAB>sptx<TAB>sprx<TAB>active<TAB>active_since».
# Мгновенная скорость сюда НЕ входит: она живёт в отдельном cluster/rates,
# который публикуется чаще (см. publish_rates).
# Первые 6 колонок пиры подмешивают в общекластерные онлайн/трафик/скорость и в
# разбивку по нодам; active/active_since (кол. 7-8) — для traffic-based жёсткой
# проверки (enforce_active_node_limit): активен ли юзер по трафику на этой ноде и
# с какого момента. Доп. колонки в конце — обратно совместимо: старые парсеры
# читают кол. 2-6, а старые ноды (6 колонок) отдают пустой active (= неактивен).
publish_stats() {
    sub_enabled || return 0
    mkdir -p "$WEBROOT/cluster"
    local tmp="$WEBROOT/cluster/stats.tmp.$BASHPID" u oc tl tx rx sp sptx sprx ac asince ips
    # Онлайн берём ОБЩИЙ (CACHED_ONLINE: Hysteria + Xray + TUIC, схлопнутый по
    # адресам), а не сырой api_get "/online". Раньше здесь висел прямой запрос к
    # Hysteria, и юзеры, сидящие по VLESS/TUIC, для остальных нод кластера были
    # офлайн: их не видел ни список, ни лимит устройств (P-38).
    [ -n "${CACHED_ONLINE:-}" ] || { declare -F refresh_online >/dev/null 2>&1 && refresh_online; }
    : > "$tmp"
    while IFS=: read -r u _; do
        [ -n "$u" ] || continue
        oc=$(get_user_online_count "$u"); [[ "$oc" =~ ^[0-9]+$ ]] || oc=0
        IFS='|' read -r _ tx rx <<< "$(get_user_traffic "$u")"
        IFS='|' read -r _ sptx sprx <<< "$(get_user_speed "$u")"
        ac=$(get_user_active "$u");  asince=$(get_user_active_since "$u")
        # Кол. 9 — адреса юзера на этой ноде через запятую. Нужна, чтобы соседи
        # не считали одно устройство за несколько (P-45): клиент замеряет пинг по
        # всем серверам подписки, и его сессия появляется на каждой ноде.
        # Старые ноды колонку не публикуют — читатели это переживают.
        ips=""
        declare -F get_user_online_ips >/dev/null 2>&1 \
            && ips=$(get_user_online_ips "$u" | paste -sd, - 2>/dev/null)
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$u" "$oc" "${tx:-0}" "${rx:-0}" "${sptx:-0}" "${sprx:-0}" "${ac:-0}" "${asince:-0}" "${ips}" >> "$tmp"
    done < "$USERS_DB"
    mv "$tmp" "$WEBROOT/cluster/stats"
    # Локальная копия в DATA_DIR: webapi берёт отсюда число подключений СВОЕЙ ноды
    # для разбивки спидометра по нодам (WEBROOT ему недоступен, peers/*.stats — да).
    cp -f "$WEBROOT/cluster/stats" "$DATA_DIR/self.stats" 2>/dev/null || true
    secure_web_files
}

# Публикует мгновенную скорость юзеров ЭТОЙ ноды (RATES_FILE «user|bps|ts»).
# Отдельно от publish_stats, потому что каденс другой: stats — раз в минуту в
# --online-sync, rates — каждые RATES_TICK_SEC (15 с) из таймера hy2-rates.
# Это просто копия файла: считает его collect_rates, здесь только выкладка.
# Права правим точечно (а не secure_web_files): тот делает chown -R по всему
# webroot и find по sub/ — раз в минуту это незаметно, каждые 15 с уже жалко.
publish_rates() {
    sub_enabled || return 0
    mkdir -p "$WEBROOT/cluster"
    cp -f "$RATES_FILE" "$WEBROOT/cluster/rates" 2>/dev/null || : > "$WEBROOT/cluster/rates"
    local cg=root; id caddy >/dev/null 2>&1 && cg=caddy
    chown "root:${cg}" "$WEBROOT/cluster/rates" 2>/dev/null || true
    chmod 640 "$WEBROOT/cluster/rates" 2>/dev/null || true
}

# Публикует IP-адреса локальных юзеров для других нод (за X-Cluster-Auth), чтобы
# в карточке были видны IP со ВСЕХ нод кластера (юзер мог коннектиться на любую).
# Формат — как IPS_FILE: «user|ip|first|last|count».
publish_ips() {
    sub_enabled || return 0
    mkdir -p "$WEBROOT/cluster"
    cp -f "$IPS_FILE" "$WEBROOT/cluster/ips" 2>/dev/null || : > "$WEBROOT/cluster/ips"
    chmod 640 "$WEBROOT/cluster/ips" 2>/dev/null || true
    secure_web_files
}

# Публикует IP по токенам подписки (кто скачивал /sub/<token> с ЭТОЙ ноды), чтобы
# счётчик «IP за неделю» по ссылке учитывал скачивания со всех нод кластера.
# Формат — как SUBIPS_FILE: «token|ip|first|last|count».
publish_subips() {
    sub_enabled || return 0
    mkdir -p "$WEBROOT/cluster"
    cp -f "$SUBIPS_FILE" "$WEBROOT/cluster/subips" 2>/dev/null || : > "$WEBROOT/cluster/subips"
    chmod 640 "$WEBROOT/cluster/subips" 2>/dev/null || true
    secure_web_files
}

# Уникальные IP, скачавшие подписку по токену за последнюю неделю, ПО ВСЕМУ
# кластеру (локальный SUBIPS_FILE + кэши пиров). Печатает число.
link_week_ip_count() {   # token -> число
    local token="$1" week_ago
    week_ago=$(date -d '7 days ago' +%s 2>/dev/null || echo 0)
    {
        [ -f "$SUBIPS_FILE" ] && cat "$SUBIPS_FILE"
        [ -d "$PEERS_DIR" ] && cat "$PEERS_DIR"/*.subips 2>/dev/null
    } | awk -F'|' -v t="$token" -v wa="$week_ago" \
        'NF>=4 && $1==t && $4+0 >= wa+0 && !seen[$2]++ {c++} END{print c+0}'
}

# IP юзера по ВСЕМУ кластеру: локальные + из кэшей пиров, объединённые по IP
# (минимальный first, максимальный last, суммарный count, список нод).
# Печатает строки «ip<TAB>first<TAB>last<TAB>count<TAB>nodes».
cluster_user_ips() {
    local user="$1" self f name
    self=$(node_name)
    {
        get_user_ips "$user" | awk -F'|' -v n="$self" 'NF>=5{print $2"|"$3"|"$4"|"$5"|"n}'
        if [ -d "$PEERS_DIR" ]; then
            for f in "$PEERS_DIR"/*.ips; do
                [ -f "$f" ] || continue
                name=$(basename "$f" .ips)
                awk -F'|' -v u="$user" -v n="$name" '$1==u && NF>=5{print $2"|"$3"|"$4"|"$5"|"n}' "$f"
            done
        fi
    } | awk -F'|' '
        {
            ip=$1
            if (!(ip in cnt)) { first[ip]=$2; last[ip]=$3 }
            if ($2+0 < first[ip]+0) first[ip]=$2
            if ($3+0 > last[ip]+0)  last[ip]=$3
            cnt[ip]+=$4
            if (index(","nodes[ip]",", ","$5",")==0) nodes[ip]=(nodes[ip]==""?$5:nodes[ip]","$5)
        }
        END { for (ip in cnt) printf "%s\t%s\t%s\t%s\t%s\n", ip, first[ip], last[ip], cnt[ip], nodes[ip] }
    ' | sort -t$'\t' -k3,3nr
}

# Внутренний хелпер: сумма колонки $col из stats-кэшей пиров для юзера.
_peer_stat_sum() {   # user col
    local user="$1" col="$2" total=0 n f
    [ -d "$PEERS_DIR" ] || { echo 0; return; }
    for f in "$PEERS_DIR"/*.stats; do
        [ -f "$f" ] || continue
        n=$(awk -F'\t' -v u="$user" -v c="$col" '$1==u{print $c; exit}' "$f" 2>/dev/null)
        [[ "$n" =~ ^[0-9]+$ ]] || n=0
        total=$((total + n))
    done
    echo "$total"
}

# По токену на устройство: адреса, если нода их публикует, иначе синтетические
# «нода#N» по числу сессий. «?» (адрес не определён) остаётся как есть — что с
# ним делать, решает вызывающий: см. _online_count_tokens.
_online_tokens() {   # tag count ips_csv
    local tag="$1" n="$2" csv="$3"
    if [ -n "$csv" ]; then
        printf '%s\n' "$csv" | tr ',' '\n' | grep -v '^$'
    else
        seq 1 "${n:-0}" 2>/dev/null | sed "s|^|${tag}#|"
    fi
}

# Уникальные устройства из потока токенов. «?» — это «сессия есть, адрес не
# определён»: так бывает, когда сессия висит дольше, чем живёт запись в
# authmap.dat. Раньше такой токен считался отдельным устройством на КАЖДОЙ ноде,
# и юзер с одним телефоном время от времени снова получал лишнее устройство и
# кик — те самые редкие «раз через раз», что оставались после P-45.
# Правило: неизвестный адрес НЕ добавляет устройство, если известен хоть один
# (почти наверняка это он же и есть), а если известных нет вовсе — считаем один.
_online_count_tokens() {   # stdin: токены
    awk '$0=="?" { unknown=1; next } $0!="" && !seen[$0]++ { n++ }
         END { print (n ? n : (unknown ? 1 : 0)) }'
}

# Устройства юзера по всему кластеру = число РАЗНЫХ адресов, а не сумма счётчиков
# нод. Одно устройство видно сразу нескольким нодам: клиент замеряет пинг по всем
# серверам подписки, и на каждой остаётся его сессия (нулевая по трафику). Пока
# складывали счётчики, такой телефон считался за столько устройств, сколько нод в
# профиле, и лимит срабатывал на пустом месте (P-45).
# Нода, которая ещё не публикует адреса (кол. 9 в stats), даёт синтетические
# токены — её сессии считаются как раньше, отдельными.
cluster_user_connections() {
    local user="$1" f name row n csv
    {
        _online_tokens "$(node_host 2>/dev/null || echo self)" \
                       "$(get_user_online_count "$user")" \
                       "$(get_user_online_ips "$user" 2>/dev/null | paste -sd, -)"
        if [ -d "$PEERS_DIR" ]; then
            for f in "$PEERS_DIR"/*.stats; do
                [ -f "$f" ] || continue
                name=$(basename "$f" .stats)
                row=$(awk -F'\t' -v u="$user" '$1==u{printf "%d\t%s", $2, (NF>=9?$9:""); exit}' "$f" 2>/dev/null)
                n=${row%%$'\t'*}; csv=${row#*$'\t'}; [ "$csv" = "$row" ] && csv=""
                [ "${n:-0}" -gt 0 ] 2>/dev/null || continue
                _online_tokens "$name" "$n" "$csv"
            done
        fi
    } | _online_count_tokens
}

# Суммарный трафик по кластеру: печатает «tx rx».
cluster_user_traffic() {
    local user="$1" l ltx lrx
    IFS='|' read -r _ ltx lrx <<< "$(get_user_traffic "$user")"
    echo "$(( ${ltx:-0} + $(_peer_stat_sum "$user" 3) )) $(( ${lrx:-0} + $(_peer_stat_sum "$user" 4) ))"
}

# Суммарная скорость по кластеру: печатает «tx rx» (B/s).
cluster_user_speed() {
    local user="$1" l ltx lrx
    IFS='|' read -r _ ltx lrx <<< "$(get_user_speed "$user")"
    echo "$(( ${ltx:-0} + $(_peer_stat_sum "$user" 5) )) $(( ${lrx:-0} + $(_peer_stat_sum "$user" 6) ))"
}

# Онлайн ли юзер ХОТЬ ГДЕ-ТО в кластере (0/1) — для статуса в списке.
cluster_user_online_any() {
    [ "$(cluster_user_connections "$1")" -gt 0 ] 2>/dev/null
}

# Разбивка по нодам: по строке «node<TAB>online<TAB>tx<TAB>rx<TAB>sptx<TAB>sprx».
# Сначала эта нода (живые данные), затем пиры из кэша. Только где юзер присутствует.
cluster_user_breakdown() {
    local user="$1" oc tl tx rx sp sptx sprx f name
    oc=$(get_user_online_count "$user")
    IFS='|' read -r _ tx rx <<< "$(get_user_traffic "$user")"
    IFS='|' read -r _ sptx sprx <<< "$(get_user_speed "$user")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(node_name)" "$oc" "${tx:-0}" "${rx:-0}" "${sptx:-0}" "${sprx:-0}"
    [ -d "$PEERS_DIR" ] || return 0
    for f in "$PEERS_DIR"/*.stats; do
        [ -f "$f" ] || continue
        name=$(basename "$f" .stats)
        awk -F'\t' -v u="$user" -v n="$name" \
            '$1==u{printf "%s\t%s\t%s\t%s\t%s\t%s\n", n,$2,$3,$4,$5,$6}' "$f"
    done
}

