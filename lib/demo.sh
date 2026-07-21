#!/bin/bash
# ================================================
# Демо-профили: рабочий VPN в один тап, до регистрации и оплаты (idea 13 веб-аппа).
#
# Демо — это обычный пользователь Hysteria/Xray, но жёстко закапанный сразу по
# трём осям: скорость, трафик и время жизни. Экономика фарма ломается сама:
# нафармить месяц доступа дороже, чем его купить, — это и есть основная защита,
# фингерпринт в браузере лишь отсекает ленивых (см. веб-апп).
#
# ЖИВЁТ ТОЛЬКО НА ЭТОЙ НОДЕ. В roster кластера демо не попадает и по нодам не
# публикуется: приёмник проб — одна нода (та, с которой работает веб-апп), чтобы
# не размазывать мусорную нагрузку по боевым локациям. Поэтому и отдельного
# publish/apply не нужно — демо не переживает переезд и не мешает боевым юзерам.
#
# DEMOS_DB: «user|state|created|expires|cap|base|used»
#   state   active — доступ работает; expired — доступ уже отобран, строка ещё
#           сутки лежит для статистики, потом её убирает та же прогонка;
#   cap     лимит трафика в байтах (0 — без лимита);
#   base    общий трафик юзера на момент выдачи (расход = текущий минус base);
#   used    израсходовано на момент отбора доступа (для статистики).
# ================================================

# Параметры демо. Подобраны так, чтобы проба ощущалась рабочей (сайты, мессенджеры,
# видео в SD), но фарм был бессмысленным: месяц доступа = сотни ротаций браузера.
DEMO_RATE_MBPS="${DEMO_RATE_MBPS:-5}"
DEMO_CAP_BYTES="${DEMO_CAP_BYTES:-$((500 * 1024 * 1024))}"
DEMO_TTL_MIN="${DEMO_TTL_MIN:-60}"
DEMO_KEEP_SEC="${DEMO_KEEP_SEC:-86400}"     # сколько держать строку после отбора

demo_enabled() { sub_enabled; }   # без подписки отдавать гостю нечего

demo_row()   { awk -F'|' -v u="$1" '$1==u{print; exit}' "$DEMOS_DB" 2>/dev/null; }
demo_field() { demo_row "$1" | cut -d'|' -f"$2"; }
demo_is()    { [ -n "$(demo_row "$1")" ]; }

demo_set() {   # user state created expires cap base used
    mkdir -p "$DATA_DIR"; touch "$DEMOS_DB"
    sed -i "/^${1}|/d" "$DEMOS_DB" 2>/dev/null
    printf '%s|%s|%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7" >> "$DEMOS_DB"
    chmod 600 "$DEMOS_DB" 2>/dev/null
}

demo_remove() { sed -i "/^${1}|/d" "$DEMOS_DB" 2>/dev/null; }

# Сколько демо сейчас раздано (для лимита/статистики).
demo_active_count() { awk -F'|' '$2=="active"' "$DEMOS_DB" 2>/dev/null | grep -c .; }

# Выдать демо-профиль. Печатает key=value: user, sub_url, expires, cap, rate.
demo_create() {
    demo_enabled || return 1
    local user pass now expires

    # Имя вида demo-xxxxxxxx: по префиксу демо видно в любом списке юзеров.
    for _ in 1 2 3; do
        user="demo-$(pwgen -s 8 1 2>/dev/null | tr 'A-Z' 'a-z')"
        [[ "$user" =~ ^demo-[a-z0-9]{8}$ ]] || user="demo-$(head -c 16 /dev/urandom | base64 | tr -dc 'a-z0-9' | head -c 8)"
        db_user_exists "$user" || break
    done
    db_user_exists "$user" && return 1

    pass=$(bot_gen_pass)
    [ -n "$pass" ] || return 1
    db_add_user "$user" "$pass" || return 1
    db_user_exists "$user" || return 1

    now=$(date +%s); expires=$(( now + DEMO_TTL_MIN * 60 ))

    # Одно устройство и урезанная скорость. klimit_apply нужен, чтобы под тариф
    # скорости реально появился HTB-класс (иначе лимит игнорируется) — так же
    # это делает set-limits в webapi/dispatch.sh.
    set_user_limits "$user" 1 0 "" "$DEMO_RATE_MBPS" >/dev/null 2>&1
    write_authlimits >/dev/null 2>&1 || true
    klimit_apply "$(klimit_down)" "$(klimit_up)" >/dev/null 2>&1 || true

    # Ключи всех локальных протоколов + токен подписки.
    sub_refresh >/dev/null 2>&1 || true

    demo_set "$user" active "$now" "$expires" "$DEMO_CAP_BYTES" "$(demo_user_bytes "$user")" 0

    printf 'user=%s\n' "$user"
    printf 'sub_url=%s\n' "$(subscription_url "$user")"
    printf 'expires=%s\n' "$expires"
    printf 'cap=%s\n' "$DEMO_CAP_BYTES"
    printf 'rate=%s\n' "$DEMO_RATE_MBPS"
}

# Трафик демо-юзера. Демо локальное, но считаем той же функцией, что и квоты
# бесплатного тарифа: она уже умеет «собранное + ещё не собранный кумулятив».
demo_user_bytes() {
    if declare -F freeplan_user_bytes >/dev/null 2>&1; then
        freeplan_user_bytes "$1"
    else
        local tl; tl=$(get_user_traffic "$1")
        printf '%s' $(( $(printf '%s' "$tl" | cut -d'|' -f2) + $(printf '%s' "$tl" | cut -d'|' -f3) ))
    fi
}

# Прогон раз в минуту (--online-sync): отобрать доступ у выдохшихся демо и
# подчистить старые строки. TTL меряем в минутах, поэтому суточной прогонки
# expiry-по-датам (check_expired_users) здесь мало.
demo_tick() {
    [ -s "$DEMOS_DB" ] || return 0
    local now user state created expires cap base used bytes spent
    now=$(date +%s)

    while IFS='|' read -r user state created expires cap base used; do
        [ -n "$user" ] || continue
        [[ "$user" =~ ^[a-zA-Z0-9_-]+$ ]] || continue

        if [ "$state" = "active" ]; then
            bytes=$(demo_user_bytes "$user")
            spent=$(( bytes - ${base:-0} )); [ "$spent" -lt 0 ] && spent=0
            if [ "$now" -ge "${expires:-0}" ] 2>/dev/null || \
               { [ "${cap:-0}" -gt 0 ] && [ "$spent" -ge "$cap" ]; }; then
                # Доступ отбираем целиком: демо не продлевают и не включают обратно.
                cluster_delete_local "$user" >/dev/null 2>&1
                demo_set "$user" expired "$created" "$expires" "$cap" "$base" "$spent"
            fi
        elif [ $(( now - ${expires:-0} )) -ge "$DEMO_KEEP_SEC" ] 2>/dev/null; then
            demo_remove "$user"
        fi
    done < "$DEMOS_DB"
}
