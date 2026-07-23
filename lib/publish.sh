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
    local online tmp="$WEBROOT/cluster/stats.tmp" u oc tl tx rx sp sptx sprx ac asince
    online=$(api_get "/online")
    echo "$online" | jq empty 2>/dev/null || online='{}'
    : > "$tmp"
    while IFS=: read -r u _; do
        [ -n "$u" ] || continue
        oc=$(echo "$online" | jq -r --arg x "$u" '.[$x]//0' 2>/dev/null); [[ "$oc" =~ ^[0-9]+$ ]] || oc=0
        tl=$(get_user_traffic "$u"); tx=$(echo "$tl" | cut -d'|' -f2); rx=$(echo "$tl" | cut -d'|' -f3)
        sp=$(get_user_speed "$u");   sptx=$(echo "$sp" | cut -d'|' -f2); sprx=$(echo "$sp" | cut -d'|' -f3)
        ac=$(get_user_active "$u");  asince=$(get_user_active_since "$u")
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$u" "$oc" "${tx:-0}" "${rx:-0}" "${sptx:-0}" "${sprx:-0}" "${ac:-0}" "${asince:-0}" >> "$tmp"
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

# Суммарные подключения юзера по всему кластеру: локально (CACHED_ONLINE) + пиры.
cluster_user_connections() {
    local user="$1"
    echo $(( $(get_user_online_count "$user") + $(_peer_stat_sum "$user" 2) ))
}

# Суммарный трафик по кластеру: печатает «tx rx».
cluster_user_traffic() {
    local user="$1" l ltx lrx
    l=$(get_user_traffic "$user"); ltx=$(echo "$l" | cut -d'|' -f2); lrx=$(echo "$l" | cut -d'|' -f3)
    echo "$(( ${ltx:-0} + $(_peer_stat_sum "$user" 3) )) $(( ${lrx:-0} + $(_peer_stat_sum "$user" 4) ))"
}

# Суммарная скорость по кластеру: печатает «tx rx» (B/s).
cluster_user_speed() {
    local user="$1" l ltx lrx
    l=$(get_user_speed "$user"); ltx=$(echo "$l" | cut -d'|' -f2); lrx=$(echo "$l" | cut -d'|' -f3)
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
    tl=$(get_user_traffic "$user"); tx=$(echo "$tl" | cut -d'|' -f2); rx=$(echo "$tl" | cut -d'|' -f3)
    sp=$(get_user_speed "$user");   sptx=$(echo "$sp" | cut -d'|' -f2); sprx=$(echo "$sp" | cut -d'|' -f3)
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(node_name)" "$oc" "${tx:-0}" "${rx:-0}" "${sptx:-0}" "${sprx:-0}"
    [ -d "$PEERS_DIR" ] || return 0
    for f in "$PEERS_DIR"/*.stats; do
        [ -f "$f" ] || continue
        name=$(basename "$f" .stats)
        awk -F'\t' -v u="$user" -v n="$name" \
            '$1==u{printf "%s\t%s\t%s\t%s\t%s\t%s\n", n,$2,$3,$4,$5,$6}' "$f"
    done
}

