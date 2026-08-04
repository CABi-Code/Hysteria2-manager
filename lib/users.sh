#!/bin/bash
# ================================================
# Управление пользователями: CRUD-операции
# ================================================

# С внешней аутентификацией (auth.type: command) имена пользователей живут в
# users.db и больше НЕ конфликтуют с YAML-ключами конфига. Запрещаем лишь то,
# что ломает формат базы (двоеточие/пробел/пустое) — это и так отсекает
# валидация ввода [a-zA-Z0-9_-]. Оставлено для обратной совместимости вызовов.
is_reserved_username() {
    case "$1" in
        ""|*[:\|[:space:]]*) return 0 ;;
        *) return 1 ;;
    esac
}

# Закрываем базу и скрипт от чужих, но даём прочитать/выполнить процессу hysteria.
# Под каким пользователем/группой РЕАЛЬНО работает сервис Hysteria. Печатает
# "user group". Hysteria читает config.yaml не как его владелец, а потому что
# файл world-readable (644). Поэтому брать владельца с config.yaml и снимать
# права у остальных (750/640) нельзя — процесс hysteria, запущенный под отдельным
# пользователем (по умолчанию «hysteria»), теряет доступ к users.db и скрипту, и
# аутентификация-командой падает у ВСЕХ клиентов. Права выдаём именно сервису.
service_identity() {
    local u g
    u=$(systemctl show -p User --value "$SERVICE" 2>/dev/null)
    g=$(systemctl show -p Group --value "$SERVICE" 2>/dev/null)
    [ -z "$u" ] && u=root
    id "$u" >/dev/null 2>&1 || u=root          # пользователь из юнита не заведён — откат
    if [ -z "$g" ]; then
        g=$(id -gn "$u" 2>/dev/null); [ -z "$g" ] && g=root
    fi
    printf '%s %s\n' "$u" "$g"
}

# Закрываем базу и скрипт от чужих, но гарантируем доступ процессу hysteria —
# выдаём владение пользователю/группе сервиса (а не владельцу config.yaml).
secure_auth_files() {
    local owner group
    read -r owner group < <(service_identity)
    [ -z "$owner" ] && owner=root
    [ -z "$group" ] && group=root
    chown "${owner}:${group}" "$DATA_DIR" "$USERS_DB" 2>/dev/null || true
    chmod 750 "$DATA_DIR" 2>/dev/null || true
    chmod 640 "$USERS_DB" 2>/dev/null || true
    # Справочник паролей слотов читает тот же скрипт аутентификации.
    if [ -f "$SLOTPASS_DB" ]; then
        chown "${owner}:${group}" "$SLOTPASS_DB" 2>/dev/null || true
        chmod 640 "$SLOTPASS_DB" 2>/dev/null || true
    fi
    if [ -f "$AUTH_SCRIPT" ]; then
        chown "${owner}:${group}" "$AUTH_SCRIPT" 2>/dev/null || true
        chmod 750 "$AUTH_SCRIPT" 2>/dev/null || true
    fi
}

# Прогоняет скрипт аутентификации так, как это сделает Hysteria: из-под
# пользователя сервиса. Так самопроверка ловит проблемы с правами доступа,
# которых не видно при запуске из-под root.
auth_check_as_service() {   # user pass
    local u="$1" p="$2" svc
    [ -z "$u" ] && return 1
    svc=$(service_identity | awk '{print $1}')
    if [ -n "$svc" ] && [ "$svc" != "root" ] && command -v runuser >/dev/null 2>&1; then
        runuser -u "$svc" -- "$AUTH_SCRIPT" "127.0.0.1:0" "${u}:${p}" "0" >/dev/null 2>&1
    else
        "$AUTH_SCRIPT" "127.0.0.1:0" "${u}:${p}" "0" >/dev/null 2>&1
    fi
}

# ---- Низкоуровневые операции с базой пользователей ----
db_user_exists() { grep -q "^${1}:" "$USERS_DB" 2>/dev/null; }

db_add_user() {   # user pass
    grep -q "^${1}:" "$USERS_DB" 2>/dev/null || printf '%s:%s\n' "$1" "$2" >> "$USERS_DB"
    secure_auth_files
}

db_remove_user() { sed -i "/^${1}:/d" "$USERS_DB" 2>/dev/null; }

is_user_disabled() {
    grep -q "^${1}|" "$DISABLED_FILE" 2>/dev/null
}

get_disabled_password() {
    grep "^${1}|" "$DISABLED_FILE" 2>/dev/null | head -1 | cut -d'|' -f2
}

# Отключение пользователя: убираем из базы + кикаем активные сессии.
# Применяется СРАЗУ — рестарт Hysteria не нужен.
disable_user() {
    local user="$1" silent="$2"
    local password
    password=$(get_user_password "$user")
    if [ -z "$password" ]; then
        [ "$silent" != "silent" ] && echo "  ❌ Пользователь $user не найден в базе"
        return 1
    fi
    grep -q "^${user}|" "$DISABLED_FILE" || echo "${user}|${password}" >> "$DISABLED_FILE"
    db_remove_user "$user"
    api_post "/kick" "[\"$user\"]" &>/dev/null
    sub_refresh
    [ "$silent" != "silent" ] && echo "  ✅ Пользователь $user отключён (применено сразу)"
}

