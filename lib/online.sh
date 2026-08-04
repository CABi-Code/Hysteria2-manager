#!/bin/bash
# ================================================
# Онлайн-статус пользователей через API
# ================================================

# Онлайн юзера = число РАЗНЫХ адресов, с которых он сейчас в сети, а не сумма
# сессий по протоколам: клиент для замера латентности держит подписку на всех
# протоколах сразу, и один телефон виден и в Hysteria, и в Xray, и в TUIC — с
# одного и того же IP. Поэтому собираем со всех протоколов строки «user|ip» и
# считаем уникальные (см. docs/guide/ONLINE.md).
# Как часто реально опрашивать протоколы (сек). Экраны TUI перерисовываются
# каждые REFRESH_INTERVAL=2 с и на каждой перерисовке звали refresh_online, а он
# спрашивает Xray ПО ЮЗЕРУ — десятки процессов на опрос. Забытое открытым меню
# съедало на ноде полъядра просто так. Кэш живёт В ПАМЯТИ процесса: у крона
# каждый прогон — новый процесс, для него первый вызов всегда настоящий, поэтому
# на свежести кластерных данных это не сказывается. `refresh_online force` —
# опросить немедленно (после действия, меняющего сессии).
ONLINE_TTL_SEC="${ONLINE_TTL_SEC:-5}"

refresh_online() {   # [force]
    local hy
    # SECONDS — встроенный счётчик bash, на проверку кэша не уходит ни одного форка.
    if [ "${1:-}" != "force" ] && [ -n "${CACHED_ONLINE:-}" ] \
       && [ $((SECONDS - ${_ONLINE_AT:--999})) -lt "$ONLINE_TTL_SEC" ]; then
        return 0
    fi
    _ONLINE_AT=$SECONDS
    hy=$(api_get "/online")
    { [ -n "$hy" ] && echo "$hy" | jq empty 2>/dev/null; } || hy='{}'
    # Уникальные пары «user|ip» держим отдельно: их публикует publish_stats, чтобы
    # соседние ноды могли отличить ОДНО устройство, засветившееся у нескольких
    # нод, от нескольких разных (cluster_user_connections). Раньше наружу уходил
    # только счётчик, и такое устройство считалось за столько, на скольких нодах
    # его видели (P-45).
    CACHED_ONLINE_IPS=$(
        {
            _online_hysteria_ip_lines "$hy"
            declare -F proto_online_ip_lines >/dev/null 2>&1 && proto_online_ip_lines 2>/dev/null
        } | awk -F'|' 'NF>=2 && $1!="" && $2!="" && !seen[$1"|"$2]++ {print $1"|"$2}'
    )
    CACHED_ONLINE=$(
        printf '%s\n' "$CACHED_ONLINE_IPS" | awk -F'|' '
            NF>=2 && $1!="" && $2!="" {
                if ($2 == "?") { ph[$1]=1; next }          # адрес неизвестен — см. ниже
                if (!seen[$1"|"$2]++) c[$1]++
            }
            END {
                for (u in ph) if (!(u in c)) c[u]=1        # сессия есть, IP не нашли → 1
                for (u in c) printf "%s|%d\n", u, c[u]
            }' \
          | jq -Rc -n '[inputs | split("|") | select(length == 2)
                        | {(.[0]): (.[1] | tonumber)}] | add // {}' 2>/dev/null
    )
    [ -n "$CACHED_ONLINE" ] || CACHED_ONLINE='{}'
}

# Адреса, с которых юзер сейчас в сети НА ЭТОЙ ноде (по строке на адрес).
# «?» означает «сессия есть, адрес не определён» — такую нельзя схлопывать с
# чужими, см. _online_tokens.
get_user_online_ips() {   # user
    printf '%s\n' "${CACHED_ONLINE_IPS:-}" | awk -F'|' -v u="$1" '$1==u && $2!=""{print $2}'
}

# Адреса Hysteria-сессий: своего API с IP у Hysteria нет, но auth-скрипт пишет
# «user|ip|ts» в authmap.dat на КАЖДОЕ подключение. Берём столько последних
# РАЗНЫХ адресов юзера, сколько у него сейчас сессий по /online: одно устройство
# с тремя QUIC-сессиями даст три записи с одним IP и схлопнется в одно.
# Если записей нет вовсе (свежая нода, потерянный файл) — отдаём «user|?»:
# refresh_online засчитает такому юзеру одно устройство, а не ноль.
_online_hysteria_ip_lines() {   # json {user: conns}
    local user n ips
    while IFS='|' read -r user n; do
        [ -n "$user" ] || continue
        [ "${n:-0}" -gt 0 ] 2>/dev/null || continue
        ips=$(awk -F'|' -v u="$user" -v lim="$n" '
                $1==u && $2!="" { a[++total]=$2 }
                END { for (i=total; i>0 && k<lim; i--) if (!s[a[i]]++) { print u "|" a[i]; k++ } }
              ' "$AUTHMAP_FILE" 2>/dev/null)
        [ -n "$ips" ] && echo "$ips" || printf '%s|?\n' "$user"
    done < <(echo "$1" | jq -r '
                to_entries[] | select(.value > 0)
                # id слота — «юзер.<8 hex>» (sub_token_slotid). Схлопываем в юзера:
                # снаружи слоты не существуют, весь учёт ведётся по имени.
                | (.key | sub("\\.[0-9a-f]{8}$"; "")) as $u
                | "\($u)|\(.value)"' 2>/dev/null \
             | awk -F'|' '{n[$1]+=$2} END{for(u in n) print u"|"n[u]}')
}

get_user_online_count() {
    local json="${CACHED_ONLINE:-}"
    [ -z "$json" ] && json='{}'
    local count
    count=$(echo "$json" | jq -r --arg u "$1" '.[$u] // 0' 2>/dev/null)
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    echo "$count"
}

# Общий онлайн ЭТОЙ ноды: сколько юзеров сейчас с активными подключениями.
# Та же метрика, что «онлайн: N» в главном меню (hy2-manager.sh). Используется
# как значение плейсхолдера {online} в подписи ключа — индикатор загрузки ноды.
# Требует свежего CACHED_ONLINE (refresh_online).
node_online_count() {
    local json="${CACHED_ONLINE:-}"
    [ -z "$json" ] && json='{}'
    local count
    count=$(echo "$json" | jq 'to_entries | map(select(.value > 0)) | length' 2>/dev/null | tr -dc '0-9')
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    echo "$count"
}
