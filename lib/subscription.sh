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

    # Чистим осиротевшие файлы подписки (токены, которых уже нет в базе).
    if [ -d "$WEBROOT/sub" ]; then
        local valid bn
        valid=$(cut -d: -f2 "$SUBTOKENS_DB" 2>/dev/null)
        for f in "$WEBROOT/sub"/*; do
            [ -f "$f" ] || continue
            bn=$(basename "$f")
            printf '%s\n' "$valid" | grep -qxF "$bn" || rm -f "$f"
        done
    fi
    secure_web_files
}

# Публикует токены подписки для остальных нод (за X-Cluster-Auth).
publish_subtokens() {
    sub_enabled || return 0
    mkdir -p "$WEBROOT/cluster"
    cp -f "$SUBTOKENS_DB" "$WEBROOT/cluster/subtokens" 2>/dev/null || true
    secure_web_files
}

# Сводит токены подписки к ЕДИНЫМ по кластеру (детерминированно — меньший токен
# выигрывает), чтобы ссылка /sub/<token> для юзера была ОДИНАКОВОЙ на всех нодах.
merge_subtokens() {
    sub_enabled || return 0
    local tmp; tmp=$(mktemp) || return 1
    {
        cat "$SUBTOKENS_DB" 2>/dev/null
        [ -d "$PEERS_DIR" ] && cat "$PEERS_DIR"/*.subtokens 2>/dev/null
    } | awk -F: 'NF>=2 && $1!="" {
            u=$1; t=substr($0,length($1)+2)
            if (!(u in best) || t < best[u]) best[u]=t
        }
        END { for (u in best) print u ":" best[u] }' | sort > "$tmp"
    [ -s "$tmp" ] && cat "$tmp" > "$SUBTOKENS_DB"
    rm -f "$tmp"
    secure_sub_files
}

# Удобный хук: обновить манифест/токены и подписки после изменения пользователей.
sub_refresh() {
    sub_enabled || return 0
    publish_manifest
    publish_subtokens
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
        respond "Hysteria2 subscription endpoint. Open your personal /sub/<token> URL inside a VPN client (Hiddify, Nekobox, sing-box) as a subscription - not in a browser." 200
    }
}
EOF
    secure_web_files
    # Caddy сам выпускает и БЕССРОЧНО продлевает сертификаты, пока сервис включён
    # и запущен. Поэтому гарантируем автозапуск + активность.
    systemctl enable caddy &>/dev/null || true
    if command -v caddy >/dev/null 2>&1; then
        caddy validate --config "$CADDYFILE" --adapter caddyfile &>/dev/null || true
    fi
    systemctl reload caddy 2>/dev/null || systemctl restart caddy 2>/dev/null
    systemctl is-active --quiet caddy 2>/dev/null || systemctl start caddy 2>/dev/null
}

# ---- Проверка домена и сертификата ----

# Базовая валидация FQDN (чтобы не записать «белиберду»).
valid_domain() {
    local d="$1"
    [ -n "$d" ] && [ ${#d} -le 253 ] || return 1
    [[ "$d" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]
}

# Все A/AAAA-адреса домена (getent/dig/host — что найдётся).
resolve_domain() {
    local d="$1"
    if command -v getent >/dev/null 2>&1; then
        getent ahosts "$d" 2>/dev/null | awk '{print $1}' | sort -u
    elif command -v dig >/dev/null 2>&1; then
        dig +short "$d" A 2>/dev/null; dig +short "$d" AAAA 2>/dev/null
    elif command -v host >/dev/null 2>&1; then
        host "$d" 2>/dev/null | awk '/has( IPv6)? address/{print $NF}'
    fi
}

# Указывает ли домен на этот сервер? 0 — да; 1 — резолвится, но не сюда; 2 — не резолвится.
domain_points_here() {
    local d="$1" myip ips
    myip=$(get_ip)
    ips=$(resolve_domain "$d")
    [ -n "$ips" ] || return 2
    printf '%s\n' "$ips" | grep -qxF "$myip" && return 0
    return 1
}

# Уже выпущен публично-доверенный сертификат для домена? Бьёмся в локальный Caddy
# (--resolve на 127.0.0.1) и проверяем цепочку СИСТЕМНЫМ доверием: внутренний
# self-signed Caddy не пройдёт, настоящий Let's Encrypt/ZeroSSL — пройдёт. Это и
# отличает реально привязанный домен от «белиберды».
cert_ready() {
    local d="$1"
    [ -n "$d" ] || return 1
    curl -sS --max-time 8 --resolve "${d}:443:127.0.0.1" "https://${d}/" -o /dev/null 2>/dev/null
}

# Дата окончания текущего сертификата (для показа), пусто если нет.
cert_expiry() {
    local d="$1"
    command -v openssl >/dev/null 2>&1 || return 0
    echo | timeout 8 openssl s_client -connect 127.0.0.1:443 -servername "$d" 2>/dev/null \
        | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2
}

# Ждёт выпуск валидного сертификата (Caddy запрашивает его при загрузке конфига).
wait_cert() {
    local d="$1" tries="${2:-15}" i=0
    while [ "$i" -lt "$tries" ]; do
        cert_ready "$d" && return 0
        i=$((i + 1)); sleep 3
    done
    return 1
}

# ---- Подключения по подписке в МАСШТАБЕ КЛАСТЕРА ----
# Подписка = один юзер на всех нодах. Хотим считать его подключения суммарно по
# кластеру и не давать раздать одну подписку на кучу устройств через разные ноды.

# Лимит устройств на подписку (0 = выкл).
get_device_limit() {
    local n; n=$(cat "$SUB_LIMIT_FILE" 2>/dev/null)
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    echo "$n"
}
set_device_limit() {
    local n="${1:-0}"; [[ "$n" =~ ^[0-9]+$ ]] || n=0
    echo "$n" > "$SUB_LIMIT_FILE"
}

# Публикует онлайн ЭТОЙ ноды («user<TAB>count») для других нод (за X-Cluster-Auth).
publish_online() {
    sub_enabled || return 0
    mkdir -p "$WEBROOT/cluster"
    local online tmp="$WEBROOT/cluster/online.tmp"
    online=$(api_get "/online")
    echo "$online" | jq empty 2>/dev/null || online='{}'
    echo "$online" | jq -r 'to_entries[] | select(.value>0) | "\(.key)\t\(.value)"' 2>/dev/null > "$tmp"
    mv "$tmp" "$WEBROOT/cluster/online"
    secure_web_files
}

# Суммарные подключения юзера по всему кластеру: локально + кэш онлайна пиров.
# Локальный онлайн берём из CACHED_ONLINE (refresh_online), чтобы не дёргать API
# на каждый вызов.
cluster_user_connections() {
    local user="$1" total n f
    total=$(get_user_online_count "$user")
    if [ -d "$PEERS_DIR" ]; then
        for f in "$PEERS_DIR"/*.online; do
            [ -f "$f" ] || continue
            n=$(awk -F'\t' -v u="$user" '$1==u{print $2; exit}' "$f" 2>/dev/null)
            [[ "$n" =~ ^[0-9]+$ ]] || n=0
            total=$((total + n))
        done
    fi
    echo "$total"
}

# Применяет лимит устройств: если суммарно по кластеру у юзера больше лимита —
# отключаем его сессии на ЭТОЙ ноде (api /kick). Так делает КАЖДАЯ нода
# независимо по одним и тем же данным, поэтому «лишние» устройства, размазанные
# по нодам, постоянно отваливаются — раздать одну подписку на 10 устройств не
# выходит. Пока подключений ≤ лимита — никого не трогаем.
enforce_device_limits() {
    local limit; limit=$(get_device_limit)
    [ "$limit" -gt 0 ] 2>/dev/null || return 0
    sub_enabled || return 0
    refresh_online          # заполнит CACHED_ONLINE для get_user_online_count
    local online_json="$CACHED_ONLINE"
    [ -z "$online_json" ] && online_json='{}'
    local user localn total
    while IFS= read -r user; do
        [ -n "$user" ] || continue
        localn=$(get_user_online_count "$user")
        [ "${localn:-0}" -gt 0 ] 2>/dev/null || continue   # кикать можем только свои сессии
        total=$(cluster_user_connections "$user")
        if [ "$total" -gt "$limit" ] 2>/dev/null; then
            api_post "/kick" "[\"$user\"]" &>/dev/null
            echo "$(date '+%F %T') $user: кластер=$total > лимит=$limit — кик на $(node_name)" \
                >> "$DATA_DIR/limit.log" 2>/dev/null
        fi
    done < <(echo "$online_json" | jq -r 'to_entries[] | select(.value>0) | .key' 2>/dev/null)
}
