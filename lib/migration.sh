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
#
# ВАЖНО: скрипт ТОЛЬКО проверяет пару user:pass и НЕ режет по числу сессий.
# Раньше здесь была жёсткая проверка лимита устройств прямо на этапе auth — она
# отклоняла новое подключение по «живому онлайну». На практике это ломало работу:
#   • собственная переподключающаяся/«залипшая» сессия клиента считалась лишней,
#     новый коннект отклонялся → клиент подключался и тут же отваливался (оффлайн);
#   • смена ноды не работала — старая нода ещё числила юзера онлайн, и новая
#     отказывала.
# Теперь лимит устройств держится НЕ на входе, а по РЕАЛЬНОМУ трафику: раз в
# минуту менеджер смотрит, на каких нодах юзер активно гонит трафик (скорость за
# минуту ≥ порога), и оставляет активной только «первую» ноду, а лишние
# параллельные обрезает (см. enforce_active_node_limit). Так пинги/keepalive
# лимит не расходуют, а одну подписку нельзя активно использовать сразу на
# нескольких нодах.
install_auth_script() {
    {
        echo '#!/bin/bash'
        echo "DB=\"${USERS_DB}\""
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

# Проверка пары user:pass по базе. Лимит устройств применяется отдельно, по
# реальному трафику (traffic-based, раз в минуту), а НЕ на этапе аутентификации —
# иначе переподключения и смена ноды ломали бы подключение (см. install_auth_script).
awk -F: -v u="$user" -v p="$pass" '
    $1==u { rest=substr($0, length($1)+2); if (rest==p) { found=1; exit } }
    END { exit (found?0:1) }
' "$DB" || exit 1

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
