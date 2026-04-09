#!/bin/bash
# ================================================
# Функции работы с Hysteria 2 API (trafficStats)
# ================================================

get_api_secret() {
    [ -f "$API_SECRET_FILE" ] && cat "$API_SECRET_FILE"
}

setup_stats_api() {
    if ! grep -q '^trafficStats:' "$CONFIG" 2>/dev/null; then
        local secret
        secret=$(pwgen -s 32 1)
        echo "$secret" > "$API_SECRET_FILE"
        chmod 600 "$API_SECRET_FILE"
        {
            echo ""
            echo "trafficStats:"
            echo "  listen: 127.0.0.1:$API_PORT"
            echo "  secret: $secret"
        } >> "$CONFIG"
        systemctl restart "$SERVICE" 2>/dev/null
        sleep 2
    else
        local secret port
        secret=$(awk '/^trafficStats:/,/^[a-zA-Z]/' "$CONFIG" | grep -oP 'secret:\s*\K\S+' | tr -d '"' | head -1)
        port=$(awk '/^trafficStats:/,/^[a-zA-Z]/' "$CONFIG" | grep 'listen' | grep -oP '\d+' | tail -1)
        [ -n "$secret" ] && echo "$secret" > "$API_SECRET_FILE" && chmod 600 "$API_SECRET_FILE"
        [ -n "$port" ] && API_PORT="$port"
    fi
}

api_get() {
    local secret
    secret=$(get_api_secret)
    curl -s --max-time 3 -H "Authorization: $secret" "http://127.0.0.1:${API_PORT}${1}" 2>/dev/null
}

api_post() {
    local secret
    secret=$(get_api_secret)
    curl -s --max-time 3 -X POST -H "Authorization: $secret" \
        -H "Content-Type: application/json" -d "$2" \
        "http://127.0.0.1:${API_PORT}${1}" 2>/dev/null
}
