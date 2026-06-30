#!/bin/bash
# ================================================
# Кластеризация нод для единой подписки.
# Ноды обмениваются манифестами ключей (за заголовком X-Cluster-Auth поверх TLS).
# Каждая нода держит полный кэш ключей кластера, поэтому ЛЮБАЯ нода отдаёт
# объединённую подписку. Обмен — периодический (cluster_sync, cron) + при правках.
# Активного удалённого CRUD в v1 нет (статика Caddy не исполняет код): юзера
# заводят на каждой ноде локально тем же именем, подписка объединяет их ключи.
# ================================================

# Общий секрет кластера (создаётся при первом обращении).
cluster_secret() {
    if [ ! -s "$CLUSTER_SECRET_FILE" ]; then
        pwgen -s 48 1 > "$CLUSTER_SECRET_FILE" 2>/dev/null
        chmod 600 "$CLUSTER_SECRET_FILE" 2>/dev/null
    fi
    cat "$CLUSTER_SECRET_FILE" 2>/dev/null
}

# Добавляет пир в реестр (без дублей по host).
cluster_add_peer() {   # name host
    local name="$1" host="$2"
    [ -n "$host" ] || return 1
    [ -n "$name" ] || name="$host"
    touch "$CLUSTER_CONF"
    grep -q "|${host}\$" "$CLUSTER_CONF" 2>/dev/null && return 0
    printf '%s|%s\n' "$name" "$host" >> "$CLUSTER_CONF"
}

# host'ы пиров, кроме самого себя.
cluster_peers() {
    local self; self=$(node_host)
    awk -F'|' -v s="$self" '$2!="" && $2!=s {print $2}' "$CLUSTER_CONF" 2>/dev/null | sort -u
}

# Удаляет пир из реестра + чистит его кэш. ВНИМАНИЕ: если пир «живой» и ещё есть
# в реестрах других нод, gossip вернёт его обратно — удаляйте на всех нодах.
# Недоступный/ошибочный пир после удаления просто перестаёт опрашиваться.
cluster_remove_peer() {   # host
    local host="$1" name tmp
    [ -n "$host" ] || return 1
    name=$(awk -F'|' -v h="$host" '$2==h{print $1; exit}' "$CLUSTER_CONF" 2>/dev/null)
    tmp=$(mktemp) || return 1
    awk -F'|' -v h="$host" '$2!=h' "$CLUSTER_CONF" > "$tmp" && cat "$tmp" > "$CLUSTER_CONF"
    rm -f "$tmp"
    if [ -n "$name" ]; then
        rm -f "$PEERS_DIR/${name}.manifest" "$PEERS_DIR/${name}.stats" "$PEERS_DIR/${name}.subtokens" "$PEERS_DIR/${name}.roster" "$PEERS_DIR/${name}.state" "$PEERS_DIR/${name}.ips" "$PEERS_DIR/${name}.expiry" "$PEERS_DIR/${name}.settings" 2>/dev/null
    fi
    publish_peers_list
    regen_subscriptions
}

# Публикует реестр пиров статикой (для gossip между нодами).
publish_peers_list() {
    sub_enabled || return 0
    mkdir -p "$WEBROOT/cluster"
    cp -f "$CLUSTER_CONF" "$WEBROOT/cluster/peers.list" 2>/dev/null || true
    secure_web_files
}

# Запрос к пиру с кластерной аутентификацией.
cluster_call() {   # host path [timeout] -> stdout
    local host="$1" path="$2" to="${3:-8}" secret
    secret=$(cluster_secret)
    curl -fsS --max-time "$to" -H "X-Cluster-Auth: $secret" "https://${host}${path}" 2>/dev/null
}

