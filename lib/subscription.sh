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

# Все локальные «белые» IPv4 сервера (у VPS их может быть несколько).
list_local_ips() {
    if command -v ip >/dev/null 2>&1; then
        ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1
    else
        hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9.]+$'
    fi
}

# IP, который использует ИМЕННО эта нода: Caddy на него садится, он же идёт в
# ссылку. Берём NODE_IP из node.conf (если задан и всё ещё локальный), иначе
# авто (внешний get_ip). Важно при нескольких IP: на занятом nginx-ом IP Caddy
# не поднять, поэтому используем свободный, на который указывает домен.
node_ip() {
    local saved
    saved=$(node_get NODE_IP)
    if [ -n "$saved" ] && list_local_ips | grep -qxF "$saved" 2>/dev/null; then
        printf '%s' "$saved"; return
    fi
    get_ip
}

# Если домен ноды резолвится в один из ЛОКАЛЬНЫХ IP — фиксируем именно его как
# NODE_IP (Caddy сядет туда, не конфликтуя с другим сервисом на другом IP).
autoset_node_ip() {
    local host dip locals
    host=$(node_host); [ -n "$host" ] || return 1
    locals=$(list_local_ips)
    for dip in $(resolve_domain "$host" 2>/dev/null); do
        if printf '%s\n' "$locals" | grep -qxF "$dip"; then
            node_set NODE_IP "$dip"
            return 0
        fi
    done
    return 1
}

# Записывает node.conf (домен + имя ноды).
# Устанавливает/обновляет одно поле node.conf, не трогая остальные.
node_set() {   # key value
    local key="$1" val="$2"
    mkdir -p "$DATA_DIR"; touch "$NODE_CONF"
    if grep -q "^${key}=" "$NODE_CONF" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$NODE_CONF"
    else
        echo "${key}=${val}" >> "$NODE_CONF"
    fi
}

node_configure() {   # domain name
    node_set NODE_NAME "$2"
    node_set NODE_HOST "$1"
    node_set WEBROOT  "$WEBROOT"
}

# Адрес ноды для ССЫЛКИ подключения: домен подключения (CONN_HOST), если задан,
# иначе публичный IP. Позволяет показывать в подписке домен вместо «голого» IP.
# ВАЖНО: домен подключения должен быть DNS-only (A-запись прямо на IP ноды) —
# Hysteria работает по UDP/QUIC, а проксирование Cloudflare (UDP) не пропускает.
link_host() {
    local h; h=$(node_get CONN_HOST)
    [ -n "$h" ] && { printf '%s' "$h"; return; }
    node_ip
}

# ---- Оформление подписки (что видит пользователь в клиенте) ----
# Метка ноды (название сервера в клиенте; можно с эмодзи/флагом). По умолчанию — имя ноды.
node_label()       { local l; l=$(node_get NODE_LABEL); echo "${l:-$(node_name)}"; }
# Шаблон подписи каждого ключа (#фрагмент). Плейсхолдеры: {label} {user} {name}.
sub_tag_tmpl()     { local t; t=$(node_get SUB_TAG_TMPL); [ -z "$t" ] && t='{label}'; printf '%s' "$t"; }
# Название всего профиля подписки в клиенте.
sub_title()        { local t; t=$(node_get SUB_TITLE); echo "${t:-VPN}"; }
# Как часто клиент обновляет подписку (часы).
sub_update_hours() { local h; h=$(node_get SUB_UPDATE_HOURS); [[ "$h" =~ ^[0-9]+$ ]] || h=12; echo "$h"; }

