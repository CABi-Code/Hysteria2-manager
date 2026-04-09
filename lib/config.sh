#!/bin/bash
# ================================================
# Конфигурация и чтение данных из config.yaml
# ================================================

CONFIG="/etc/hysteria/config.yaml"
SERVICE="hysteria-server.service"
DATA_DIR="/etc/hysteria/manager"
STATS_FILE="$DATA_DIR/stats.dat"
IPS_FILE="$DATA_DIR/ips.dat"
EXPIRY_FILE="$DATA_DIR/expiry.dat"
DISABLED_FILE="$DATA_DIR/disabled.dat"
LAST_LOG_TS="$DATA_DIR/last_log_ts"
API_SECRET_FILE="$DATA_DIR/api_secret"
API_PORT=25580
PAGE_SIZE=10

get_ip() {
    curl -4s --max-time 5 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}'
}

get_port() {
    grep -oP '(?<=listen: :)\d+' "$CONFIG" 2>/dev/null || echo "11478"
}

get_obfs_pass() {
    grep -oP '(?<=password: ")[^"]+' <(grep -A 5 "salamander:" "$CONFIG") 2>/dev/null | head -1
}

get_sni() {
    grep -oP '(?<=url: https://)[^/]+' "$CONFIG" 2>/dev/null | head -1 || echo "www.microsoft.com"
}

get_user_password() {
    grep -oP "^    ${1}:\s*\"\K[^\"]*" "$CONFIG" 2>/dev/null
}

get_active_users() {
    awk '
        /^  userpass:/ { in_block=1; next }
        in_block && /^    [a-zA-Z0-9_-]+:/ {
            sub(/^[ \t]+/, "")
            sub(/:.*/, "")
            print
        }
        in_block && /^  [a-zA-Z]/ { in_block=0 }
        in_block && /^[a-zA-Z]/ { in_block=0 }
    ' "$CONFIG" 2>/dev/null
}

get_all_users() {
    {
        get_active_users
        cut -d'|' -f1 "$DISABLED_FILE" 2>/dev/null
    } | grep -v '^$' | sort -u
}
