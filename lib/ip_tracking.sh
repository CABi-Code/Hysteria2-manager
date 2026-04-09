#!/bin/bash
# ================================================
# IP-трекинг: сбор и анализ IP-адресов пользователей
# ================================================

collect_ips() {
    local since_opt=""
    if [ -f "$LAST_LOG_TS" ]; then
        since_opt="--since=$(cat "$LAST_LOG_TS")"
    else
        since_opt="--since=30 days ago"
    fi
    date '+%Y-%m-%d %H:%M:%S' > "$LAST_LOG_TS"

    journalctl -u "$SERVICE" --no-pager -o cat $since_opt 2>/dev/null | \
    grep -E '"(addr|remote|client)"' | grep -E '"username"' | \
    while read -r line; do
        local ip user
        ip=$(echo "$line" | grep -oP '"(?:addr|remote|client)"\s*:\s*"\K[\d.]+' | head -1)
        user=$(echo "$line" | grep -oP '"username"\s*:\s*"\K[^"]+' | head -1)
        [ -z "$ip" ] || [ -z "$user" ] || [ "$ip" = "127.0.0.1" ] && continue

        local now
        now=$(date +%s)
        if grep -q "^${user}|${ip}|" "$IPS_FILE"; then
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
    grep -c "^${1}|" "$IPS_FILE" 2>/dev/null || echo "0"
}

get_user_ips() {
    grep "^${1}|" "$IPS_FILE" 2>/dev/null
}
