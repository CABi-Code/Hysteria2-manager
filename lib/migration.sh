#!/bin/bash
# ================================================
# Автомиграции конфига Hysteria 2
#   1) auth: password   -> auth: userpass   (старое)
#   2) auth: userpass   -> auth: command    (внешний скрипт, без рестартов)
# ================================================

migrate_auth() {
    # Если уже на внешней аутентификации — старая миграция не нужна.
    grep -qE '^[[:space:]]*type:[[:space:]]*command' "$CONFIG" 2>/dev/null && return 0

    if grep -q 'type: password' "$CONFIG" 2>/dev/null; then
        echo "⚠️  Обнаружен старый тип auth: password"
        echo "   Переключаю на userpass..."
        sed -i 's/type: password/type: userpass/' "$CONFIG"
        sed -i '/^  password:/d' "$CONFIG"
        if ! grep -q '^  userpass:' "$CONFIG"; then
            sed -i '/^auth:/a \  userpass:' "$CONFIG"
        fi
        echo "✅ Переключено на userpass."
    fi
    if ! grep -q '^  userpass:' "$CONFIG" 2>/dev/null; then
        if grep -q '^auth:' "$CONFIG"; then
            sed -i '/^auth:/a \  userpass:' "$CONFIG"
        fi
    fi
}

