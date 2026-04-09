#!/bin/bash
# ================================================
# Онлайн-статус пользователей через API
# ================================================

refresh_online() {
    CACHED_ONLINE=$(api_get "/online")
}

get_user_online_count() {
    echo "${CACHED_ONLINE:-{}}" | jq -r ".[\"${1}\"] // 0" 2>/dev/null || echo "0"
}