# Включение: возвращаем пару в базу. Применяется сразу, без рестарта.
enable_user() {
    local user="$1"
    if ! is_user_disabled "$user"; then
        echo "  ❌ $user не в списке отключённых"
        return 1
    fi
    local password
    password=$(get_disabled_password "$user")
    db_add_user "$user" "$password"
    if ! db_user_exists "$user"; then
        echo "  ❌ Ошибка записи в базу! Пользователь не восстановлен."
        return 1
    fi
    sed -i "/^${user}|/d" "$DISABLED_FILE"
    sub_refresh
    echo "  ✅ Пользователь $user включён (применено сразу)"
}

# Полное удаление: чистим базу и все файлы статистики. Без рестарта.
delete_user() {
    local user="$1"
    # Кластерный ли юзер? Считаем ДО снятия метки (roster_remove ниже).
    local was_cluster=0
    if sub_enabled && declare -F is_cluster_user >/dev/null && is_cluster_user "$user"; then
        was_cluster=1
    fi
    # Снимаем токен подписки и удаляем готовый файл подписки.
    if [ -f "$SUBTOKENS_DB" ]; then
        local _t
        _t=$(awk -F: -v u="$user" '$1==u{print $2; exit}' "$SUBTOKENS_DB" 2>/dev/null)
        [ -n "$_t" ] && rm -f "$WEBROOT/sub/$_t" 2>/dev/null
        sub_token_remove "$user"
    fi
    db_remove_user "$user"
    sed -i "/^${user}|/d" "$DISABLED_FILE" "$STATS_FILE" "$IPS_FILE" "$EXPIRY_FILE" "$SPEED_FILE" "$USERLIMITS_FILE" "$USERLIMITS_TS_FILE" "$ACTIVITY_FILE" "$ACTIVITY_PREV_FILE" "$ABUSE_FILE" "$ABUSE_OBS_FILE" 2>/dev/null
    declare -F roster_remove >/dev/null && roster_remove "$user"   # снять метку «кластерный»
    api_post "/kick" "[\"$user\"]" &>/dev/null
    # Точка правды: ставим tombstone и публикуем — удаление кластерного юзера
    # САМО разнесётся по нодам (а старый roster/манифест пира его не воскресит).
    # СТРОГО ДО sub_refresh: пересборка подписок видит юзера в манифестах пиров и
    # без tombstone заводила ему НОВЫЙ токен с рабочими ключами чужих нод —
    # удалённый профиль продолжал получать подписку.
    if [ "$was_cluster" = 1 ] && declare -F cstate_set >/dev/null; then
        cstate_set "$user" deleted
        publish_cluster_state
    fi
    sub_refresh
    declare -F publish_roster >/dev/null && publish_roster
    echo "  ✅ Пользователь $user полностью удалён (применено сразу)"
    if [ "$was_cluster" = 1 ]; then
        echo "  🌐 Удаление разнесётся по кластеру (на пирах — в течение ~5 мин или по «Синхронизировать»)."
    fi
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
# экранируются.
#
# Второй аргумент — режим:
#   tun   (по умолчанию) — TUN-инбаунд, полный системный туннель (ПК/телефон);
#   socks                — mixed-инбаунд (SOCKS+HTTP) на 127.0.0.1:1080, лёгкий
#                          локальный прокси без захвата всего трафика; удобно
#                          для проверки и для серверов (нет петли auto_route).
#
# Формат рассчитан на sing-box >= 1.12:
#  - DNS-серверы в новом виде ({type,server}), без legacy "address";
#  - перехват DNS (только tun) через route-экшен "hijack-dns";
#  - sniff (только tun) через route-экшен "sniff", а не поле инбаунда;
#  - route.default_domain_resolver обязателен в 1.12 — указывает на dns_local;
#  - у dns_local НЕТ detour: detour на пустой direct outbound в 1.12 даёт FATAL
#    ("detour to an empty direct outbound makes no sense").
#
# Аутентификация Hysteria 2 (userpass) — строка "user:pass" в поле password.
# Блок obfs (salamander) добавляется, только если задан obfs-пароль; для нашего
# сервера он обязателен, иначе сервер отбросит пакеты.
generate_user_config() {
    local user="$1"
    local mode="${2:-tun}"
    local pass
    if is_user_disabled "$user"; then
        pass=$(get_disabled_password "$user")
    else
        pass=$(get_user_password "$user")
    fi
    [ -z "$pass" ] && return 1

    local tmpfile
    tmpfile=$(mktemp "/tmp/sb-${user}.XXXXXX.json") || return 1

    # Если на сервере задан лимит скорости — прописываем его и в клиентский
    # конфиг (up/down_mbps): клиент включит Brutal на этой скорости, и лимит
    # будет соблюдаться «мягко» на уровне протокола (без дропов в ядре).
    # Маппинг: серверный up = скачивание клиента (down_mbps), и наоборот.
    local cl_down_mbps=0 cl_up_mbps=0
    if declare -F bw_to_mbps >/dev/null; then
        cl_down_mbps=$(bw_to_mbps "$(bw_up_get)")
        cl_up_mbps=$(bw_to_mbps "$(bw_down_get)")
    fi

    local jq_filter
    if [ "$mode" = "socks" ]; then
        jq_filter='{
            log: { level: "info", timestamp: true },
            dns: {
                servers: [ { type: "udp", tag: "dns_local", server: "1.1.1.1" } ]
            },
            inbounds: [
                { type: "mixed", tag: "socks-in", listen: "127.0.0.1", listen_port: 1080 }
            ],
            outbounds: [
                ({
                    type: "hysteria2",
                    tag: "proxy_out",
                    server: $server,
                    server_port: $port,
                    password: $auth,
                    tls: { enabled: true, server_name: $sni, insecure: true }
                } + (if $obfs == "" then {} else { obfs: { type: "salamander", password: $obfs } } end)
                  + (if $dmb > 0 then { down_mbps: $dmb } else {} end)
                  + (if $umb > 0 then { up_mbps: $umb } else {} end)),
                { type: "direct", tag: "direct_out" }
            ],
            route: {
                default_domain_resolver: { server: "dns_local" },
                final: "proxy_out"
            }
        }'
    else
        jq_filter='{
            log: { level: "info", timestamp: true },
            dns: {
                servers: [
                    { type: "https", tag: "dns_remote", server: "8.8.8.8", detour: "proxy_out" },
                    { type: "udp", tag: "dns_local", server: "1.1.1.1" }
                ],
                final: "dns_remote",
                strategy: "ipv4_only"
            },
            inbounds: [
                {
                    type: "tun",
                    tag: "tun-in",
                    interface_name: "singtun0",
                    address: [ "172.19.0.1/30" ],
                    auto_route: true,
                    strict_route: true,
                    stack: "system"
                }
            ],
            outbounds: [
                ({
                    type: "hysteria2",
                    tag: "proxy_out",
                    server: $server,
                    server_port: $port,
                    password: $auth,
                    tls: { enabled: true, server_name: $sni, insecure: true }
                } + (if $obfs == "" then {} else { obfs: { type: "salamander", password: $obfs } } end)
                  + (if $dmb > 0 then { down_mbps: $dmb } else {} end)
                  + (if $umb > 0 then { up_mbps: $umb } else {} end)),
                { type: "direct", tag: "direct_out" }
            ],
            route: {
                auto_detect_interface: true,
                default_domain_resolver: { server: "dns_local" },
                final: "proxy_out",
                rules: [
                    { action: "sniff" },
                    { protocol: "dns", action: "hijack-dns" },
                    { port: 22, outbound: "direct_out" },
                    { ip_is_private: true, outbound: "direct_out" }
                ]
            }
        }'
    fi

    # Адрес сервера — через link_host (домен подключения/релей, если настроен),
    # а не голый IP: иначе конфиг раскрывал бы IP скрытой за релеем ноды.
    local srv="${CACHED_IP:-}"
    declare -F link_host >/dev/null && srv=$(link_host)
    [ -z "$srv" ] && srv="$CACHED_IP"

    jq -n \
        --arg server "$srv" \
        --argjson port "${CACHED_PORT:-$(get_port)}" \
        --arg auth "${user}:${pass}" \
        --arg sni "${CACHED_SNI:-$(get_sni)}" \
        --arg obfs "${CACHED_OBFS:-$(get_obfs_pass)}" \
        --argjson dmb "${cl_down_mbps:-0}" \
        --argjson umb "${cl_up_mbps:-0}" \
        "$jq_filter" > "$tmpfile" || { rm -f "$tmpfile"; return 1; }

    echo "$tmpfile"
}

change_user_password() {
    local user="$1"
    local new_pass
    new_pass=$(pwgen -s 64 1)
    if is_user_disabled "$user"; then
        sed -i "s#^${user}|.*#${user}|${new_pass}#" "$DISABLED_FILE"
    else
        if ! db_user_exists "$user"; then
            echo "  ❌ Пользователь не найден"
            return 1
        fi
        db_remove_user "$user"
        db_add_user "$user" "$new_pass"
        if ! db_user_exists "$user"; then
            echo "  ❌ Ошибка записи нового пароля в базу!"
            return 1
        fi
        # Кикаем — со старым паролем доступ сразу пропадёт, переподключится по новой ссылке.
        api_post "/kick" "[\"$user\"]" &>/dev/null
    fi
    sub_refresh
    echo "  ✅ Пароль $user обновлён (применено сразу)"
    echo "  🔑 Новый: ${new_pass}"
}
