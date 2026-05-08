#!/bin/bash
# ================================================
# Онлайн-статус пользователей через API
# ================================================

refresh_online() {
    CACHED_ONLINE=$(api_get "/online")
    # Если API недоступен или ответ невалиден — подставляем пустой объект
    if [ -z "$CACHED_ONLINE" ] || ! echo "$CACHED_ONLINE" | jq empty 2>/dev/null; then
        CACHED_ONLINE='{}'
    fi
}

get_user_online_count() {
    local json="${CACHED_ONLINE:-}"
    [ -z "$json" ] && json='{}'
    local count
    count=$(echo "$json" | jq -r --arg u "$1" '.[$u] // 0' 2>/dev/null)
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    echo "$count"
}
