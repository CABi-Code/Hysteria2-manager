#!/bin/bash
# ================================================
# Управление сроками действия пользователей
# ================================================

set_user_expiry() {
    local user="$1" date="$2"
    sed -i "/^${user}|/d" "$EXPIRY_FILE"
    echo "${user}|${date}" >> "$EXPIRY_FILE"
}

get_user_expiry() {
    grep "^${1}|" "$EXPIRY_FILE" 2>/dev/null | head -1 | cut -d'|' -f2
}

# Дата (ГГГГ-ММ-ДД) через N дней от сегодня. Пустой вывод = ошибка.
days_to_date() {
    local days="$1"
    [[ "$days" =~ ^[0-9]+$ ]] || return 1
    date -d "+${days} days" +%Y-%m-%d 2>/dev/null
}

# Сколько дней осталось до даты (может быть < 0 = просрочено).
# Пустой вывод/код 1 — если дата не задана или не распарсилась.
expiry_days_left() {
    local exp="$1" exp_ts now_ts
    [ -z "$exp" ] && return 1
    exp_ts=$(date -d "$exp 23:59:59" +%s 2>/dev/null) || return 1
    now_ts=$(date +%s)
    echo $(( (exp_ts - now_ts) / 86400 ))
}

remove_user_expiry() {
    sed -i "/^${1}|/d" "$EXPIRY_FILE"
}

check_expired_users() {
    local today changed=false
    today=$(date +%Y-%m-%d)
    while IFS='|' read -r user exp_date; do
        [ -z "$user" ] || [ -z "$exp_date" ] && continue
        if [[ "$exp_date" < "$today" ]]; then
            if ! is_user_disabled "$user" && grep -q "^[[:space:]]*${user}:[[:space:]]" "$CONFIG"; then
                disable_user "$user" silent
                echo "⏰ Автоотключение: $user (срок: $exp_date)"
                changed=true
            fi
        fi
    done < "$EXPIRY_FILE"
    if $changed; then
        systemctl restart "$SERVICE" 2>/dev/null
        sleep 2
    fi
}
