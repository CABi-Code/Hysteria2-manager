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
    get_ip
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
    ip=$(link_host); port=$(get_port); obfs=$(get_obfs_pass); sni=$(get_sni)
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

    # Бэкап текущего конфига — чтобы при ошибке не уронить уже работающий Caddy.
    bak=""
    [ -f "$CADDYFILE" ] && { bak=$(mktemp); cp -f "$CADDYFILE" "$bak"; }

    # ВАЖНО: каждый блок — на отдельных строках; «{» обязана быть последним
    # токеном строки, иначе Caddy не парсит конфиг и не стартует. handle-блоки
    # взаимоисключающие и проверяются в порядке записи.
    cat > "$CADDYFILE" <<EOF
${domain} {
    root * ${WEBROOT}

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

# Слушается ли TCP-порт локально (Caddy на 80/443).
port_listening() {
    local p="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | grep -qE ":${p}[[:space:]]"
    elif command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | grep -qE ":${p}[[:space:]]"
    else
        return 0
    fi
}

# Кто слушает TCP-порт. Печатает «процесс|pid|unit» (любое поле может быть пустым).
# Требует root (ss -p) — менеджер работает от root.
port_holder() {
    local p="$1" line proc pid unit
    command -v ss >/dev/null 2>&1 || { printf '||'; return; }
    line=$(ss -ltnp 2>/dev/null | awk -v p=":$p" '$4 ~ (p"$"){print; exit}')
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
            local cp; cp=$(printf '%s' "$reason" | grep -oE ':(80|443)\b' | tr -d ':' | head -1)
            [ -z "$cp" ] && cp=443
            local h proc pid unit; h=$(port_holder "$cp")
            proc=${h%%|*}; pid=$(printf '%s' "$h" | cut -d'|' -f2); unit=${h##*|}
            echo "     ⛔ Порт $cp/tcp уже занят: ${proc:-неизвестный процесс}${pid:+ (pid $pid)}${unit:+, сервис: $unit}"
            if [ -n "$unit" ]; then
                echo "     Освободить порт: systemctl stop $unit   (или смените порт у того сервиса)"
                DIAG_CONFLICT_UNIT="$unit"; DIAG_CONFLICT_PORT="$cp"; DIAG_CONFLICT_PROC="$proc"
            else
                echo "     Найдите процесс: ss -ltnp | grep :$cp   и освободите порт."
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
    host=$(node_host); myip=$(get_ip)
    echo "  Нода «$(node_name)» · домен $host · IP сервера $myip"
    echo ""

    # 1. DNS
    ips=$(resolve_domain "$host")
    if [ -z "$ips" ]; then
        echo "  ❌ DNS: $host не резолвится. Нужна A-запись $host → $myip."
    elif printf '%s\n' "$ips" | grep -qxF "$myip"; then
        echo "  ✅ DNS: $host → $myip (этот сервер)"
    else
        echo "  ❌ DNS: $host → $(printf '%s' "$ips" | tr '\n' ' ')(НЕ этот сервер $myip)"
        echo "        Похоже на CDN/прокси (Akamai/Cloudflare). Нужна ПРЯМАЯ A-запись на $myip,"
        echo "        без проксирования — иначе Let's Encrypt не подтвердит домен."
    fi

    # 2. Caddy: проверяем, при необходимости включаем/запускаем, объясняем сбой.
    echo "  ── Caddy ──"
    caddy_start_report

    # 3. Порты — кто реально слушает (и не мешает ли кто-то Caddy).
    echo "  ── Порты ──"
    local p
    for p in 80 443; do
        if port_listening "$p"; then
            local h proc unit
            h=$(port_holder "$p"); proc=${h%%|*}; unit=${h##*|}
            if printf '%s' "$proc" | grep -qi caddy; then
                echo "  ✅ Порт $p/tcp слушает Caddy"
            else
                echo "  ⚠️  Порт $p/tcp занят НЕ Caddy: ${proc:-неизвестно}${unit:+ (сервис $unit)}"
            fi
        else
            echo "  ⚠️  Порт $p/tcp никто не слушает$( [ "$p" = 80 ] && echo " (нужен для выпуска сертификата)" )"
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