# Живой опрос статистики пиров — для интерактивных экранов, где видно онлайн/
# скорость/трафик по кластеру. Троттлинг: не чаще раза в LIVE_THROTTLE сек, чтобы
# не дёргать пиров на каждый перерисов. Тайм-аут короткий (живые пиры отвечают
# быстро; недоступные не вешают интерфейс надолго).
LIVE_THROTTLE=4
cluster_stats_live() {
    sub_enabled || return 0
    local now last fp="$PEERS_DIR/.live_ts"
    now=$(date +%s); last=$(cat "$fp" 2>/dev/null); [[ "$last" =~ ^[0-9]+$ ]] || last=0
    [ $((now - last)) -lt "${LIVE_THROTTLE:-4}" ] && return 0
    mkdir -p "$PEERS_DIR"; echo "$now" > "$fp"
    publish_stats
    local host name data
    while IFS= read -r host; do
        [ -n "$host" ] || continue
        name=$(awk -F'|' -v h="$host" '$2==h{print $1; exit}' "$CLUSTER_CONF" 2>/dev/null)
        [ -z "$name" ] && name=$(printf '%s' "$host" | tr -c 'a-zA-Z0-9_.-' '_')
        data=$(cluster_call "$host" "/cluster/stats" 3)
        [ -n "$data" ] && printf '%s' "$data" > "$PEERS_DIR/${name}.stats"
    done < <(cluster_peers)
}

# Инициализация кластера на первой ноде. Печатает join-токен для остальных.
cluster_init() {
    sub_enabled || { echo "Сначала настройте домен ноды."; return 1; }
    cluster_secret >/dev/null
    cluster_add_peer "$(node_name)" "$(node_host)"
    publish_peers_list
    publish_manifest
    printf '%s|%s' "$(node_host)" "$(cluster_secret)" | base64 -w0
    echo
}

# Подключение к существующему кластеру по join-токену.
cluster_join() {   # token
    local token="$1" decoded host secret
    decoded=$(printf '%s' "$token" | base64 -d 2>/dev/null) || { echo "❌ Битый токен"; return 1; }
    host="${decoded%%|*}"; secret="${decoded#*|}"
    if [ -z "$host" ] || [ -z "$secret" ] || [ "$host" = "$secret" ]; then
        echo "❌ Битый токен"; return 1
    fi
    sub_enabled || { echo "Сначала настройте домен ноды."; return 1; }
    printf '%s' "$secret" > "$CLUSTER_SECRET_FILE"; chmod 600 "$CLUSTER_SECRET_FILE"
    setup_caddy "$(node_host)"          # перенастроить Caddy с новым секретом
    cluster_add_peer "$(node_name)" "$(node_host)"
    cluster_add_peer "seed" "$host"
    publish_peers_list
    publish_manifest
    cluster_sync
    echo "✅ Подключено к $host."
    echo "   На seed-ноде один раз добавьте этот сервер: Подписка → Добавить пир → $(node_host)"
}

# Периодическая синхронизация: стянуть реестр (gossip) и манифесты пиров,
# затем пересобрать подписки. Недоступный пир пропускаем (отдаём остальные ключи).
cluster_sync() {
    sub_enabled || return 0
    mkdir -p "$PEERS_DIR"
    publish_peers_list
    publish_manifest
    publish_subtokens
    publish_roster
    publish_cluster_state
    publish_cluster_expiry
    publish_cluster_settings
    publish_ips

    local host name data
    while IFS= read -r host; do
        [ -n "$host" ] || continue
        # gossip реестра
        cluster_call "$host" "/cluster/peers.list" | while IFS='|' read -r pn ph; do
            [ -n "$ph" ] && cluster_add_peer "$pn" "$ph"
        done
        name=$(awk -F'|' -v h="$host" '$2==h{print $1; exit}' "$CLUSTER_CONF" 2>/dev/null)
        [ -z "$name" ] && name=$(printf '%s' "$host" | tr -c 'a-zA-Z0-9_.-' '_')
        # манифест ключей пира -> локальный кэш
        data=$(cluster_call "$host" "/cluster/manifest")
        [ -n "$data" ] && printf '%s\n' "$data" > "$PEERS_DIR/${name}.manifest"
        # токены подписки пира -> кэш (для единого токена по кластеру)
        data=$(cluster_call "$host" "/cluster/subtokens")
        [ -n "$data" ] && printf '%s\n' "$data" > "$PEERS_DIR/${name}.subtokens"
        # список «кластерных» юзеров пира -> кэш (для заведения у себя)
        data=$(cluster_call "$host" "/cluster/roster")
        [ -n "$data" ] && printf '%s\n' "$data" > "$PEERS_DIR/${name}.roster"
        # состояния (active/disabled/deleted) пира -> кэш (точка правды)
        data=$(cluster_call "$host" "/cluster/state")
        [ -n "$data" ] && printf '%s\n' "$data" > "$PEERS_DIR/${name}.state"
        # IP-адреса юзеров пира -> кэш (для показа IP со всех нод)
        data=$(cluster_call "$host" "/cluster/ips")
        [ -n "$data" ] && printf '%s\n' "$data" > "$PEERS_DIR/${name}.ips"
        # сроки действия кластерных юзеров пира -> кэш (для синхронизации срока)
        data=$(cluster_call "$host" "/cluster/expiry")
        [ -n "$data" ] && printf '%s\n' "$data" > "$PEERS_DIR/${name}.expiry"
        # общие настройки оформления пира -> кэш
        data=$(cluster_call "$host" "/cluster/settings")
        [ -n "$data" ] && printf '%s\n' "$data" > "$PEERS_DIR/${name}.settings"
    done < <(cluster_peers)

    cluster_apply_state      # точка правды: вкл/выкл/удаление с других нод
    cluster_apply_roster     # завести у себя кластерных юзеров, которых нет
    cluster_apply_expiry     # подтянуть единый срок действия по кластеру
    cluster_apply_settings   # подтянуть общее оформление подписки
    regen_subscriptions
    cluster_online_sync      # заодно обновим онлайн и применим лимит устройств
}

