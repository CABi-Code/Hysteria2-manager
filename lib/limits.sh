#!/bin/bash
# ================================================
# Персональные лимиты пользователя: кол-во устройств и «жёсткая проверка».
# Хранятся в USERLIMITS_FILE «user|devices|hardcheck», метки изменения — в
# USERLIMITS_TS_FILE «user|ts». Синхронизируются по кластеру LWW-по-ts (как срок
# действия, см. lib/expiry.sh + cluster_apply_userlimits в lib/cluster.sh).
# devices: 0 = «использовать глобальный POOL_LIMIT», ≥1 = персональный лимит.
# hardcheck: 0/1 — отклонять новые устройства сверх лимита на этапе auth.
# ================================================

DEFAULT_DEVICES=1

# Метка времени последнего изменения (для кластерной синхронизации).
userlimits_set_ts() {   # user [ts]
    local user="$1" ts="${2:-$(date +%s)}"
    touch "$USERLIMITS_TS_FILE" 2>/dev/null
    sed -i "/^${user}|/d" "$USERLIMITS_TS_FILE" 2>/dev/null
    echo "${user}|${ts}" >> "$USERLIMITS_TS_FILE"
}
userlimits_get_ts() {   # user -> ts (0 если нет)
    local t; t=$(grep "^${1}|" "$USERLIMITS_TS_FILE" 2>/dev/null | head -1 | cut -d'|' -f2)
    [[ "$t" =~ ^[0-9]+$ ]] && echo "$t" || echo 0
}

# Сырая строка «devices|hardcheck» пользователя (пусто, если записи нет).
_userlimits_row() { grep "^${1}|" "$USERLIMITS_FILE" 2>/dev/null | head -1; }

# Кол-во устройств пользователя (по умолчанию DEFAULT_DEVICES=1).
get_user_devices() {
    local v; v=$(_userlimits_row "$1" | cut -d'|' -f2)
    [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" || echo "$DEFAULT_DEVICES"
}

# Включена ли жёсткая проверка (0/1, по умолчанию 0).
get_user_hardcheck() {
    local v; v=$(_userlimits_row "$1" | cut -d'|' -f3)
    [ "$v" = "1" ] && echo 1 || echo 0
}

# Записать обе настройки разом (+ метка времени; пустой ts = «сейчас» + публикация).
# Третий аргумент ts — внутренний (применение записи с другой ноды, чтобы не
# зациклить синхронизацию). Из UI не передаётся → ts=now + публикация.
set_user_limits() {   # user devices hardcheck [ts]
    local user="$1" devices="$2" hard="$3" ts="$4"
    [[ "$devices" =~ ^[0-9]+$ ]] || devices="$DEFAULT_DEVICES"
    [ "$hard" = "1" ] || hard=0
    touch "$USERLIMITS_FILE" 2>/dev/null
    sed -i "/^${user}|/d" "$USERLIMITS_FILE" 2>/dev/null
    echo "${user}|${devices}|${hard}" >> "$USERLIMITS_FILE"
    userlimits_set_ts "$user" "$ts"
    [ -z "$ts" ] && declare -F publish_cluster_userlimits >/dev/null && publish_cluster_userlimits
}

# Удобные обёртки: меняем одно поле, второе берём текущим.
set_user_devices()   { set_user_limits "$1" "$2" "$(get_user_hardcheck "$1")"; }
set_user_hardcheck() { set_user_limits "$1" "$(get_user_devices "$1")" "$2"; }

# Удалить персональные лимиты (например, при полном удалении юзера).
remove_user_limits() {
    sed -i "/^${1}|/d" "$USERLIMITS_FILE" "$USERLIMITS_TS_FILE" 2>/dev/null
}
