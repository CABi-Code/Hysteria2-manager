#!/bin/bash
# ================================================
# Сбор и отображение трафика пользователей
# ================================================

collect_traffic() {
    local response
    response=$(api_get "/traffic?clear=1")
    [ -z "$response" ] || [ "$response" = "null" ] && return

    echo "$response" | jq -r 'to_entries[] | "\(.key)|\(.value.tx // 0)|\(.value.rx // 0)"' 2>/dev/null | \
    while IFS='|' read -r user tx rx; do
        [ -z "$user" ] && continue
        tx=${tx:-0}; rx=${rx:-0}
        [[ "$tx" =~ ^[0-9]+$ ]] || tx=0
        [[ "$rx" =~ ^[0-9]+$ ]] || rx=0
        [ "$tx" -eq 0 ] && [ "$rx" -eq 0 ] && continue

        if grep -q "^${user}|" "$STATS_FILE"; then
            local old_tx old_rx new_tx new_rx
            old_tx=$(grep "^${user}|" "$STATS_FILE" | head -1 | cut -d'|' -f2)
            old_rx=$(grep "^${user}|" "$STATS_FILE" | head -1 | cut -d'|' -f3)
            new_tx=$(( ${old_tx:-0} + tx ))
            new_rx=$(( ${old_rx:-0} + rx ))
            sed -i "s#^${user}|.*#${user}|${new_tx}|${new_rx}#" "$STATS_FILE"
        else
            echo "${user}|${tx}|${rx}" >> "$STATS_FILE"
        fi
    done
}

get_user_traffic() {
    local line
    line=$(grep "^${1}|" "$STATS_FILE" 2>/dev/null | head -1)
    if [ -n "$line" ]; then
        echo "$line"
    else
        echo "${1}|0|0"
    fi
}

format_bytes() {
    local bytes=${1:-0}
    [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
    if [ "$bytes" -ge 1073741824 ]; then
        awk "BEGIN {printf \"%.1fG\", $bytes / 1073741824}"
    elif [ "$bytes" -ge 1048576 ]; then
        awk "BEGIN {printf \"%.1fM\", $bytes / 1048576}"
    elif [ "$bytes" -ge 1024 ]; then
        awk "BEGIN {printf \"%.1fK\", $bytes / 1024}"
    else
        echo "${bytes}B"
    fi
}
