#!/bin/bash
# ================================================
# Персональные лимиты пользователя: кол-во устройств, «жёсткая проверка» и тариф
# скорости. Хранятся в USERLIMITS_FILE «user|devices|hardcheck|rate», метки
# изменения — в USERLIMITS_TS_FILE «user|ts». Синхронизируются по кластеру
# LWW-по-ts (как срок действия, см. lib/expiry.sh + cluster_apply_userlimits в
# lib/cluster.sh) — то есть тариф это атрибут ПОДПИСКИ, единый на всех нодах.
# devices: 0 = «использовать глобальный POOL_LIMIT», ≥1 = персональный лимит.
# hardcheck: 0/1 — отклонять новые устройства сверх лимита на этапе auth.
# rate: тариф скорости в Мбит/с (0 = нет тарифа → глобальный kernel-лимит).
#       Применяется на уровне ядра пер-IP через tc (см. klimit_reconcile в perf.sh).
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

# Сырая строка «devices|hardcheck|rate» пользователя (пусто, если записи нет).
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

# Тариф скорости пользователя в Мбит/с (0 = нет тарифа → глобальный лимит).
# Поле опциональное: старые записи без 4-го поля → 0 (обратная совместимость).
get_user_rate() {
    local v; v=$(_userlimits_row "$1" | cut -d'|' -f4)
    [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" || echo 0
}

# Записать все настройки разом (+ метка времени; пустой ts = «сейчас» + публикация).
# Аргумент ts — внутренний (применение записи с другой ноды, чтобы не зациклить
# синхронизацию). Из UI не передаётся → ts=now + публикация. rate опционален —
# если не передан, берётся текущий (обёртки ниже сохраняют неизменяемые поля).
set_user_limits() {   # user devices hardcheck [ts] [rate]
    local user="$1" devices="$2" hard="$3" ts="$4" rate="$5"
    [[ "$devices" =~ ^[0-9]+$ ]] || devices="$DEFAULT_DEVICES"
    [ "$hard" = "1" ] || hard=0
    [[ "$rate" =~ ^[0-9]+$ ]] || rate=0
    touch "$USERLIMITS_FILE" 2>/dev/null
    sed -i "/^${user}|/d" "$USERLIMITS_FILE" 2>/dev/null
    echo "${user}|${devices}|${hard}|${rate}" >> "$USERLIMITS_FILE"
    userlimits_set_ts "$user" "$ts"
    [ -z "$ts" ] && declare -F publish_cluster_userlimits >/dev/null && publish_cluster_userlimits
}

# Удобные обёртки: меняем одно поле, остальные берём текущими.
set_user_devices()   { set_user_limits "$1" "$2" "$(get_user_hardcheck "$1")" "" "$(get_user_rate "$1")"; }
set_user_hardcheck() { set_user_limits "$1" "$(get_user_devices "$1")" "$2" "" "$(get_user_rate "$1")"; }
set_user_rate()      { set_user_limits "$1" "$(get_user_devices "$1")" "$(get_user_hardcheck "$1")" "" "$2"; }

# Поднять лимит устройств до тарифного, НЕ опуская уже имеющийся (P-42).
# Тариф обещает «не меньше N устройств»; всё, что сверх, человек мог докупить
# отдельно и за деньги (надстройка, cibpn-webapp/docs/DEVICES.md), и оплата
# тарифа не должна это стирать. devices=0 у тарифа = «лимит не задан» → не
# трогаем вовсе; devices=0 у ЮЗЕРА = «глобальный лимит», его тариф перебивает.
tariff_raise_devices() {   # user tariff_devices
    local user="$1" want="$2" cur
    { [[ "$want" =~ ^[0-9]+$ ]] && [ "$want" -gt 0 ]; } || return 0
    cur=$(get_user_devices "$user")
    [ "${cur:-0}" -ge "$want" ] 2>/dev/null && return 0
    set_user_devices "$user" "$want"
}

# Удалить персональные лимиты (например, при полном удалении юзера).
remove_user_limits() {
    sed -i "/^${1}|/d" "$USERLIMITS_FILE" "$USERLIMITS_TS_FILE" 2>/dev/null
}