# ---- Кластерные пользователи (живут на ВСЕХ нодах) ----
# Подход pull: нода-владелец помечает юзера в roster и публикует его; остальные
# ноды на своём cluster_sync видят это и заводят юзера ЛОКАЛЬНО (свой пароль).
# Авто-заведённые в свой roster НЕ добавляются — источник истины один (владелец),
# чтобы удаление у владельца не приводило к бесконечному пересозданию.
roster_add()    { mkdir -p "$DATA_DIR"; touch "$CLUSTER_USERS_FILE"; grep -qxF "$1" "$CLUSTER_USERS_FILE" 2>/dev/null || echo "$1" >> "$CLUSTER_USERS_FILE"; }
roster_has()    { grep -qxF "$1" "$CLUSTER_USERS_FILE" 2>/dev/null; }
roster_remove() {
    [ -f "$CLUSTER_USERS_FILE" ] || return 0
    grep -vxF "$1" "$CLUSTER_USERS_FILE" > "${CLUSTER_USERS_FILE}.t" 2>/dev/null || true
    mv "${CLUSTER_USERS_FILE}.t" "$CLUSTER_USERS_FILE" 2>/dev/null || true
}

# ---- ТОЧКА ПРАВДЫ: жизненный цикл кластерного юзера (active/disabled/deleted) ----
# Нода, на которой произошло действие, бампает ts=now и публикует. Остальные на
# своём sync применяют у себя запись с наибольшим ts (last-write-wins). Так
# отключение/удаление/включение распространяются по кластеру, а deleted-tombstone
# не даёт манифесту/roster пира воскресить юзера обратно.
cstate_get()    { awk -F'|' -v u="$1" '$1==u{print $2; exit}' "$CLUSTER_STATE_FILE" 2>/dev/null; }
cstate_get_ts() { local t; t=$(awk -F'|' -v u="$1" '$1==u{print $3; exit}' "$CLUSTER_STATE_FILE" 2>/dev/null); [[ "$t" =~ ^[0-9]+$ ]] && echo "$t" || echo 0; }
cstate_set() {   # user state [ts]
    local u="$1" s="$2" ts="${3:-$(date +%s)}"
    mkdir -p "$DATA_DIR"; touch "$CLUSTER_STATE_FILE"
    sed -i "/^${u}|/d" "$CLUSTER_STATE_FILE" 2>/dev/null
    printf '%s|%s|%s\n' "$u" "$s" "$ts" >> "$CLUSTER_STATE_FILE"
}

# Зафиксировать новое состояние юзера ЛОКАЛЬНЫМ действием и тут же опубликовать.
# Только для кластерных юзеров — локальные (одна нода) не распространяем.
# Для delete вызывать ДО снятия метки (membership проверяется по roster).
cstate_mark() {   # user state
    sub_enabled || return 0
    is_cluster_user "$1" || return 0
    cstate_set "$1" "$2"
    publish_cluster_state
}

