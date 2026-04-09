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

remove_user_expiry() {
    sed -i "/^${1}|/d" "$EXPIRY_FILE"
}

check_expired_users() {
    local today changed=false
    today=$(date +%Y-%m-%d)
    while IFS='|' read -r user exp_date; do
        [ -z "$user" ] || [ -z "$exp_date" ] && continue
        if [[ "$exp_date" < "$today" || "$exp_date" == "$today" ]]; then
            if ! is_user_disabled "$user" && grep -q "^    ${user}: " "$CONFIG"; then
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
