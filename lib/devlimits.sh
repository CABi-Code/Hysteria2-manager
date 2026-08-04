#!/bin/bash
# ================================================
# Глобальные лимиты подключений (POOL_LIMIT/NODE_LIMIT) и их применение.
# Лимит держится по реальному трафику: enforce_device_limits / enforce_active_node_limit.
# ================================================

# ---- Глобальные лимиты подключений (общие для кластера, синхронны) ----
# POOL_LIMIT — максимум одновременных подключений на подписку по ВСЕМУ кластеру
# (0 = без лимита). NODE_LIMIT — максимум на ОДНУ ноду (0 = без лимита; страхует
# от «размазывания» одной подписки и от багов синхронизации между нодами).
# Оба хранятся в node.conf и разъезжаются по кластеру через SETTING_KEYS (LWW).
# get_device_limit оставлен как псевдоним POOL_LIMIT для обратной совместимости.
get_device_limit() { local n; n=$(node_get POOL_LIMIT); [[ "$n" =~ ^[0-9]+$ ]] && echo "$n" || echo 0; }
get_node_limit()   { local n; n=$(node_get NODE_LIMIT); [[ "$n" =~ ^[0-9]+$ ]] && echo "$n" || echo 0; }
set_device_limit() { local n="${1:-0}"; [[ "$n" =~ ^[0-9]+$ ]] || n=0; setting_set POOL_LIMIT "$n"; }
set_node_limit()   { local n="${1:-0}"; [[ "$n" =~ ^[0-9]+$ ]] || n=0; setting_set NODE_LIMIT "$n"; }

# Разовая миграция старого device_limit (файл SUB_LIMIT_FILE) в POOL_LIMIT.
migrate_device_limit() {
    [ -f "$SUB_LIMIT_FILE" ] || return 0
    local old; old=$(cat "$SUB_LIMIT_FILE" 2>/dev/null)
    if [[ "$old" =~ ^[0-9]+$ ]] && [ -z "$(node_get POOL_LIMIT)" ]; then
        setting_set POOL_LIMIT "$old"
    fi
    rm -f "$SUB_LIMIT_FILE" 2>/dev/null
}

# ---- Эффективные лимиты КОНКРЕТНОГО пользователя ----
# Персональное кол-во устройств приоритетнее глобальных настроек:
#   pool_cap = devices(user), если >0; иначе глобальный POOL_LIMIT (0 = ∞).
#   node_cap = min(NODE_LIMIT, pool_cap); при NODE_LIMIT=0 = pool_cap.
# Значение 0 в итоге означает «без лимита» (∞).
pool_cap() {   # user -> число (0 = ∞)
    local d; d=$(get_user_devices "$1")
    if [ "${d:-0}" -gt 0 ] 2>/dev/null; then echo "$d"; else get_device_limit; fi
}
node_cap() {   # user -> число (0 = ∞)
    local nl pc; nl=$(get_node_limit); pc=$(pool_cap "$1")
    if [ "${nl:-0}" -le 0 ] 2>/dev/null; then echo "$pc"; return; fi
    if [ "${pc:-0}" -le 0 ] 2>/dev/null; then echo "$nl"; return; fi
    [ "$nl" -lt "$pc" ] && echo "$nl" || echo "$pc"
}

# Превышен ли у юзера лимит подключений (для ⚠️ в списке и решений о кике).
# cluster_conn/local_conn можно передать (снимок), иначе считаем сами.
user_over_limit() {   # user [cluster_conn] [local_conn]
    local user="$1" cc="$2" ln="$3" pc nc
    [ -z "$cc" ] && cc=$(cluster_user_connections "$user")
    [ -z "$ln" ] && ln=$(get_user_online_count "$user")
    pc=$(pool_cap "$user"); nc=$(node_cap "$user")
    { [ "${pc:-0}" -gt 0 ] && [ "${cc:-0}" -gt "$pc" ]; } 2>/dev/null && return 0
    { [ "${nc:-0}" -gt 0 ] && [ "${ln:-0}" -gt "$nc" ]; } 2>/dev/null && return 0
    return 1
}

