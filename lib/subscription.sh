#!/bin/bash
# ================================================
# Единая подписка (subscription) для клиентов.
# Клиент один раз добавляет https://<домен>/sub/<token>, нода отдаёт base64-список
# всех ключей hysteria2:// этого юзера со всех нод кластера. Статику раздаёт Caddy
# (авто-HTTPS), менеджер лишь перегенерирует файлы. Кластерную часть см. cluster.sh.
# ================================================

# Подписка включена, только если настроен домен ноды (node.conf с NODE_HOST).
sub_enabled() {
    [ -f "$NODE_CONF" ] && grep -q '^NODE_HOST=.' "$NODE_CONF" 2>/dev/null
}

# Значение поля из node.conf (NODE_NAME / NODE_HOST / WEBROOT).
node_get() {
    [ -f "$NODE_CONF" ] && grep "^${1}=" "$NODE_CONF" 2>/dev/null | head -1 | cut -d= -f2-
}
node_host() { node_get NODE_HOST; }
node_name() { local n; n=$(node_get NODE_NAME); echo "${n:-node}"; }

# Записывает node.conf (домен + имя ноды).
node_configure() {   # domain name
    local domain="$1" name="$2"
    mkdir -p "$DATA_DIR"
    {
        echo "NODE_NAME=${name}"
        echo "NODE_HOST=${domain}"
        echo "WEBROOT=${WEBROOT}"
    } > "$NODE_CONF"
}

# Права на секреты подписки (читает только менеджер от root).
secure_sub_files() {
    [ -f "$SUBTOKENS_DB" ] && chmod 600 "$SUBTOKENS_DB" 2>/dev/null || true
    [ -f "$CLUSTER_SECRET_FILE" ] && chmod 600 "$CLUSTER_SECRET_FILE" 2>/dev/null || true
}

# Файлы в WEBROOT читает процесс Caddy (обычно пользователь caddy). Каталоги
# делаем проходимыми для группы caddy, но не для остальных (имена файлов в sub/
# = токены, их нельзя давать листать чужим). Манифест с паролями — 640.
secure_web_files() {
    local cg=root
    id caddy >/dev/null 2>&1 && cg=caddy
    mkdir -p "$WEBROOT/sub" "$WEBROOT/cluster"
    chown -R "root:${cg}" "$WEBROOT" 2>/dev/null || true
    chmod 750 "$WEBROOT" "$WEBROOT/sub" "$WEBROOT/cluster" 2>/dev/null || true
    find "$WEBROOT/sub" -type f -exec chmod 640 {} + 2>/dev/null || true
    [ -f "$WEBROOT/cluster/manifest" ]   && chmod 640 "$WEBROOT/cluster/manifest" 2>/dev/null || true
    [ -f "$WEBROOT/cluster/peers.list" ] && chmod 640 "$WEBROOT/cluster/peers.list" 2>/dev/null || true
}

# Собирает клиентскую ссылку hysteria2:// для юзера. ip/port/obfs/sni можно
# передать (меню кеширует их), иначе берём из конфига. tag — суффикс #...,
# по умолчанию имя юзера; для подписки добавляем имя ноды (user@node), чтобы
# клиент видел, с какого сервера ключ.
build_user_link() {
    local user="$1" pass="$2"
    local ip="${3:-$(get_ip)}" port="${4:-$(get_port)}"
    local obfs="${5:-$(get_obfs_pass)}" sni="${6:-$(get_sni)}"
    local tag="${7:-$user}"
    printf 'hysteria2://%s:%s@%s:%s/?obfs=salamander&obfs-password=%s&sni=%s&insecure=1#%s' \
        "$user" "$pass" "$ip" "$port" "$obfs" "$sni" "$tag"
}

# Токен подписки юзера (создаёт при отсутствии). Высокоэнтропийный — он и есть
# «секрет» в ссылке https://домен/sub/<token>.
sub_token_for() {
    local user="$1" token
    touch "$SUBTOKENS_DB" 2>/dev/null
    token=$(awk -F: -v u="$user" '$1==u{print $2; exit}' "$SUBTOKENS_DB" 2>/dev/null)
    if [ -z "$token" ]; then
        token=$(pwgen -s 40 1)
        printf '%s:%s\n' "$user" "$token" >> "$SUBTOKENS_DB"
        secure_sub_files
    fi
    printf '%s' "$token"
}
sub_token_remove() { sed -i "/^${1}:/d" "$SUBTOKENS_DB" 2>/dev/null; }

