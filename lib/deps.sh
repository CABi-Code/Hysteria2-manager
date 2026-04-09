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
    mkdir -p "$DATA_DIR"
    for f in "$STATS_FILE" "$IPS_FILE" "$EXPIRY_FILE" "$DISABLED_FILE"; do
        [ -f "$f" ] || touch "$f"
    done
}