# Снимок лимитов «user|hardcheck|pool_cap|node_cap|cluster_others».
# УСТАРЕЛО как вход для auth: скрипт аутентификации больше НЕ режет по числу
# сессий (это ломало переподключения и смену ноды), а лимит устройств держится
# по реальному трафику (enforce_active_node_limit + анти-абуз). Файл оставлен для
# совместимости/диагностики и как дешёвый снимок; на решение о пуске он не влияет.
write_authlimits() {
    local tmp="${AUTHLIMITS_FILE}.tmp.$BASHPID" user hc pc nc others owner group
    : > "$tmp" 2>/dev/null || return 0
    while IFS= read -r user; do
        [ -n "$user" ] || continue
        hc=$(get_user_hardcheck "$user")
        pc=$(pool_cap "$user"); nc=$(node_cap "$user")
        others=$(_peer_stat_sum "$user" 2)
        printf '%s|%s|%s|%s|%s\n' "$user" "$hc" "${pc:-0}" "${nc:-0}" "${others:-0}" >> "$tmp"
    done < <(get_active_users)
    mv "$tmp" "$AUTHLIMITS_FILE" 2>/dev/null
    if declare -F service_identity >/dev/null; then
        read -r owner group < <(service_identity)
        [ -n "$owner" ] && chown "${owner}:${group}" "$AUTHLIMITS_FILE" 2>/dev/null || true
    fi
    chmod 640 "$AUTHLIMITS_FILE" 2>/dev/null || true
}

# Мягкое применение лимитов: если у юзера превышен эффективный лимит — кикаем его
# сессии на ЭТОЙ ноде (api /kick). Так делает КАЖДАЯ нода независимо по одним и
# тем же данным. Кик включается ТОЛЬКО когда задан хотя бы один ГЛОБАЛЬНЫЙ лимит
# (POOL_LIMIT/NODE_LIMIT); при этом действует эффективный per-user cap
# (персональное кол-во устройств приоритетнее). Жёсткая проверка от этого кика
# больше НЕ освобождает (P-41): она ограничивает число активных НОД, а адреса
# внутри ноды держит только этот кик — раньше у таких юзеров лимит устройств не
# работал вовсе. Оба ограничения складываются.
# Снимок для auth пишем всегда.
enforce_device_limits() {
    sub_enabled || return 0
    # CACHED_ONLINE мог уже посчитать publish_stats в этом же процессе — второй
    # опрос протоколов стоил бы ещё пары секунд ради тех же чисел.
    [ -n "${CACHED_ONLINE:-}" ] || refresh_online
    local online_json="$CACHED_ONLINE"
    [ -z "$online_json" ] && online_json='{}'
    # Гейта «есть ли ГЛОБАЛЬНЫЙ лимит» здесь нет намеренно: pool_cap/node_cap
    # уже отдают персональное число устройств (а 0 = ∞), и user_over_limit при
    # нулях ничего не находит. С гейтом же обнуление POOL_LIMIT молча снимало
    # лимит и с персональных тарифов, и с демо (у них devices=1) — а именно на
    # него они и рассчитаны.
    # Починка состава Xray ДО киков: вернуть тех, кого сняла оборвавшаяся
    # заморозка прошлого прогона (см. proto_xray_kick).
    declare -F proto_xray_repair >/dev/null && proto_xray_repair

    local user localn total
    while IFS= read -r user; do
        [ -n "$user" ] || continue
        # Юзеров с жёсткой проверкой этот кик тоже касается (P-41). Раньше их
        # пропускали, отдавая traffic-based энфорсеру, — но тот считает НОДЫ, а
        # не адреса, и внутри одной ноды лимит устройств у них не действовал
        # вовсе. А попасть под жёсткую проверку можно и автоматически (окно
        # анти-абуза), то есть чем активнее шаринг, тем слабее становился лимит.
        # Теперь ограничения складываются: адреса держит этот кик, ноды —
        # enforce_active_node_limit ниже.
        localn=$(get_user_online_count "$user")
        [ "${localn:-0}" -gt 0 ] 2>/dev/null || continue   # кикать можем только свои сессии
        total=$(cluster_user_connections "$user")
        if user_over_limit "$user" "$total" "$localn"; then
            api_post "/kick" "[\"$user\"]" &>/dev/null
            # Доп. протоколы рвутся своими способами: без этого лимит держался
            # только на Hysteria, а протокол выбирает клиент (P-16).
            declare -F proto_kick_user >/dev/null && proto_kick_user "$user"
            echo "$(date '+%F %T') $user: cluster=$total local=$localn pool_cap=$(pool_cap "$user") node_cap=$(node_cap "$user") — кик на $(node_name)" \
                >> "$DATA_DIR/limit.log" 2>/dev/null
        fi
    done < <(echo "$online_json" | jq -r 'to_entries[] | select(.value>0) | .key' 2>/dev/null)
    enforce_active_node_limit
    write_authlimits
}