# Готовая ссылка-подписка для юзера.
subscription_url() {
    local user="$1"
    sub_enabled || return 1
    printf 'https://%s/sub/%s\n' "$(node_host)" "$(sub_token_for "$user")"
}

# Публикует манифест ЭТОЙ ноды: «user<TAB>uri» по всем локальным юзерам. Его
# забирают другие ноды (за заголовком X-Cluster-Auth) и подмешивают в подписку.
publish_manifest() {
    sub_enabled || return 0
    mkdir -p "$WEBROOT/cluster"
    local tmp="$WEBROOT/cluster/manifest.tmp" u p node ip port obfs sni
    node=$(node_name)
    # Параметры сервера считаем один раз (get_ip дёргает сеть) и переиспользуем.
    ip=$(get_ip); port=$(get_port); obfs=$(get_obfs_pass); sni=$(get_sni)
    : > "$tmp"
    while IFS=: read -r u p; do
        [ -n "$u" ] || continue
        printf '%s\t%s\n' "$u" "$(build_user_link "$u" "$p" "$ip" "$port" "$obfs" "$sni" "${u}@${node}")" >> "$tmp"
    done < "$USERS_DB"
    mv "$tmp" "$WEBROOT/cluster/manifest"
    secure_web_files
}

# Пересобирает файлы подписки для всех известных юзеров: локальные ключи +
# ключи из кэшированных манифестов пиров. Дедуп по host:port.
regen_subscriptions() {
    sub_enabled || return 0
    mkdir -p "$WEBROOT/sub"

    local users
    users=$(
        cut -d: -f1 "$USERS_DB" 2>/dev/null
        [ -d "$PEERS_DIR" ] && awk -F'\t' '{print $1}' "$PEERS_DIR"/*.manifest 2>/dev/null
    )
    users=$(printf '%s\n' "$users" | grep -v '^$' | sort -u)

    local user token lp node ip port obfs sni
    node=$(node_name)
    ip=$(get_ip); port=$(get_port); obfs=$(get_obfs_pass); sni=$(get_sni)
    while IFS= read -r user; do
        [ -n "$user" ] || continue
        token=$(sub_token_for "$user")
        [ -n "$token" ] || continue   # без токена не пишем (иначе путь = каталог sub/)
        lp=$(get_user_password "$user")
        {
            [ -n "$lp" ] && { build_user_link "$user" "$lp" "$ip" "$port" "$obfs" "$sni" "${user}@${node}"; echo; }
            [ -d "$PEERS_DIR" ] && cat "$PEERS_DIR"/*.manifest 2>/dev/null \
                | awk -F'\t' -v u="$user" '$1==u{print $2}'
        } | grep -v '^$' | awk '
            {
              s=$0
              sub(/^[^/]*\/\//,"",s)   # убрать схему hysteria2://
              sub(/\/.*/,"",s)          # убрать путь/квери/фрагмент -> user:pass@host:port
              n=split(s,p,"@"); hp=p[n]  # host:port = после ПОСЛЕДНЕГО @ (пароль может содержать @)
              if (!seen[hp]++) print $0
            }' | base64 -w0 > "$WEBROOT/sub/$token"
    done <<< "$users"
    secure_web_files
}

# Удобный хук: обновить манифест и подписки после изменения пользователей.
sub_refresh() {
    sub_enabled || return 0
    publish_manifest
    regen_subscriptions
}

# Пишет Caddyfile под домен ноды и перезагружает Caddy. Идемпотентно.
# /sub/* — публично; /cluster/* — только при заголовке X-Cluster-Auth.
setup_caddy() {
    local domain="$1" secret
    [ -n "$domain" ] || domain=$(node_host)
    [ -n "$domain" ] || return 1
    secret=$(cluster_secret)
    mkdir -p "$(dirname "$CADDYFILE")" "$WEBROOT/sub" "$WEBROOT/cluster"
    cat > "$CADDYFILE" <<EOF
${domain} {
    root * ${WEBROOT}
    @authed header X-Cluster-Auth "${secret}"
    handle /cluster/* {
        handle @authed { file_server }
        respond 403
    }
    handle /sub/* {
        file_server
    }
    handle {
        respond 200
    }
}
EOF
    secure_web_files
    systemctl reload caddy 2>/dev/null || systemctl restart caddy 2>/dev/null
}
