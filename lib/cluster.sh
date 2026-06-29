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

    local host name data
    while IFS= read -r host; do
        [ -n "$host" ] || continue
        # gossip реестра
        cluster_call "$host" "/cluster/peers.list" | while IFS='|' read -r pn ph; do
            [ -n "$ph" ] && cluster_add_peer "$pn" "$ph"
        done
        # манифест пира -> локальный кэш
        name=$(awk -F'|' -v h="$host" '$2==h{print $1; exit}' "$CLUSTER_CONF" 2>/dev/null)
        [ -z "$name" ] && name=$(printf '%s' "$host" | tr -c 'a-zA-Z0-9_.-' '_')
        data=$(cluster_call "$host" "/cluster/manifest")
        [ -n "$data" ] && printf '%s\n' "$data" > "$PEERS_DIR/${name}.manifest"
    done < <(cluster_peers)

    regen_subscriptions
}