# Traffic-based ЖЁСТКАЯ ПРОВЕРКА: держим АКТИВНЫЙ трафик подписки не более чем на
# pool_cap нодах одновременно. «Активная» нода — та, где скорость юзера за
# последнюю минуту ≥ порога (реальное использование сети, а не пинг/keepalive).
# Если активных нод больше лимита — оставляем те, что стали активны РАНЬШЕ (по
# active_since), а на «лишних» (более поздних) кикаем сессии ЭТОЙ ноды. Так
# «первая» активная нода остаётся рабочей, а параллельная активность на других
# обрезается. Переключение на другую ноду работает само: как только старая нода
# перестаёт гнать трафик (уходит в неактив), новая становится единственной
# активной и остаётся. Решение принимает КАЖДАЯ нода независимо по одним и тем же
# данным (свой active_since + active_since пиров из их stats-кэша, кол. 7-8).
# Кикаем ТОЛЬКО свои сессии и ТОЛЬКО если сами сейчас активны и оказались «лишними».
enforce_active_node_limit() {
    sub_enabled || return 0
    local self; self=$(node_name)
    local user my_since cap active_list total keep f name
    while IFS= read -r user; do
        [ -n "$user" ] || continue
        [ "$(get_user_hardcheck_effective "$user")" = "1" ] || continue
        # Мы сами сейчас активны по трафику? Если нет — нам некого обрезать.
        [ "$(get_user_active "$user")" = "1" ] || continue
        my_since=$(get_user_active_since "$user")
        [ "${my_since:-0}" -gt 0 ] 2>/dev/null || continue

        cap=$(pool_cap "$user"); [[ "$cap" =~ ^[0-9]+$ ]] || cap=0
        [ "$cap" -le 0 ] && continue    # 0 = без лимита

        # Список активных нод «active_since|node»: эта нода + пиры (кол. 7=active,
        # 8=active_since в их stats-кэше). Старые ноды (6 колонок) сюда не попадут.
        active_list=$(
            printf '%s|%s\n' "$my_since" "$self"
            if [ -d "$PEERS_DIR" ]; then
                for f in "$PEERS_DIR"/*.stats; do
                    [ -f "$f" ] || continue
                    name=$(basename "$f" .stats)
                    awk -F'\t' -v u="$user" -v n="$name" \
                        'NF>=8 && $1==u && $7==1 && ($8+0)>0 {print $8"|"n}' "$f"
                done
            fi
        )
        total=$(printf '%s\n' "$active_list" | grep -c '|')
        [ "${total:-0}" -gt "$cap" ] 2>/dev/null || continue   # в пределах лимита

        # Оставляем cap самых ранних (по active_since, tie-break по имени ноды).
        # Если МЫ не среди «оставленных» — кикаем свои сессии на этой ноде.
        keep=$(printf '%s\n' "$active_list" | sort -t'|' -k1,1n -k2,2 | head -n "$cap")
        if ! printf '%s\n' "$keep" | grep -qx "${my_since}|${self}"; then
            api_post "/kick" "[\"$user\"]" &>/dev/null
            declare -F proto_kick_user >/dev/null && proto_kick_user "$user"
            echo "$(date '+%F %T') $user: активных нод=$total > cap=$cap — обрезаю $self (active_since=$my_since), оставляю ранние" \
                >> "$DATA_DIR/limit.log" 2>/dev/null
        fi
    done < <(get_active_users)
}