# Записывает скрипт внешней аутентификации. Hysteria вызывает его на КАЖДОЕ
# подключение с аргументами: $1=addr, $2=auth("user:pass"), $3=tx.
# При успехе печатает id пользователя (имя) и выходит с кодом 0.
# Благодаря этому добавление/удаление пользователя в users.db применяется
# сразу же — рестарт сервера не требуется.
install_auth_script() {
    {
        echo '#!/bin/bash'
        echo "DB=\"${USERS_DB}\""
        echo "AUTHLIMITS=\"${AUTHLIMITS_FILE}\""
        echo "CONFIG=\"${CONFIG}\""
        cat <<'AUTHEOF'
# Внешняя аутентификация Hysteria 2 (auth.type: command).
# Вызывается на КАЖДОЕ подключение: $1=addr, $2="user:pass", $3=tx.
# При успехе печатает id (имя юзера) и выходит с кодом 0.
auth="$2"
[ -z "$auth" ] && exit 1
user="${auth%%:*}"
pass="${auth#*:}"
{ [ -z "$user" ] || [ "$user" = "$auth" ]; } && exit 1   # нет двоеточия — отказ
[ -r "$DB" ] || exit 1

# 1) Проверка пары user:pass по базе.
awk -F: -v u="$user" -v p="$pass" '
    $1==u { rest=substr($0, length($1)+2); if (rest==p) { found=1; exit } }
    END { exit (found?0:1) }
' "$DB" || exit 1

# 2) Жёсткая проверка лимита устройств (только если включена у юзера).
# FAIL-OPEN: любая ошибка (нет файла/API/утилит) => пускаем, чтобы сбой
# мониторинга НИКОГДА не заблокировал всех клиентов.
# Живой локальный онлайн юзера через API Hysteria (секрет/порт — из config.yaml,
# он world-readable). Печатает число или ничего (тогда fail-open).
auth_local_online() {
    command -v curl >/dev/null 2>&1 || return 1
    command -v jq   >/dev/null 2>&1 || return 1
    [ -r "$CONFIG" ] || return 1
    local secret port resp cnt
    secret=$(awk '/^trafficStats:/,/^[a-zA-Z]/' "$CONFIG" 2>/dev/null | grep -oP 'secret:\s*\K\S+' | tr -d '"' | head -1)
    port=$(awk '/^trafficStats:/,/^[a-zA-Z]/' "$CONFIG" 2>/dev/null | grep 'listen' | grep -oP '\d+' | tail -1)
    [ -n "$secret" ] || return 1
    [ -n "$port" ] || port=25580
    resp=$(curl -s --max-time 2 -H "Authorization: $secret" "http://127.0.0.1:${port}/online" 2>/dev/null)
    [ -n "$resp" ] || return 1
    cnt=$(printf '%s' "$resp" | jq -r --arg u "$user" '.[$u] // 0' 2>/dev/null)
    [[ "$cnt" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$cnt"
}

if [ -r "$AUTHLIMITS" ]; then
    row=$(awk -F'|' -v u="$user" '$1==u{print; exit}' "$AUTHLIMITS" 2>/dev/null)
    if [ -n "$row" ]; then
        hc=$(printf '%s' "$row" | cut -d'|' -f2)
        pc=$(printf '%s' "$row" | cut -d'|' -f3)
        nc=$(printf '%s' "$row" | cut -d'|' -f4)
        others=$(printf '%s' "$row" | cut -d'|' -f5)
        [[ "$pc" =~ ^[0-9]+$ ]] || pc=0
        [[ "$nc" =~ ^[0-9]+$ ]] || nc=0
        [[ "$others" =~ ^[0-9]+$ ]] || others=0
        if [ "$hc" = "1" ]; then
            local_online=$(auth_local_online)
            if [[ "$local_online" =~ ^[0-9]+$ ]]; then
                # На ноду: local_online + это подключение > node_cap ?
                if [ "$nc" -gt 0 ] && [ $((local_online + 1)) -gt "$nc" ]; then
                    exit 1
                fi
                # По кластеру: другие ноды + локально + это подключение > pool_cap ?
                if [ "$pc" -gt 0 ] && [ $((others + local_online + 1)) -gt "$pc" ]; then
                    exit 1
                fi
            fi
        fi
    fi
fi

printf '%s\n' "$user"
exit 0
AUTHEOF
    } > "$AUTH_SCRIPT"
    # Владение/права выставляет secure_auth_files — отдаёт их пользователю
    # сервиса, чтобы процесс hysteria гарантированно мог выполнить скрипт.
    secure_auth_files
}

# Заменяет секцию auth конфига на внешнюю аутентификацию командой.
rewrite_auth_section() {
    local tmp
    tmp=$(mktemp) || return 1
    awk -v cmd="$AUTH_SCRIPT" '
        /^auth:/ {
            print "auth:"
            print "  type: command"
            print "  command: " cmd
            skip=1
            next
        }
        skip && /^[[:space:]]/ { next }   # строки внутри блока auth — выкидываем
        skip && /^[^[:space:]]/ { skip=0 } # начался новый top-level ключ
        { print }
    ' "$CONFIG" > "$tmp" && cat "$tmp" > "$CONFIG"
    rm -f "$tmp"
}

# Разовый перевод на внешнюю аутентификацию. Идемпотентно: если уже command —
# просто обновляет скрипт и права. Делает ОДИН рестарт, дальше управление
# пользователями идёт без перезапусков. При сбое откатывает конфиг.
migrate_to_command_auth() {
    if grep -qE '^[[:space:]]*type:[[:space:]]*command' "$CONFIG" 2>/dev/null; then
        install_auth_script
        secure_auth_files
        return 0
    fi
    grep -q '^[[:space:]]*userpass:' "$CONFIG" 2>/dev/null || return 0

    echo "🔄 Перевожу аутентификацию на внешний скрипт"
    echo "   (разовый перезапуск — дальше пользователи добавляются/удаляются без рестартов)..."

    local bak="${CONFIG}.authbak.$(date +%s)"
    cp -a "$CONFIG" "$bak" 2>/dev/null

    # users.db из текущих userpass (не затирая уже существующие записи)
    touch "$USERS_DB"
    config_userpass_pairs | while IFS='|' read -r u p; do
        [ -n "$u" ] && [ -n "$p" ] || continue
        grep -q "^${u}:" "$USERS_DB" || printf '%s:%s\n' "$u" "$p" >> "$USERS_DB"
    done

    install_auth_script
    secure_auth_files

    # Защита от блокировки ВСЕХ: если в базу не попало ни одной пары (старый
    # формат не распарсился), переключаться на command нельзя — иначе остались
    # бы вообще без рабочей аутентификации. Конфиг не трогаем.
    if ! grep -q '[^[:space:]]' "$USERS_DB" 2>/dev/null; then
        echo "❌ База пользователей пуста — миграция отменена, конфиг не изменён."
        return 1
    fi

    # Самопроверка на первой паре из базы, ИЗ-ПОД ПОЛЬЗОВАТЕЛЯ СЕРВИСА — именно
    # так скрипт будет вызывать Hysteria. Ловит и логику, и проблемы с правами.
    # Если не прошла, конфиг НЕ трогаем и сервер НЕ перезапускаем.
    local tu tp
    IFS=: read -r tu tp < "$USERS_DB"
    if ! auth_check_as_service "$tu" "$tp"; then
        echo "❌ Скрипт аутентификации не прошёл самопроверку — миграция отменена, ничего не изменено."
        return 1
    fi

    rewrite_auth_section
    secure_auth_files

    systemctl restart "$SERVICE" 2>/dev/null
    sleep 2
    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        clear_restart_pending
        echo "✅ Готово. Пользователи теперь применяются мгновенно, без перезапуска Hysteria."
        sleep 2
    else
        echo "❌ Hysteria не запустилась — откатываю конфиг."
        cp -a "$bak" "$CONFIG" 2>/dev/null
        systemctl restart "$SERVICE" 2>/dev/null
        sleep 2
    fi
}
