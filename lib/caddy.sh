#!/bin/bash
# ================================================
# Caddy и сеть: Caddyfile, открытие портов, отчёт о запуске, домен и сертификат.
# Раздаёт /sub/* публично и /cluster/* по X-Cluster-Auth.
# ================================================

# Значение заголовка, безопасное для Caddyfile: кавычки и обратные слэши в нём
# развалили бы парсер, а перевод строки — весь блок. Режем, а не экранируем:
# в URL и параметрах клиентов им делать нечего.
_caddy_hval() { printf '%s' "$1" | tr -d '"\\\n\r'; }

# Пишет Caddyfile под домен ноды и перезагружает Caddy. Идемпотентно.
# /sub/* — публично; /cluster/* — только при заголовке X-Cluster-Auth.
setup_caddy() {
    local domain="$1" secret bak
    [ -n "$domain" ] || domain=$(node_host)
    [ -n "$domain" ] || return 1
    secret=$(cluster_secret)
    mkdir -p "$(dirname "$CADDYFILE")" "$WEBROOT/sub" "$WEBROOT/cluster"

    # Если домен указывает на один из локальных IP — фиксируем его как NODE_IP,
    # чтобы при нескольких IP Caddy сел на нужный (свободный), а не на занятый.
    autoset_node_ip 2>/dev/null || true

    # Если у сервера несколько IP и наш IP — реально локальный, привязываем Caddy
    # ИМЕННО к нему. Тогда другой сервис (nginx и т.п.) на другом IP не мешает.
    #
    # ВМЕСТЕ С LOOPBACK, и это обязательно. `bind <ip>` без 127.0.0.1 означает,
    # что снаружи Caddy отвечает, а изнутри ноды `127.0.0.1:443` мёртв. А это
    # штатный `dest` для REALITY (docs/guide/MULTIPROTOCOL.md): не дозвонившись
    # до dest, REALITY рвёт КАЖДОЕ соединение, при том что порт слушается и
    # сервис активен. То есть один и тот же код одной рукой ставил dest на
    # loopback, а другой — уводил Caddy с loopback, и ломался VLESS целиком,
    # только на нодах с несколькими адресами. См. P-136.
    local bind_ip bind_line=""
    bind_ip=$(node_ip)
    if [ "$(list_local_ips | grep -c .)" -gt 1 ] && list_local_ips | grep -qxF "$bind_ip" 2>/dev/null; then
        bind_line="    bind ${bind_ip} 127.0.0.1"
    fi

    # Оформление подписки: название профиля и интервал обновления — клиенты
    # (Hiddify и др.) читают эти заголовки и показывают их пользователю. Название
    # вынесено в импортируемый сниппет: с плейсхолдерами оно у каждого юзера своё,
    # и его перепекает regen_subscriptions без переписывания Caddyfile.
    local upd
    write_sub_titles >/dev/null
    upd=$(sub_update_hours)

    # Остальные заголовки подписки — общие для всех юзеров: кнопки ссылок и
    # свободный список (SUB_HEADERS: «имя: значение|имя: значение»), через который
    # включается любой параметр клиента без правки кода. Значение в кавычки не
    # берём как есть, а прогоняем через printf %q-безопасный путь: кавычка в
    # значении иначе развалила бы Caddyfile.
    local sub_hdrs="" u
    u=$(sub_support_url);  [ -n "$u" ] && sub_hdrs+="        header support-url \"$(_caddy_hval "$u")\"
"
    u=$(sub_page_url);     [ -n "$u" ] && sub_hdrs+="        header profile-web-page-url \"$(_caddy_hval "$u")\"
"
    u=$(sub_announce_url); [ -n "$u" ] && sub_hdrs+="        header announce-url \"$(_caddy_hval "$u")\"
"
    local hline name val
    while IFS= read -r hline; do
        [ -n "$hline" ] || continue
        name=${hline%%:*}; val=${hline#*:}
        name=$(printf '%s' "$name" | tr -cd 'A-Za-z0-9-')
        val=${val# }
        [ -n "$name" ] && [ -n "$val" ] && sub_hdrs+="        header ${name} \"$(_caddy_hval "$val")\"
"
    done <<< "$(printf '%s' "$(sub_headers_extra)" | tr '|' '\n')"

    # Ссылку-подписку регулярно вставляют не в клиент, а в адресную строку
    # браузера — и человек видел простыню base64. Уводим такой заход на страницу
    # подписки кабинета (SUB_WEB_URL), путь запроса дописывается целиком, так что
    # страница знает токен. Признак браузера — Sec-Fetch-Mode: navigate: его шлёт
    # любой современный браузер при переходе по адресу и не шлёт ни один клиент
    # (они ходят обычным HTTP-запросом за файлом). Подробности и что делать со
    # старыми браузерами — docs/guide/SUB-BROWSER.md.
    local web_url sub_redir=""
    web_url=$(sub_web_url)
    [ -n "$web_url" ] && sub_redir="    @sub_browser {
        path /sub/*
        header Sec-Fetch-Mode navigate
    }
    handle @sub_browser {
        redir \"$(_caddy_hval "$web_url"){uri}\" 302
    }
"

    # Web API для внешних приложений (lib/webapi.sh): когда включён — проксируем
    # /api/* на локальный демон. Блок генерируется здесь, а не дописывается извне:
    # setup_caddy полностью перезаписывает Caddyfile, и внешняя правка потерялась бы.
    # handle_path, а НЕ handle: префикс /api надо снять. Демон знает маршруты
    # как /v1/…, и с обычным handle к нему приходило /api/v1/… — он отвечал
    # «нет такого эндпоинта» на ВСЁ. Локальный потребитель этого не замечал
    # (он ходит прямо на 127.0.0.1), а вот межнодовые вызовы, которые строят
    # адрес как https://<нода>/api/v1/… (wa_core.cluster_request), молча
    # получали 404 — и снаружи Web API ноды не существовало вовсе.
    local api_block=""
    if type -t webapi_enabled >/dev/null 2>&1 && webapi_enabled; then
        api_block="    handle_path /api/* {
        reverse_proxy 127.0.0.1:$(webapi_port)
    }"
    fi

    # Чужие вирт-хосты (мини-апп, редирект основного домена) живут отдельными
    # файлами и подключаются import'ом: setup_caddy переписывает Caddyfile
    # целиком, и блок, дописанный руками В САМ файл, потерялся бы при первой же
    # смене домена ноды. Импорт добавляем только когда файлы есть — Caddy падает
    # на глобе, который ничего не нашёл.
    local extra_block=""
    if compgen -G "${CADDY_EXTRA_DIR}/*.caddy" >/dev/null 2>&1; then
        extra_block="import ${CADDY_EXTRA_DIR}/*.caddy
"
    fi

    # Бэкап текущего конфига — чтобы при ошибке не уронить уже работающий Caddy.
    bak=""
    [ -f "$CADDYFILE" ] && { bak=$(mktemp); cp -f "$CADDYFILE" "$bak"; }

    # ВАЖНО: каждый блок — на отдельных строках; «{» обязана быть последним
    # токеном строки, иначе Caddy не парсит конфиг и не стартует. handle-блоки
    # взаимоисключающие и проверяются в порядке записи.
    cat > "$CADDYFILE" <<EOF
${extra_block}${domain} {
    root * ${WEBROOT}
${bind_line}
    log {
        output stderr
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
${api_block}
${sub_redir}    handle /sub/* {
        header Content-Type "text/plain; charset=utf-8"
        import ${CADDY_SUBTITLES}
        header profile-update-interval "${upd}"
${sub_hdrs}        file_server
    }
    handle {
        respond "Subscription endpoint. Open your personal /sub/<token> URL inside a client app (Hiddify, Nekobox, sing-box) as a subscription - not in a browser." 200
    }
}
EOF
    # Caddyfile содержит СЕКРЕТ КЛАСТЕРА открытым текстом (матчер @cluster_auth).
    # Сам cluster.secret лежит 600, а этот файл создавался по umask — 0644, то
    # есть секрет читал любой локальный процесс: www-data под php-fpm кабинета,
    # hysteria, caddy. А знание секрета — это доступ ко всем разделам обмена всех
    # нод, включая манифест с паролями юзеров. Отдаём чтение только группе Caddy
    # (он работает под своим пользователем и конфиг читает уже под ним). См. P-135.
    local cg=root; id caddy >/dev/null 2>&1 && cg=caddy
    chown "root:${cg}" "$CADDYFILE" 2>/dev/null || true
    chmod 640 "$CADDYFILE" 2>/dev/null || true
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

# Разовая миграция: до 4.26.123 блок прокси стоял на «handle /api/*», который
# префикс НЕ снимает, и Web API ноды снаружи не отвечал ни на один запрос.
# Отдельной миграцией, потому что самовосстановление в hy2-manager.sh чинит
# только ЛЕЖАЩИЙ или БИТЫЙ конфиг, а этот валиден — он просто неправильный.
# Идемпотентна: смотрит ровно на старую форму блока и молчит, если её нет.
migrate_caddy_api_prefix() {
    sub_enabled || return 0
    [ -f "$CADDYFILE" ] || return 0
    grep -qE '^[[:space:]]*handle /api/\*' "$CADDYFILE" 2>/dev/null || return 0
    setup_caddy >/dev/null 2>&1
}

# Разовая миграция: `bind <ip>` без loopback. На ноде с несколькими адресами
# Caddy садился только на публичный, и `127.0.0.1:443` — штатный dest REALITY —
# был мёртв изнутри. Снаружи при этом всё отвечало, порт VLESS слушался, сервис
# был активен: отказ выглядел как «ключ не работает» без единой зацепки (P-136).
#
# Условие сформулировано как «НЕТ нужного», а не «есть плохое»: проверяем
# отсутствие 127.0.0.1 в строке bind, а не конкретную старую форму. Так
# миграция не промахнётся мимо ноды с чуть иным написанием — ровно та ошибка,
# из-за которой migrate_caddy_api_prefix молча пропускала свои цели (P-133).
# Терминируется сама: после регенерации 127.0.0.1 в строке есть.
migrate_caddy_bind_loopback() {
    sub_enabled || return 0
    [ -f "$CADDYFILE" ] || return 0
    local line
    line=$(grep -E '^[[:space:]]*bind[[:space:]]' "$CADDYFILE" 2>/dev/null | head -1)
    [ -n "$line" ] || return 0                      # bind нет вовсе — Caddy на всех адресах
    printf '%s' "$line" | grep -q '127\.0\.0\.1' && return 0
    setup_caddy >/dev/null 2>&1
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
        echo "  ❌ Caddyfile невалиден — пересоберите (Подписка → 1)"
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

