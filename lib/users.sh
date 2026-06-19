#!/bin/bash
# ================================================
# Управление пользователями: CRUD-операции
# ================================================

# Имена, которые конфликтуют с YAML-ключами Hysteria 2 — нельзя использовать как username,
# иначе sed-операции порушат другие секции конфига.
is_reserved_username() {
    case "$1" in
        type|userpass|password|proxy|url|listen|tls|cert|key|auth|masquerade|obfs|salamander|quic|trafficStats|secret|rewriteHost)
            return 0 ;;
        *)
            return 1 ;;
    esac
}

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
    sed -i "/^[[:space:]]*${user}:[[:space:]]/d" "$CONFIG"
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

    if ! grep -q '^[[:space:]]*userpass:' "$CONFIG"; then
        echo "  ❌ Секция userpass не найдена в конфиге!"
        return 1
    fi

    sed -i "/^[[:space:]]*userpass:/a\\    ${user}: \"${password}\"" "$CONFIG"

    if ! grep -q "^    ${user}: " "$CONFIG"; then
        echo "  ❌ Ошибка записи в конфиг! Пользователь не восстановлен."
        return 1
    fi

    sed -i "/^${user}|/d" "$DISABLED_FILE"
    echo "  ✅ Пользователь $user включён"
}

delete_user() {
    local user="$1"
    sed -i "/^[[:space:]]*${user}:[[:space:]]/d" "$CONFIG"
    sed -i "/^${user}|/d" "$DISABLED_FILE" "$STATS_FILE" "$IPS_FILE" "$EXPIRY_FILE"
    api_post "/kick" "[\"$user\"]" &>/dev/null
    echo "  ✅ Пользователь $user полностью удалён"
}

reset_user_stats() {
    local user="$1"
    sed -i "/^${user}|/d" "$STATS_FILE" "$IPS_FILE"
    echo "  ✅ Статистика $user сброшена"
}

# Генерирует клиентский конфиг (JSON) для sing-box и сохраняет его во
# временный файл. Путь к файлу печатается в stdout (пустой вывод = ошибка).
# Файл создаётся через mktemp с правами 0600 — пароль виден только владельцу.
# JSON собирается через jq, поэтому спецсимволы в пароле/обфускации корректно
# экранируются. Структура — inbounds (mixed) + outbound type "hysteria2";
# подходит для sing-box (sing-box -C config.json check/run).
generate_user_config() {
    local user="$1"
    local pass
    if is_user_disabled "$user"; then
        pass=$(get_disabled_password "$user")
    else
        pass=$(get_user_password "$user")
    fi
    [ -z "$pass" ] && return 1

    local tmpfile
    tmpfile=$(mktemp "/tmp/sb-${user}.XXXXXX.json") || return 1

    # Аутентификация Hysteria 2 в режиме userpass — строка "user:pass".
    # В sing-box она передаётся в поле password у outbound hysteria2.
    # Блок obfs добавляется только если задан salamander-пароль.
    jq -n \
        --arg server "$CACHED_IP" \
        --argjson port "${CACHED_PORT:-443}" \
        --arg auth "${user}:${pass}" \
        --arg sni "$CACHED_SNI" \
        --arg obfs "$CACHED_OBFS" \
        '{
            log: { level: "info", timestamp: true },
            inbounds: [
                { type: "mixed", tag: "mixed-in", listen: "127.0.0.1", listen_port: 1080 }
            ],
            outbounds: [
                ({
                    type: "hysteria2",
                    tag: "hy2-out",
                    server: $server,
                    server_port: $port,
                    password: $auth,
                    tls: { enabled: true, server_name: $sni, insecure: true }
                } + (if $obfs == "" then {} else { obfs: { type: "salamander", password: $obfs } } end)),
                { type: "direct", tag: "direct" }
            ],
            route: { final: "hy2-out" }
        }' > "$tmpfile" || { rm -f "$tmpfile"; return 1; }

    echo "$tmpfile"
}

change_user_password() {
    local user="$1"
    local new_pass
    new_pass=$(pwgen -s 64 1)
    if is_user_disabled "$user"; then
        sed -i "s#^${user}|.*#${user}|${new_pass}#" "$DISABLED_FILE"
    else
        if ! grep -q "^[[:space:]]*${user}:[[:space:]]" "$CONFIG"; then
            echo "  ❌ Пользователь не найден"
            return 1
        fi
        sed -i "/^[[:space:]]*${user}:[[:space:]]/d" "$CONFIG"
        sed -i "/^[[:space:]]*userpass:/a\\    ${user}: \"${new_pass}\"" "$CONFIG"
        if ! grep -q "^    ${user}: " "$CONFIG"; then
            echo "  ❌ Ошибка записи нового пароля в конфиг!"
            return 1
        fi
    fi
    echo "  ✅ Пароль $user обновлён"
    echo "  🔑 Новый: ${new_pass}"
}
