#!/bin/bash
# ================================================
# IP-трекинг: сбор и анализ IP-адресов пользователей
# ================================================

collect_ips() {
    local since_ts=""
    if [ -f "$LAST_LOG_TS" ] && [ -s "$LAST_LOG_TS" ]; then
        since_ts=$(cat "$LAST_LOG_TS")
    else
        since_ts=$(date -d '30 days ago' '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "30 days ago")
    fi
    date '+%Y-%m-%d %H:%M:%S' > "$LAST_LOG_TS"

    # ВАЖНО: Hysteria 2 (auth.type: command) логирует подключение строкой
    #   ... msg":"client connected" ... "addr":"<IP>:<порт>" ... "id":"<user>"
    # Поля «username» в логе НЕТ — раньше тут грепали именно его, поэтому IP
    # НИКОГДА не собирались («IP-адресов нет» в карточке). Берём пару addr+id из
    # событий подключения. «client disconnected» исключаем (это не новый коннект).
    journalctl -u "$SERVICE" --no-pager -o cat --since="$since_ts" 2>/dev/null | \
    grep -F 'client connected' | \
    while IFS= read -r line; do
        local ip user now
        # addr/remote/client — на разных версиях по-разному; берём IPv4 до «:».
        ip=$(printf '%s' "$line" | grep -oP '"(?:addr|remote|client)"\s*:\s*"\K[0-9.]+' | head -1)
        # id (имя из auth-скрипта); username — на случай иного формата лога.
        user=$(printf '%s' "$line" | grep -oP '"(?:id|username)"\s*:\s*"\K[^"]+' | head -1)
        if [ -z "$ip" ] || [ -z "$user" ] || [ "$ip" = "127.0.0.1" ]; then
            continue
        fi

        now=$(date +%s)
        if grep -q "^${user}|${ip}|" "$IPS_FILE" 2>/dev/null; then
            local old_line first_seen old_count new_count
            old_line=$(grep "^${user}|${ip}|" "$IPS_FILE" | head -1)
            first_seen=$(echo "$old_line" | cut -d'|' -f3)
            old_count=$(echo "$old_line" | cut -d'|' -f5)
            new_count=$(( ${old_count:-0} + 1 ))
            sed -i "s#^${user}|${ip}|.*#${user}|${ip}|${first_seen}|${now}|${new_count}#" "$IPS_FILE"
        else
            echo "${user}|${ip}|${now}|${now}|1" >> "$IPS_FILE"
        fi
    done
}

get_user_ip_count() {
    local count
    count=$(grep -c "^${1}|" "$IPS_FILE" 2>/dev/null || true)
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    echo "$count"
}

get_user_ips() {
    grep "^${1}|" "$IPS_FILE" 2>/dev/null
}

# Собирает IP, скачавшие подписку по КОНКРЕТНОМУ токену, из access-лога Caddy
# (JSON). Нужно для счётчика «IP за неделю» по каждой доп. ссылке. Инкрементально:
# берём только записи новее метки SUBLOG_TS. Формат SUBIPS_FILE — как IPS_FILE:
# «token|ip|first|last|count». Пишем время в секундах (floor от .ts Caddy).
collect_sub_ips() {
    [ -f "$CADDY_ACCESS_LOG" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    touch "$SUBIPS_FILE" 2>/dev/null
    local since maxts parsed ts ip uri token old first count new
    since=$(cat "$SUBLOG_TS" 2>/dev/null); [[ "$since" =~ ^[0-9]+$ ]] || since=0

    # jq: только запросы к /sub/*, новее метки. remote_ip (новые Caddy) или
    # remote_addr «ip:port» (старые). Печатаем «секунды<TAB>ip<TAB>uri».
    parsed=$(jq -r --argjson since "$since" '
        select(.request?.uri != null)
        | select(.request.uri | startswith("/sub/"))
        | select(((.ts // 0) | floor) > $since)
        | [ ((.ts // 0) | floor | tostring),
            (.request.remote_ip // ((.request.remote_addr // "") | split(":")[0]) // ""),
            (.request.uri) ] | @tsv
    ' "$CADDY_ACCESS_LOG" 2>/dev/null)
    [ -n "$parsed" ] || return 0

    maxts="$since"
    while IFS=$'\t' read -r ts ip uri; do
        [ -n "$ip" ] || continue
        [ "$ip" = "127.0.0.1" ] && continue
        [[ "$ts" =~ ^[0-9]+$ ]] || continue
        token="${uri#/sub/}"; token="${token%%\?*}"; token="${token%%/*}"
        [[ "$token" =~ ^[A-Za-z0-9]+$ ]] || continue
        if grep -q "^${token}|${ip}|" "$SUBIPS_FILE" 2>/dev/null; then
            old=$(grep "^${token}|${ip}|" "$SUBIPS_FILE" | head -1)
            first=$(echo "$old" | cut -d'|' -f3)
            count=$(echo "$old" | cut -d'|' -f5)
            new=$(( ${count:-0} + 1 ))
            sed -i "s#^${token}|${ip}|.*#${token}|${ip}|${first}|${ts}|${new}#" "$SUBIPS_FILE"
        else
            echo "${token}|${ip}|${ts}|${ts}|1" >> "$SUBIPS_FILE"
        fi
        [ "$ts" -gt "$maxts" ] 2>/dev/null && maxts="$ts"
    done <<< "$parsed"
    echo "$maxts" > "$SUBLOG_TS"
}
