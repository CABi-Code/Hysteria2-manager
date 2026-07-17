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
    # Подмешиваем онлайн доп. протоколов (VLESS/SS2022/TUIC), суммируя по юзеру.
    # best-effort: при выключенных протоколах или сбое — CACHED_ONLINE не меняется.
    if declare -F proto_online_json >/dev/null 2>&1 && proto_any_enabled; then
        local _po
        _po=$(proto_online_json 2>/dev/null)
        if [ -n "$_po" ] && [ "$_po" != '{}' ]; then
            CACHED_ONLINE=$(_proto_merge_online "$CACHED_ONLINE" "$_po")
        fi
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
