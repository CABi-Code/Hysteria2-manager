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
        rm -f "$PEERS_DIR/${name}.manifest" "$PEERS_DIR/${name}.stats" "$PEERS_DIR/${name}.subtokens" 2>/dev/null
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
cluster_call() {   # host path -> stdout
    local host="$1" path="$2" secret
    secret=$(cluster_secret)
    curl -fsS --max-time 8 -H "X-Cluster-Auth: $secret" "https://${host}${path}" 2>/dev/null
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
    done < <(cluster_peers)

    merge_subtokens          # единый токен подписки на всех нодах
    regen_subscriptions
    cluster_online_sync      # заодно обновим онлайн и применим лимит устройств
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
