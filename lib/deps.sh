#!/bin/bash
# ================================================
# Проверка зависимостей и инициализация
# ================================================

check_deps() {
    for cmd in pwgen jq; do
        if ! command -v "$cmd" &>/dev/null; then
            echo "📦 Устанавливаю $cmd..."
            apt update -qq && apt install -y "$cmd" -qq
        fi
    done
}

init_data_dir() {
    mkdir -p "$DATA_DIR" "$PEERS_DIR"
    for f in "$STATS_FILE" "$IPS_FILE" "$EXPIRY_FILE" "$EXPIRY_TS_FILE" "$DISABLED_FILE" "$SPEED_FILE" "$USERS_DB" "$SUBTOKENS_DB" "$CLUSTER_STATE_FILE"; do
        [ -f "$f" ] || touch "$f"
    done
}

# Установка Caddy (нужен только для подписки — ставим при её настройке, а не на
# каждом старте). Возвращает 0, если caddy доступен.
ensure_caddy() {
    command -v caddy &>/dev/null && return 0
    echo "📦 Устанавливаю Caddy (нужен для HTTPS-подписки)..."
    apt install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl gnupg &>/dev/null
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        > /etc/apt/sources.list.d/caddy-stable.list 2>/dev/null
    apt update -qq && apt install -y -qq caddy
    systemctl enable caddy &>/dev/null || true
    command -v caddy &>/dev/null
}
