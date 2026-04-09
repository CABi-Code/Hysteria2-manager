#!/bin/bash
# ================================================
# Управление пользователями: CRUD-операции
# ================================================

is_user_disabled() {
    grep -q "^${1}|" "$DISABLED_FILE" 2>/dev/null
}

get_disabled_password() {
    grep "^${1}|" "$DISABLED_FILE" 2>/dev/null | head -1 | cut -d'|' -f2
}

disable_user() {
    local user="$1" silent="$2"
    local password
    password=$(get_user_password "$user")
    if [ -z "$password" ]; then
        [ "$silent" != "silent" ] && echo "  ❌ Пользователь $user не найден в конфиге"
        return 1
    fi
    grep -q "^${user}|" "$DISABLED_FILE" || echo "${user}|${password}" >> "$DISABLED_FILE"
    sed -i "/^    ${user}: \"/d" "$CONFIG"
    api_post "/kick" "[\"$user\"]" &>/dev/null
    [ "$silent" != "silent" ] && echo "  ✅ Пользователь $user отключён"
}

enable_user() {
    local user="$1"
    if ! is_user_disabled "$user"; then
        echo "  ❌ $user не в списке отключённых"
        return 1
    fi
    local password
    password=$(get_disabled_password "$user")
    sed -i "/^  userpass:/a\\    ${user}: \"${password}\"" "$CONFIG"
    sed -i "/^${user}|/d" "$DISABLED_FILE"
    echo "  ✅ Пользователь $user включён"
}

delete_user() {
    local user="$1"
    sed -i "/^    ${user}: \"/d" "$CONFIG"
    sed -i "/^${user}|/d" "$DISABLED_FILE" "$STATS_FILE" "$IPS_FILE" "$EXPIRY_FILE"
    api_post "/kick" "[\"$user\"]" &>/dev/null
    echo "  ✅ Пользователь $user полностью удалён"
}

reset_user_stats() {
    local user="$1"
    sed -i "/^${user}|/d" "$STATS_FILE" "$IPS_FILE"
    echo "  ✅ Статистика $user сброшена"
}

change_user_password() {
    local user="$1"
    local new_pass
    new_pass=$(pwgen -s 64 1)
    if is_user_disabled "$user"; then
        sed -i "s#^${user}|.*#${user}|${new_pass}#" "$DISABLED_FILE"
    else
        if ! grep -q "^    ${user}: " "$CONFIG"; then
            echo "  ❌ Пользователь не найден"
            return 1
        fi
        sed -i "/^    ${user}: \"/d" "$CONFIG"
        sed -i "/^  userpass:/a\\    ${user}: \"${new_pass}\"" "$CONFIG"
    fi
    echo "  ✅ Пароль $user обновлён"
    echo "  🔑 Новый: ${new_pass}"
}