# Подпись ключа по шаблону для конкретного юзера.
render_tag() {   # user
    local u="$1" t; t=$(sub_tag_tmpl)
    t=${t//\{user\}/$u}
    t=${t//\{label\}/$(node_label)}
    t=${t//\{name\}/$(node_name)}
    printf '%s' "$t"
}

# Глобальные (общие для всего кластера) настройки. Метка ноды (NODE_LABEL) сюда
# НЕ входит — она у каждой ноды своя. POOL_LIMIT/NODE_LIMIT — глобальные лимиты
# подключений (см. ниже), синхронизируются тем же LWW-механизмом.
SETTING_KEYS="SUB_TITLE SUB_TAG_TMPL SUB_UPDATE_HOURS POOL_LIMIT NODE_LIMIT"

# Установить общую настройку + метку времени (для синхронизации last-write-wins).
setting_set() {   # key value [ts]
    local k="$1" v="$2" ts="${3:-$(date +%s)}"
    node_set "$k" "$v"
    node_set "${k}_TS" "$ts"
}
setting_ts() { local t; t=$(node_get "${1}_TS"); [[ "$t" =~ ^[0-9]+$ ]] && echo "$t" || echo 0; }

# ---- Релей (фронт-сервер, реально прячет IP ноды) ----
# Релей — отдельный дешёвый VPS. Клиенты/DNS видят IP релея, релей форвардит
# трафик (UDP Hysteria + TCP 80/443) на скрытую ноду. dig покажет IP релея.
relay_host() { node_get RELAY_HOST; }

# Генерирует скрипт, который надо запустить НА РЕЛЕЙ-СЕРВЕРЕ (от root). Печатает
# путь к скрипту. Форвардит UDP-порт Hysteria и TCP 80/443 на реальную ноду.
generate_relay_script() {
    local node_ip hyport out
    node_ip=$(node_ip); hyport=$(get_port)
    out="$DATA_DIR/relay-setup.sh"
    cat > "$out" <<EOF
#!/bin/bash
# ╔═══════════════════════════════════════════════════════════════╗
# ║  ЗАПУСКАТЬ НА РЕЛЕЙ-СЕРВЕРЕ (отдельный VPS), от root.           ║
# ║  Форвардит трафик на скрытую ноду ${node_ip}.                  ║
# ╚═══════════════════════════════════════════════════════════════╝
set -e
NODE_IP="${node_ip}"
HYPORT="${hyport}"

# Включаем форвардинг пакетов
sysctl -w net.ipv4.ip_forward=1 >/dev/null
grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf

# UDP — сам VPN (Hysteria/QUIC)
iptables -t nat -C PREROUTING -p udp --dport "\$HYPORT" -j DNAT --to-destination "\$NODE_IP:\$HYPORT" 2>/dev/null || \\
  iptables -t nat -A PREROUTING -p udp --dport "\$HYPORT" -j DNAT --to-destination "\$NODE_IP:\$HYPORT"

# TCP 80/443 — подписка (Caddy на ноде). Нужно, только если домен подписки тоже
# указывает на релей. Без этого можно убрать, но тогда IP ноды виден в подписке.
for tp in 80 443; do
  iptables -t nat -C PREROUTING -p tcp --dport "\$tp" -j DNAT --to-destination "\$NODE_IP:\$tp" 2>/dev/null || \\
    iptables -t nat -A PREROUTING -p tcp --dport "\$tp" -j DNAT --to-destination "\$NODE_IP:\$tp"
done

# Обратный путь
iptables -t nat -C POSTROUTING -d "\$NODE_IP" -j MASQUERADE 2>/dev/null || \\
  iptables -t nat -A POSTROUTING -d "\$NODE_IP" -j MASQUERADE

# Сохраняем правила (если установлен iptables-persistent)
mkdir -p /etc/iptables && iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

echo "✅ Релей настроен: UDP \$HYPORT + TCP 80,443 -> \$NODE_IP"
echo "   Не забудьте открыть эти порты в firewall релея."
EOF
    chmod +x "$out"
    printf '%s' "$out"
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
    local ip="${3:-$(link_host)}" port="${4:-$(get_port)}"
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

# ---- Несколько ссылок подписки на юзера (по одной на устройство/человека) ----
# У юзера может быть несколько токенов (строк «user:token» в SUBTOKENS_DB) — все
# отдают один и тот же набор ключей. Разные токены нужны, чтобы раздать подписку
# нескольким людям и по логам Caddy видеть IP отдельно по каждой ссылке.

# Все ЛОКАЛЬНЫЕ токены юзера (первый — основной, созданный sub_token_for).
sub_tokens_all() { awk -F: -v u="$1" '$1==u{print $2}' "$SUBTOKENS_DB" 2>/dev/null; }

# Токены юзера ПО ВСЕМУ КЛАСТЕРУ (локальные + кэш пиров), для подсчёта лимита ссылок.
sub_tokens_cluster() {
    { sub_tokens_all "$1"
      [ -d "$PEERS_DIR" ] && awk -F: -v u="$1" '$1==u{print $2}' "$PEERS_DIR"/*.subtokens 2>/dev/null; } \
    | grep -v '^$' | sort -u
}

# Сколько ссылок разрешено юзеру = его кол-во устройств (0/∞ → без ограничения).
sub_links_allowed() { local d; d=$(get_user_devices "$1"); echo "${d:-1}"; }

# Создать новую доп. ссылку (токен). Печатает новый токен или пусто при отказе.
# Соблюдает лимит: число ссылок по кластеру не должно превышать кол-во устройств.
sub_link_add() {   # user -> token | ""
    local user="$1" allowed have token
    sub_token_for "$user" >/dev/null           # гарантируем основной токен
    allowed=$(sub_links_allowed "$user")
    have=$(sub_tokens_cluster "$user" | grep -c .)
    if [ "${allowed:-0}" -gt 0 ] 2>/dev/null && [ "${have:-0}" -ge "$allowed" ]; then
        return 1                               # лимит ссылок исчерпан
    fi
    token=$(pwgen -s 40 1)
    printf '%s:%s\n' "$user" "$token" >> "$SUBTOKENS_DB"
    secure_sub_files
    printf '%s' "$token"
}

# Удалить конкретную ссылку (токен) юзера. Основной (первый) токен не удаляем,
# чтобы у юзера всегда оставалась рабочая подписка.
sub_link_remove() {   # user token
    local user="$1" token="$2" primary
    primary=$(sub_token_for "$user")
    [ "$token" = "$primary" ] && return 2      # основной токен не трогаем
    sub_tokens_all "$user" | grep -qxF "$token" || return 1
    sed -i "/^${user}:${token}\$/d" "$SUBTOKENS_DB" 2>/dev/null
    rm -f "$WEBROOT/sub/$token" 2>/dev/null
    secure_sub_files
    return 0
}

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
    ip=$(link_host); port=$(get_port); obfs=$(get_obfs_pass); sni=$(get_sni)
    : > "$tmp"
    while IFS=: read -r u p; do
        [ -n "$u" ] || continue
        printf '%s\t%s\n' "$u" "$(build_user_link "$u" "$p" "$ip" "$port" "$obfs" "$sni" "$(render_tag "$u")")" >> "$tmp"
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

    local user lp node ip port obfs sni content tok toks cst
    node=$(node_name)
    ip=$(link_host); port=$(get_port); obfs=$(get_obfs_pass); sni=$(get_sni)
    while IFS= read -r user; do
        [ -n "$user" ] || continue
        # Точка правды: для удалённого/отключённого по кластеру отдаём ПУСТУЮ
        # подписку (клиент остаётся без серверов), даже если он ещё «висит» в кэше
        # манифеста пира. Так отключение/удаление действует сразу, не дожидаясь
        # пиров. Важно перезаписать токены пустым, а не пропустить — иначе остался
        # бы старый файл подписки с рабочими ключами.
        cst=""
        declare -F cstate_get >/dev/null 2>&1 && cst=$(cstate_get "$user")
        if [ "$cst" = "deleted" ] || [ "$cst" = "disabled" ]; then
            content=""
        else
            lp=$(get_user_password "$user")
            content=$(
                {
                    [ -n "$lp" ] && { build_user_link "$user" "$lp" "$ip" "$port" "$obfs" "$sni" "$(render_tag "$user")"; echo; }
                    [ -d "$PEERS_DIR" ] && cat "$PEERS_DIR"/*.manifest 2>/dev/null \
                        | awk -F'\t' -v u="$user" '$1==u{print $2}'
                } | grep -v '^$' | awk '
                    {
                      s=$0
                      sub(/^[^/]*\/\//,"",s)   # убрать схему hysteria2://
                      sub(/\/.*/,"",s)          # убрать путь/квери/фрагмент -> user:pass@host:port
                      n=split(s,p,"@"); hp=p[n]  # host:port = после ПОСЛЕДНЕГО @ (пароль может содержать @)
                      if (!seen[hp]++) print $0
                    }' | base64 -w0
            )
        fi
        # ВАЖНО: пишем подписку под ВСЕ токены юзера (наш + токены пиров). Так
        # уже розданная ссылка НИКОГДА не ломается, даже если на другой ноде у
        # юзера свой токен. Свой токен обязателен — создаём, если нет. Для
        # УДАЛЁННОГО свой токен НЕ создаём (иначе воскреснет) — только перезапишем
        # пустым уже существующие токены пиров.
        if [ "$cst" = "deleted" ]; then
            toks=$( [ -d "$PEERS_DIR" ] && awk -F: -v u="$user" '$1==u{print $2}' "$PEERS_DIR"/*.subtokens 2>/dev/null )
        else
            toks=$(
                sub_token_for "$user" >/dev/null    # гарантируем основной токен
                sub_tokens_all "$user"              # ВСЕ локальные токены (доп. ссылки)
                [ -d "$PEERS_DIR" ] && awk -F: -v u="$user" '$1==u{print $2}' "$PEERS_DIR"/*.subtokens 2>/dev/null
            )
        fi
        toks=$(printf '%s\n' "$toks" | grep -v '^$' | sort -u)
        while IFS= read -r tok; do
            [ -n "$tok" ] || continue
            printf '%s' "$content" > "$WEBROOT/sub/$tok"
        done <<< "$toks"
    done <<< "$users"

    # Чистим ТОЛЬКО действительно осиротевшие токены: которых нет ни в нашей базе,
    # ни в кэше токенов пиров (т.е. юзер удалён везде). Иначе бы ломали чужие ссылки.
    if [ -d "$WEBROOT/sub" ]; then
        local valid bn
        valid=$(
            cut -d: -f2 "$SUBTOKENS_DB" 2>/dev/null
            [ -d "$PEERS_DIR" ] && awk -F: '{print $2}' "$PEERS_DIR"/*.subtokens 2>/dev/null
        )
        valid=$(printf '%s\n' "$valid" | grep -v '^$' | sort -u)
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

# Токены НЕ объединяем: у каждой ноды свой стабильный токен для юзера, а подписка
# отдаётся под ВСЕМИ токенами (см. regen_subscriptions). Это гарантирует, что уже
# розданная ссылка не ломается, даже если на другой ноде юзер с тем же именем
# получил свой токен. Оставлено no-op для обратной совместимости вызовов.
merge_subtokens() { return 0; }

# Удобный хук: обновить манифест/токены и подписки после изменения пользователей.
sub_refresh() {
    sub_enabled || return 0
    publish_manifest
    publish_subtokens
    publish_stats
    regen_subscriptions
}

# Пишет Caddyfile под домен ноды и перезагружает Caddy. Идемпотентно.
# /sub/* — публично; /cluster/* — только при заголовке X-Cluster-Auth.
setup_caddy() {
    local domain="$1" secret bak
    [ -n "$domain" ] || domain=$(node_host)
    [ -n "$domain" ] || return 1
    secret=$(cluster_secret)
    mkdir -p "$(dirname "$CADDYFILE")" "$WEBROOT/sub" "$WEBROOT/cluster"
    # Каталог для access-лога подписки (из него collect_sub_ips берёт IP по токенам).
    local clog_dir; clog_dir=$(dirname "$CADDY_ACCESS_LOG")
    mkdir -p "$clog_dir" 2>/dev/null
    id caddy >/dev/null 2>&1 && chown caddy:caddy "$clog_dir" 2>/dev/null || true

    # Если домен указывает на один из локальных IP — фиксируем его как NODE_IP,
    # чтобы при нескольких IP Caddy сел на нужный (свободный), а не на занятый.
    autoset_node_ip 2>/dev/null || true

    # Если у сервера несколько IP и наш IP — реально локальный, привязываем Caddy
    # ИМЕННО к нему. Тогда другой сервис (nginx и т.п.) на другом IP не мешает.
    local bind_ip bind_line=""
    bind_ip=$(node_ip)
    if [ "$(list_local_ips | grep -c .)" -gt 1 ] && list_local_ips | grep -qxF "$bind_ip" 2>/dev/null; then
        bind_line="    bind ${bind_ip}"
    fi

    # Оформление подписки: название профиля (base64) и интервал обновления —
    # клиенты (Hiddify и др.) читают эти заголовки и показывают их пользователю.
    local title_b64 upd
    title_b64=$(printf '%s' "$(sub_title)" | base64 -w0 2>/dev/null)
    upd=$(sub_update_hours)

    # Бэкап текущего конфига — чтобы при ошибке не уронить уже работающий Caddy.
    bak=""
    [ -f "$CADDYFILE" ] && { bak=$(mktemp); cp -f "$CADDYFILE" "$bak"; }

    # ВАЖНО: каждый блок — на отдельных строках; «{» обязана быть последним
    # токеном строки, иначе Caddy не парсит конфиг и не стартует. handle-блоки
    # взаимоисключающие и проверяются в порядке записи.
    cat > "$CADDYFILE" <<EOF
${domain} {
    root * ${WEBROOT}
${bind_line}
    log {
        output file ${CADDY_ACCESS_LOG} {
            roll_size 10MiB
            roll_keep 3
        }
        format json
    }
    @cluster_noauth {
        path /cluster/*
        not header X-Cluster-Auth "${secret}"
    }
    @cluster_auth {
        path /cluster/*
        header X-Cluster-Auth "${secret}"
    }

    handle @cluster_noauth {
        respond 403
    }
    handle @cluster_auth {
        file_server
    }
    handle /sub/* {
        header Content-Type "text/plain; charset=utf-8"
        header profile-title "base64:${title_b64}"
        header profile-update-interval "${upd}"
        header profile-web-page-url "https://${domain}/"
        file_server
    }
    handle {
        respond "Hysteria2 subscription endpoint. Open your personal /sub/<token> URL inside a VPN client (Hiddify, Nekobox, sing-box) as a subscription - not in a browser." 200
    }
}
EOF
    secure_web_files

    # Проверяем конфиг ДО применения. Если невалиден — откат, Caddy не трогаем.
    systemctl enable caddy &>/dev/null || true
    if command -v caddy >/dev/null 2>&1; then
        if ! caddy validate --config "$CADDYFILE" --adapter caddyfile &>/dev/null; then
            [ -n "$bak" ] && cp -f "$bak" "$CADDYFILE"
            [ -n "$bak" ] && rm -f "$bak"
            return 1
        fi
    fi
    [ -n "$bak" ] && rm -f "$bak"

    # Caddy сам выпускает и БЕССРОЧНО продлевает сертификаты, пока сервис активен.
    systemctl reload caddy 2>/dev/null || systemctl restart caddy 2>/dev/null
    systemctl is-active --quiet caddy 2>/dev/null || systemctl start caddy 2>/dev/null
    systemctl is-active --quiet caddy 2>/dev/null
}

# Открывает 80/443 tcp в активном firewall (ufw/firewalld/iptables). Идемпотентно.
# 80 нужен для ACME-проверки Let's Encrypt, 443 — для самой подписки.
ensure_ports_open() {
    local p
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "Status: active"; then
        for p in 80 443; do ufw allow "${p}/tcp" >/dev/null 2>&1 || true; done
        return 0
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state &>/dev/null; then
        for p in 80 443; do firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null 2>&1 || true; done
        firewall-cmd --reload >/dev/null 2>&1 || true
        return 0
    fi
    # iptables — best-effort: добавляем ACCEPT, только если правило ещё не стоит.
    if command -v iptables >/dev/null 2>&1; then
        for p in 80 443; do
            iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null && continue
            iptables -I INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
        done
    fi
    return 0
}

# Регэксп локального адреса для ss/netstat: либо конкретный ip:port, либо
# wildcard (*/0.0.0.0/[::]):port (такой слушатель покрывает и наш ip).
_addr_pat() {   # port [ip]
    local p="$1" ip="$2"
    if [ -n "$ip" ]; then
        printf '(\\*|0\\.0\\.0\\.0|\\[::\\]|%s):%s$' "${ip//./\\.}" "$p"
    else
        printf ':%s$' "$p"
    fi
}

# Слушается ли TCP-порт (опц. на конкретном ip). Caddy на 80/443.
port_listening() {   # port [ip]
    local pat; pat=$(_addr_pat "$1" "$2")
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | awk -v pat="$pat" '$4 ~ pat{f=1} END{exit !f}'
    elif command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | awk -v pat="$pat" '$4 ~ pat{f=1} END{exit !f}'
    else
        return 0
    fi
}

# Кто слушает TCP-порт (опц. на конкретном ip). Печатает «процесс|pid|unit».
# Требует root (ss -p) — менеджер работает от root.
port_holder() {   # port [ip]
    local pat line proc pid unit
    command -v ss >/dev/null 2>&1 || { printf '||'; return; }
    pat=$(_addr_pat "$1" "$2")
    line=$(ss -ltnp 2>/dev/null | awk -v pat="$pat" '$4 ~ pat{print; exit}')
    proc=$(printf '%s' "$line" | sed -nE 's/.*\(\("([^"]+)".*/\1/p')
    pid=$(printf '%s'  "$line" | sed -nE 's/.*pid=([0-9]+).*/\1/p')
    if [ -n "$pid" ] && [ -r "/proc/$pid/cgroup" ]; then
        unit=$(sed -nE 's@.*/([a-zA-Z0-9_.@-]+\.service).*@\1@p' "/proc/$pid/cgroup" 2>/dev/null | head -1)
    fi
    printf '%s|%s|%s' "$proc" "$pid" "$unit"
}

# Последняя содержательная строка ошибки запуска Caddy из журнала.
caddy_failure_reason() {
    journalctl -u caddy -n 80 --no-pager 2>/dev/null \
        | grep -iE 'Error:|address already in use|permission denied|bind:|cannot' \
        | tail -1 | sed -E 's/.*caddy\[[0-9]+\]: //; s/^[[:space:]]*//'
}

# Пробует запустить Caddy и вернуть результат. Заодно гарантирует автозапуск.
# Печатает диагноз; при конфликте порта выставляет глобальные DIAG_CONFLICT_*.
caddy_start_report() {
    DIAG_CONFLICT_UNIT=""; DIAG_CONFLICT_PORT=""; DIAG_CONFLICT_PROC=""
    if ! command -v caddy >/dev/null 2>&1; then
        echo "  ❌ Caddy не установлен (Подписка → 1 поставит автоматически)"
        return 1
    fi
    if ! caddy validate --config "$CADDYFILE" --adapter caddyfile &>/dev/null; then
        echo "  ❌ Caddyfile невалиден — пересоберите (Подписка → 1 или Настройки → 3)"
    else
        echo "  ✅ Caddyfile валиден"
    fi
    # автозапуск
    if systemctl is-enabled --quiet caddy 2>/dev/null; then
        echo "  ✅ Caddy в автозапуске"
    else
        echo "  ⏳ Включаю автозапуск Caddy..."
        systemctl enable caddy &>/dev/null && echo "  ✅ Автозапуск включён" \
            || echo "  ⚠️  Не удалось включить автозапуск"
    fi
    # запущен? если нет — пробуем поднять
    if ! systemctl is-active --quiet caddy 2>/dev/null; then
        echo "  ⏳ Caddy не запущен — пробую запустить..."
        systemctl start caddy 2>/dev/null
        sleep 1
    fi
    if systemctl is-active --quiet caddy 2>/dev/null; then
        echo "  ✅ Caddy запущен"
        return 0
    fi

    # Не поднялся — объясняем причину.
    local reason; reason=$(caddy_failure_reason)
    echo "  ❌ Caddy НЕ запускается."
    [ -n "$reason" ] && echo "     Причина: $reason"
    case "$reason" in
        *"address already in use"*|*"bind:"*)
            local cp nip; cp=$(printf '%s' "$reason" | grep -oE ':(80|443)\b' | tr -d ':' | head -1)
            [ -z "$cp" ] && cp=443
            # Несколько IP? Пробуем привязать Caddy к свободному (на который указывает домен).
            if [ "$(list_local_ips | grep -c .)" -gt 1 ]; then
                echo "     💡 У сервера несколько IP — пробую привязать Caddy к свободному..."
                autoset_node_ip 2>/dev/null || true
                setup_caddy >/dev/null 2>&1
                if systemctl is-active --quiet caddy 2>/dev/null; then
                    echo "  ✅ Caddy запущен на IP $(node_ip) (другой сервис на другом IP не мешает)."
                    return 0
                fi
            fi
            nip=$(node_ip)
            local h proc pid unit; h=$(port_holder "$cp" "$nip")
            proc=${h%%|*}; pid=$(printf '%s' "$h" | cut -d'|' -f2); unit=${h##*|}
            echo "     ⛔ Порт ${nip}:$cp занят: ${proc:-неизвестный процесс}${pid:+ (pid $pid)}${unit:+, сервис: $unit}"
            if [ "$(list_local_ips | grep -c .)" -gt 1 ]; then
                echo "     Укажите свободный IP вручную: Подписка → 11 (Выбрать IP ноды),"
                echo "     и убедитесь, что домен указывает на этот IP."
            fi
            if [ -n "$unit" ]; then
                echo "     Либо освободить порт: systemctl stop $unit (или смените его порт)."
                DIAG_CONFLICT_UNIT="$unit"; DIAG_CONFLICT_PORT="$cp"; DIAG_CONFLICT_PROC="$proc"
            fi
            ;;
        *"permission denied"*)
            echo "     Нет прав на привязку порта. Проверьте capabilities caddy.service."
            ;;
    esac
    echo "     Полный лог: journalctl -u caddy -e | tail -n 30"
    return 1
}

# Полная диагностика подписки: DNS→сервер, порты, Caddy, сертификат, пиры и
# содержимое подписки. Печатает отчёт с ✅/❌ и подсказками.
subscription_diagnose() {
    local host myip ips
    echo "  ══ Диагностика подписки ══════════════════════════════"
    if ! sub_enabled; then
        echo "  ⚪ Подписка не настроена (Настройки → Подписка → 1)."
        return 0
    fi
    autoset_node_ip 2>/dev/null || true
    host=$(node_host); myip=$(node_ip)
    local alllocal; alllocal=$(list_local_ips | tr '\n' ' ')
    echo "  Нода «$(node_name)» · домен $host"
    echo "  IP ноды (Caddy): $myip   ·   Все IP сервера: ${alllocal:-?}"
    echo ""

    # 1. DNS — принимаем ЛЮБОЙ локальный IP (у сервера их может быть несколько).
    ips=$(resolve_domain "$host")
    if [ -z "$ips" ]; then
        echo "  ❌ DNS: $host не резолвится. Нужна A-запись $host → один из: ${alllocal}"
    elif domain_points_here "$host"; then
        echo "  ✅ DNS: $host → $(printf '%s' "$ips" | tr '\n' ' ')(этот сервер)"
    else
        echo "  ❌ DNS: $host → $(printf '%s' "$ips" | tr '\n' ' ')(НЕ этот сервер)"
        echo "        Локальные IP сервера: ${alllocal}"
        echo "        Нужна ПРЯМАЯ A-запись на один из них, без CDN/прокси (Akamai/Cloudflare)."
    fi

    # 2. Caddy: проверяем, при необходимости включаем/запускаем, объясняем сбой.
    echo "  ── Caddy ──"
    caddy_start_report

    # 3. Порты — проверяем ИМЕННО на IP ноды (на другом IP может сидеть nginx — это ок).
    echo "  ── Порты (на IP ноды $myip) ──"
    local p
    for p in 80 443; do
        if port_listening "$p" "$myip"; then
            local h proc unit
            h=$(port_holder "$p" "$myip"); proc=${h%%|*}; unit=${h##*|}
            if printf '%s' "$proc" | grep -qi caddy; then
                echo "  ✅ Порт ${myip}:$p слушает Caddy"
            else
                echo "  ⚠️  Порт ${myip}:$p занят НЕ Caddy: ${proc:-неизвестно}${unit:+ (сервис $unit)}"
            fi
        else
            echo "  ⚠️  Порт ${myip}:$p никто не слушает$( [ "$p" = 80 ] && echo " (нужен для выпуска сертификата)" )"
        fi
    done

    # 4. Сертификат
    if cert_ready "$host"; then
        echo "  ✅ Сертификат валиден (до $(cert_expiry "$host")) — Caddy продлевает сам"
    else
        echo "  ❌ Сертификат не подтверждён — HTTPS-подписка не работает."
        echo "        Причины: DNS не на этот сервер; закрыт 80/tcp; Caddy лёг; DNS не распространился."
    fi

    # 5. Пиры
    echo "  ── Пиры кластера ──"
    local total=0 okp=0 ph pn
    while IFS='|' read -r pn ph; do
        [ -n "$ph" ] || continue
        [ "$ph" = "$host" ] && continue
        total=$((total + 1))
        if cluster_call "$ph" "/cluster/manifest" >/dev/null 2>&1; then
            echo "  ✅ $pn ($ph) — на связи"; okp=$((okp + 1))
        else
            echo "  ❌ $pn ($ph) — недоступен (DNS/сертификат/секрет/файрвол пира)"
        fi
    done < "$CLUSTER_CONF"
    [ "$total" -eq 0 ] && echo "  ℹ️  Пиров нет (одиночная нода)." \
        || echo "  Итого пиров: $okp из $total на связи"

    # 6. Содержимое подписки (на примере первого юзера)
    local u tok keys
    u=$(head -1 "$USERS_DB" 2>/dev/null | cut -d: -f1)
    if [ -n "$u" ]; then
        tok=$(sub_token_for "$u")
        echo "  ── Подписка юзера «$u» ──"
        if [ -f "$WEBROOT/sub/$tok" ]; then
            keys=$(base64 -d < "$WEBROOT/sub/$tok" 2>/dev/null | grep -c '^hysteria2')
            echo "  Ключей в подписке (со всех нод): ${keys:-0}"
            echo "  Ссылка: $(subscription_url "$u")"
            if [ "$total" -gt 0 ] && [ "${keys:-0}" -le 1 ]; then
                echo "  ⚠️  В подписке только свой ключ при наличии пиров — ключи пиров не подтянулись."
                echo "       Обычно из-за недоступных пиров выше. Почините их и нажмите «Синхронизировать»."
            fi
        else
            echo "  ⚠️  Файл подписки ещё не сгенерирован — нажмите «Синхронизировать»."
        fi
    fi
    echo "  ══════════════════════════════════════════════════════"
}

# Диагностика КОНКРЕТНОГО профиля по кластеру: где есть, онлайн по нодам, токены,
# срок, доступность пиров. Помогает понять, почему профиль где-то не работает.
user_debug() {
    local user="$1"
    echo "  🩺 Диагностика профиля «$user»"
    echo "  ──────────────────────────────────────────────────────"
    if db_user_exists "$user"; then
        echo "  ✅ На этой ноде ($(node_name)): активен"
    elif is_user_disabled "$user"; then
        echo "  ⏸  На этой ноде: ОТКЛЮЧЁН"
    else
        echo "  ❌ На этой ноде: отсутствует"
    fi
    if sub_enabled && is_cluster_user "$user"; then
        echo "  🌐 Тип: кластерный (должен быть на всех нодах)"
    else
        echo "  🔒 Тип: локальный (только эта нода)"
    fi
    local e; e=$(get_user_expiry "$user")
    if [ -n "$e" ]; then echo "  ⏰ Срок: $e ($(format_remaining "$e"))"; else echo "  ⏰ Срок: не задан"; fi

    if ! sub_enabled; then echo "  ⚪ Подписка не настроена."; return 0; fi

    echo "  🔗 Ссылка-подписка: $(subscription_url "$user")"
    local toks
    toks=$( { awk -F: -v u="$user" '$1==u{print $2}' "$SUBTOKENS_DB" 2>/dev/null
              [ -d "$PEERS_DIR" ] && awk -F: -v u="$user" '$1==u{print $2}' "$PEERS_DIR"/*.subtokens 2>/dev/null; } \
            | grep -v '^$' | sort -u )
    echo "  🎫 Токенов в кластере: $(printf '%s\n' "$toks" | grep -c .) (любой работает на любой ноде)"

    echo "  📡 По нодам (онлайн · трафик):"
    local bn bo btx brx
    while IFS=$'\t' read -r bn bo btx brx _ _; do
        echo "     • $bn: онлайн ${bo:-0} · ↑$(format_bytes "$btx")/↓$(format_bytes "$brx")"
    done < <(cluster_user_breakdown "$user")

    if cert_ready "$(node_host)"; then
        echo "  ✅ HTTPS этой ноды работает (сертификат валиден)"
    else
        echo "  ❌ HTTPS этой ноды НЕ работает — подписка по этой ссылке не отдаётся!"
        echo "     Запустите общую Диагностику (Подписка → 8)."
    fi
    local pn ph total=0 bad=0
    while IFS='|' read -r pn ph; do
        [ -n "$ph" ] || continue; [ "$ph" = "$(node_host)" ] && continue
        total=$((total+1))
        if ! cluster_call "$ph" "/cluster/manifest" 3 >/dev/null 2>&1; then
            echo "  ⚠️  Пир «$pn» ($ph) недоступен — его ключ может не попасть в подписку."
            bad=$((bad+1))
        fi
    done < "$CLUSTER_CONF"
    [ "$total" -gt 0 ] && [ "$bad" -eq 0 ] && echo "  ✅ Все пиры на связи."
    [ "$total" -eq 0 ] && echo "  ℹ️  Пиров нет (одиночная нода)."
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

# Указывает ли домен на этот сервер? 0 — да; 1 — резолвится, но не сюда; 2 — не
# резолвится. Учитываем ВСЕ локальные IP (у сервера их может быть несколько).
domain_points_here() {
    local d="$1" ips dip locals
    ips=$(resolve_domain "$d")
    [ -n "$ips" ] || return 2
    locals=$(list_local_ips)
    for dip in $ips; do
        printf '%s\n' "$locals" | grep -qxF "$dip" && return 0
    done
    return 1
}

# Уже выпущен публично-доверенный сертификат для домена? Бьёмся в локальный Caddy
# (--resolve на IP ноды — Caddy может слушать НЕ на 127.0.0.1, а на конкретном IP)
# и проверяем цепочку СИСТЕМНЫМ доверием: внутренний self-signed Caddy не пройдёт,
# настоящий Let's Encrypt/ZeroSSL — пройдёт.
cert_ready() {
    local d="$1" ip
    [ -n "$d" ] || return 1
    ip=$(node_ip)
    curl -sS --max-time 8 --resolve "${d}:443:${ip}" "https://${d}/" -o /dev/null 2>/dev/null \
        || curl -sS --max-time 8 --resolve "${d}:443:127.0.0.1" "https://${d}/" -o /dev/null 2>/dev/null
}

# Дата окончания текущего сертификата (для показа), пусто если нет.
cert_expiry() {
    local d="$1" ip
    command -v openssl >/dev/null 2>&1 || return 0
    ip=$(node_ip)
    { echo | timeout 8 openssl s_client -connect "${ip}:443" -servername "$d" 2>/dev/null \
        || echo | timeout 8 openssl s_client -connect "127.0.0.1:443" -servername "$d" 2>/dev/null; } \
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

# Публикует статистику ЭТОЙ ноды для других нод (за X-Cluster-Auth). По строке
# на юзера: «user<TAB>online<TAB>tx<TAB>rx<TAB>sptx<TAB>sprx». Эти данные пиры
# подмешивают в общекластерные онлайн/трафик/скорость и в разбивку по нодам.
publish_stats() {
    sub_enabled || return 0
    mkdir -p "$WEBROOT/cluster"
    local online tmp="$WEBROOT/cluster/stats.tmp" u oc tl tx rx sp sptx sprx
    online=$(api_get "/online")
    echo "$online" | jq empty 2>/dev/null || online='{}'
    : > "$tmp"
    while IFS=: read -r u _; do
        [ -n "$u" ] || continue
        oc=$(echo "$online" | jq -r --arg x "$u" '.[$x]//0' 2>/dev/null); [[ "$oc" =~ ^[0-9]+$ ]] || oc=0
        tl=$(get_user_traffic "$u"); tx=$(echo "$tl" | cut -d'|' -f2); rx=$(echo "$tl" | cut -d'|' -f3)
        sp=$(get_user_speed "$u");   sptx=$(echo "$sp" | cut -d'|' -f2); sprx=$(echo "$sp" | cut -d'|' -f3)
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$u" "$oc" "${tx:-0}" "${rx:-0}" "${sptx:-0}" "${sprx:-0}" >> "$tmp"
    done < "$USERS_DB"
    mv "$tmp" "$WEBROOT/cluster/stats"
    secure_web_files
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

# Снимок лимитов для скрипта аутентификации (жёсткая проверка). По строке на
# активного юзера: «user|hardcheck|pool_cap|node_cap|cluster_others», где
# cluster_others — подключения на ДРУГИХ нодах (сумма из кэшей пиров). Скрипт
# auth читает файл и решает, пускать ли новое устройство. Права — как у users.db.
write_authlimits() {
    local tmp="${AUTHLIMITS_FILE}.tmp" user hc pc nc others owner group
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
# (персональное кол-во устройств приоритетнее). Без глобальных лимитов принуди-
# тельного кика нет — блокировка лишних устройств делается «жёсткой проверкой»
# на этапе аутентификации. Снимок для auth пишем всегда.
enforce_device_limits() {
    sub_enabled || return 0
    refresh_online          # заполнит CACHED_ONLINE для get_user_online_count
    local online_json="$CACHED_ONLINE"
    [ -z "$online_json" ] && online_json='{}'
    local gpool gnode; gpool=$(get_device_limit); gnode=$(get_node_limit)
    if [ "${gpool:-0}" -gt 0 ] || [ "${gnode:-0}" -gt 0 ] 2>/dev/null; then
        local user localn total
        while IFS= read -r user; do
            [ -n "$user" ] || continue
            localn=$(get_user_online_count "$user")
            [ "${localn:-0}" -gt 0 ] 2>/dev/null || continue   # кикать можем только свои сессии
            total=$(cluster_user_connections "$user")
            if user_over_limit "$user" "$total" "$localn"; then
                api_post "/kick" "[\"$user\"]" &>/dev/null
                echo "$(date '+%F %T') $user: cluster=$total local=$localn pool_cap=$(pool_cap "$user") node_cap=$(node_cap "$user") — кик на $(node_name)" \
                    >> "$DATA_DIR/limit.log" 2>/dev/null
            fi
        done < <(echo "$online_json" | jq -r 'to_entries[] | select(.value>0) | .key' 2>/dev/null)
    fi
    write_authlimits
}