publish_cluster_state() {
    sub_enabled || return 0
    mkdir -p "$WEBROOT/cluster"; touch "$CLUSTER_STATE_FILE"
    cp -f "$CLUSTER_STATE_FILE" "$WEBROOT/cluster/state" 2>/dev/null || : > "$WEBROOT/cluster/state"
    chmod 640 "$WEBROOT/cluster/state" 2>/dev/null || true
    secure_web_files
}

# Тихое локальное удаление (без печати/сообщений) — для применения tombstone.
cluster_delete_local() {   # user
    local user="$1" _t
    if [ -f "$SUBTOKENS_DB" ]; then
        _t=$(awk -F: -v u="$user" '$1==u{print $2; exit}' "$SUBTOKENS_DB" 2>/dev/null)
        [ -n "$_t" ] && rm -f "$WEBROOT/sub/$_t" 2>/dev/null
        sub_token_remove "$user"
    fi
    db_remove_user "$user"
    sed -i "/^${user}|/d" "$DISABLED_FILE" "$STATS_FILE" "$IPS_FILE" "$EXPIRY_FILE" "$SPEED_FILE" 2>/dev/null
    roster_remove "$user"
    api_post "/kick" "[\"$user\"]" &>/dev/null
}

# Применяет состояния с других нод: для каждого юзера берём запись с наибольшим
# ts; если она новее локальной — применяем у себя (создать/включить, отключить,
# удалить) и фиксируем тот же ts (чтобы не зациклить). Лёгкие raw-операции (без
# per-user sub_refresh) — финальная пересборка делается один раз в конце.
cluster_apply_state() {
    sub_enabled || return 0
    local merged
    merged=$(
        { [ -f "$CLUSTER_STATE_FILE" ] && cat "$CLUSTER_STATE_FILE"
          [ -d "$PEERS_DIR" ] && cat "$PEERS_DIR"/*.state 2>/dev/null; } \
        | awk -F'|' 'NF>=3 && $1!="" { if (($3+0) > (ts[$1]+0)) { ts[$1]=$3; s[$1]=$2 } }
                     END { for (u in ts) printf "%s|%s|%s\n", u, s[u], ts[u] }'
    )
    [ -n "$merged" ] || return 0
    local u s t localts pw changed=0
    while IFS='|' read -r u s t; do
        [ -n "$u" ] || continue
        [[ "$u" =~ ^[a-zA-Z0-9_-]+$ ]] || continue
        localts=$(cstate_get_ts "$u")
        [ "${t:-0}" -gt "${localts:-0}" ] 2>/dev/null || continue
        case "$s" in
            active)
                if is_user_disabled "$u"; then
                    pw=$(get_disabled_password "$u")
                    [ -n "$pw" ] && db_add_user "$u" "$pw"
                    sed -i "/^${u}|/d" "$DISABLED_FILE" 2>/dev/null
                elif ! db_user_exists "$u"; then
                    db_add_user "$u" "$(pwgen -s 64 1)"
                fi
                roster_add "$u"          # это объявленный кластерный юзер
                ;;
            disabled)
                if db_user_exists "$u"; then
                    pw=$(get_user_password "$u")
                    grep -q "^${u}|" "$DISABLED_FILE" 2>/dev/null || echo "${u}|${pw}" >> "$DISABLED_FILE"
                    db_remove_user "$u"
                    api_post "/kick" "[\"$u\"]" &>/dev/null
                fi
                ;;
            deleted)
                cluster_delete_local "$u"
                ;;
        esac
        cstate_set "$u" "$s" "$t"
        changed=1
    done <<< "$merged"
    if [ "$changed" = 1 ]; then
        secure_auth_files
        sub_refresh
        publish_cluster_state
    fi
}

publish_roster() {
    sub_enabled || return 0
    mkdir -p "$WEBROOT/cluster"; touch "$CLUSTER_USERS_FILE"
    cp -f "$CLUSTER_USERS_FILE" "$WEBROOT/cluster/roster" 2>/dev/null || : > "$WEBROOT/cluster/roster"
    secure_web_files
}

# Заводит локально кластерных юзеров, объявленных пирами, которых тут ещё нет.
cluster_apply_roster() {
    sub_enabled || return 0
    local want u f created=0
    want=$(for f in "$PEERS_DIR"/*.roster; do [ -f "$f" ] && cat "$f"; done 2>/dev/null)
    want=$(printf '%s\n' "$want" | grep -v '^$' | sort -u)
    [ -n "$want" ] || return 0
    while IFS= read -r u; do
        [ -n "$u" ] || continue
        [[ "$u" =~ ^[a-zA-Z0-9_-]+$ ]] || continue
        # Точка правды важнее roster: удалённого/отключённого по кластеру НЕ
        # пересоздаём, даже если он ещё «висит» в roster-кэше пира.
        case "$(cstate_get "$u")" in deleted|disabled) continue ;; esac
        db_user_exists "$u" && continue
        is_user_disabled "$u" && continue
        db_add_user "$u" "$(pwgen -s 64 1)"
        created=1
    done <<< "$want"
    [ "$created" = 1 ] && sub_refresh
}

# Пометить юзера кластерным и разослать (peers заведут у себя на своём sync).
cluster_share_user() {   # user
    roster_add "$1"
    cstate_set "$1" active            # точка правды: юзер активен по кластеру
    publish_roster
    publish_cluster_state
    cluster_sync
}

# Предложить синхронизацию после изменения. Режим (node.conf SYNC_MODE):
#   ask  — спрашивать каждый раз (по умолчанию)
#   auto — синхронизировать сразу, без вопроса
#   cron — ничего не делать (разнесётся по расписанию)
offer_sync() {
    sub_enabled || return 0
    [ -n "$(cluster_peers 2>/dev/null)" ] || return 0   # одиночная нода — нечего синхронизировать
    local mode; mode=$(node_get SYNC_MODE); [ -z "$mode" ] && mode=ask
    case "$mode" in
        auto)
            echo "  🌐 Синхронизирую со всеми нодами..."
            cluster_sync >/dev/null 2>&1
            echo "  ✅ Синхронизировано." ;;
        cron) : ;;   # тихо, разнесётся по расписанию (каждые 5 мин)
        *)
            local a; ask a "  🌐 Синхронизировать со всеми нодами сейчас? (да/нет, по умолч. по расписанию): "
            if is_yes "$a"; then
                echo "  ⏳ Синхронизирую..."
                cluster_sync >/dev/null 2>&1
                echo "  ✅ Готово."
            fi ;;
    esac
}

# ---- Синхронизация ОФОРМЛЕНИЯ подписки (общее для кластера) ----
# Название профиля, шаблон подписи, интервал обновления — одинаковые на всех
# нодах. Значения в base64 (могут содержать пробелы/спецсимволы), last-write-wins.
publish_cluster_settings() {
    sub_enabled || return 0
    mkdir -p "$WEBROOT/cluster"
    local tmp="$WEBROOT/cluster/settings.tmp" k v ts
    : > "$tmp"
    for k in $SETTING_KEYS; do
        v=$(node_get "$k"); ts=$(setting_ts "$k")
        printf '%s|%s|%s\n' "$k" "$(printf '%s' "$v" | base64 -w0)" "$ts" >> "$tmp"
    done
    mv "$tmp" "$WEBROOT/cluster/settings"
    secure_web_files
}

cluster_apply_settings() {
    sub_enabled || return 0
    local merged
    merged=$(
        { [ -f "$WEBROOT/cluster/settings" ] && cat "$WEBROOT/cluster/settings"
          [ -d "$PEERS_DIR" ] && cat "$PEERS_DIR"/*.settings 2>/dev/null; } \
        | awk -F'|' 'NF>=3 && $1!="" { if (($3+0) > (ts[$1]+0)) { ts[$1]=$3; v[$1]=$2 } }
                     END { for (k in ts) printf "%s|%s|%s\n", k, v[k], ts[k] }'
    )
    [ -n "$merged" ] || return 0
    local k b t localts changed=0
    while IFS='|' read -r k b t; do
        [ -n "$k" ] || continue
        localts=$(setting_ts "$k")
        [ "${t:-0}" -gt "${localts:-0}" ] 2>/dev/null || continue
        setting_set "$k" "$(printf '%s' "$b" | base64 -d 2>/dev/null)" "$t"
        changed=1
    done <<< "$merged"
    if [ "$changed" = 1 ]; then
        setup_caddy >/dev/null 2>&1   # обновить заголовки (title/interval)
        sub_refresh                   # обновить подписи ключей (template)
        publish_cluster_settings
    fi
}

# ---- Синхронизация СРОКА ДЕЙСТВИЯ кластерных юзеров ----
# Все «кластерные» юзеры (объявлены в roster локально или у пиров).
cluster_users_all() {
    { [ -f "$CLUSTER_USERS_FILE" ] && cat "$CLUSTER_USERS_FILE"
      [ -d "$PEERS_DIR" ] && cat "$PEERS_DIR"/*.roster 2>/dev/null; } \
      | grep -v '^$' | sort -u
}
is_cluster_user() { cluster_users_all | grep -qxF "$1" 2>/dev/null; }

# Публикует сроки кластерных юзеров: «user|date|ts». Разделитель «|» (не пробел),
# иначе пустая дата (срок снят) схлопывалась бы при разборе через IFS-таб.
publish_cluster_expiry() {
    sub_enabled || return 0
    mkdir -p "$WEBROOT/cluster"
    local tmp="$WEBROOT/cluster/expiry.tmp" u d t
    : > "$tmp"
    while IFS= read -r u; do
        [ -n "$u" ] || continue
        d=$(get_user_expiry "$u"); t=$(expiry_get_ts "$u")
        printf '%s|%s|%s\n' "$u" "$d" "$t" >> "$tmp"
    done < <(cluster_users_all)
    mv "$tmp" "$WEBROOT/cluster/expiry"
    secure_web_files
}

# Применяет сроки с других нод: для каждого юзера берём запись с наибольшим ts;
# если она новее локальной — применяем (с тем же ts, чтобы не зациклить).
# Так изменение срока на любой ноде влияет на всю подписку (последнее изменение
# выигрывает).
cluster_apply_expiry() {
    sub_enabled || return 0
    local merged
    merged=$(
        { [ -f "$WEBROOT/cluster/expiry" ] && cat "$WEBROOT/cluster/expiry"
          [ -d "$PEERS_DIR" ] && cat "$PEERS_DIR"/*.expiry 2>/dev/null; } \
        | awk -F'|' 'NF>=3 && $1!="" { if (($3+0) >= (ts[$1]+0)) { ts[$1]=$3; d[$1]=$2 } }
                      END { for (u in ts) printf "%s|%s|%s\n", u, d[u], ts[u] }'
    )
    [ -n "$merged" ] || return 0
    local u d t localts changed=0
    while IFS='|' read -r u d t; do
        [ -n "$u" ] || continue
        localts=$(expiry_get_ts "$u")
        [ "${t:-0}" -gt "${localts:-0}" ] 2>/dev/null || continue
        if [ -n "$d" ]; then set_user_expiry "$u" "$d" "$t"; else remove_user_expiry "$u" "$t"; fi
        changed=1
    done <<< "$merged"
    if [ "$changed" = 1 ]; then
        check_expired_users >/dev/null 2>&1
        publish_cluster_expiry
    fi
}

# Частая синхронизация СТАТИСТИКИ (онлайн/трафик/скорость по кластеру + лимит
# устройств). Публикует свою статистику, стягивает статистику пиров, применяет
# лимит. Лёгкая — гоняется по cron чаще (раз в минуту), чем полная cluster_sync.
cluster_online_sync() {
    sub_enabled || return 0
    mkdir -p "$PEERS_DIR"
    publish_stats

    local host name data
    while IFS= read -r host; do
        [ -n "$host" ] || continue
        name=$(awk -F'|' -v h="$host" '$2==h{print $1; exit}' "$CLUSTER_CONF" 2>/dev/null)
        [ -z "$name" ] && name=$(printf '%s' "$host" | tr -c 'a-zA-Z0-9_.-' '_')
        # Свежая статистика пира; недоступен -> пусто (= 0), не залипаем на старом.
        data=$(cluster_call "$host" "/cluster/stats")
        printf '%s' "$data" > "$PEERS_DIR/${name}.stats"
    done < <(cluster_peers)

    enforce_device_limits
}
