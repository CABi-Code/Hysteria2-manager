#!/bin/bash
# ================================================
# Управление сроками действия пользователей
# ================================================

# Метка времени последнего изменения срока (для кластерной синхронизации).
expiry_set_ts() {   # user [ts]
    local user="$1" ts="${2:-$(date +%s)}"
    touch "$EXPIRY_TS_FILE" 2>/dev/null
    sed -i "/^${user}|/d" "$EXPIRY_TS_FILE" 2>/dev/null
    echo "${user}|${ts}" >> "$EXPIRY_TS_FILE"
}
expiry_get_ts() {   # user -> ts (0 если нет)
    local t; t=$(fld_by_key "$EXPIRY_TS_FILE" "$1" 2)
    [[ "$t" =~ ^[0-9]+$ ]] && echo "$t" || echo 0
}

# Третий аргумент ts — внутренний (применение срока, пришедшего с другой ноды,
# чтобы не зациклить синхронизацию). Из UI не передаётся → ts=now + публикация.
set_user_expiry() {
    local user="$1" date="$2" ts="$3"
    sed -i "/^${user}|/d" "$EXPIRY_FILE"
    echo "${user}|${date}" >> "$EXPIRY_FILE"
    expiry_set_ts "$user" "$ts"
    [ -z "$ts" ] && declare -F publish_cluster_expiry >/dev/null && publish_cluster_expiry
}

get_user_expiry() {
    fld_by_key "$EXPIRY_FILE" "$1" 2
}

# Дата (ГГГГ-ММ-ДД) через N дней от сегодня. Пустой вывод = ошибка.
days_to_date() {
    local days="$1"
    [[ "$days" =~ ^[0-9]+$ ]] || return 1
    date -d "+${days} days" +%Y-%m-%d 2>/dev/null
}

# Сколько дней осталось до даты (может быть < 0 = просрочено).
# Пустой вывод/код 1 — если дата не задана или не распарсилась.
#
# Просроченное ОКРУГЛЯЕМ ВНИЗ: деление в bash режет к нулю, поэтому вчерашний
# срок давал ровно 0 — «ещё действует». Из-за этого freeplan_tick считал юзера
# оплатившим и снимал его с бесплатного тарифа, а check_expired_users (там
# сравнение дат, а не секунд) тут же переводил обратно — с уведомлением в личку
# на каждый прогон. Ноль теперь означает только «истекает сегодня».
expiry_days_left() {
    local exp="$1" exp_ts now_ts diff
    [ -z "$exp" ] && return 1
    exp_ts=$(date -d "$exp 23:59:59" +%s 2>/dev/null) || return 1
    now_ts=$(date +%s)
    diff=$(( exp_ts - now_ts ))
    if [ "$diff" -ge 0 ]; then
        echo $(( diff / 86400 ))
    else
        echo $(( -(( -diff + 86399 ) / 86400) ))
    fi
}

# Единственный ответ на вопрос «срок кончился?»: 0 — да, 1 — нет (в т.ч. когда
# срока нет вовсе, это бессрочный доступ). Все решения о переводе на бесплатный
# тариф и об отключении обязаны спрашивать ИМЕННО ЕЁ: две независимые проверки
# (сравнение дат в одном месте, секунды в другом) уже разъезжались на сутки.
expiry_is_over() {   # expiry_date
    local left
    [ -z "$1" ] && return 1
    left=$(expiry_days_left "$1") || return 1
    [ "$left" -lt 0 ]
}

# Остаток до конца дня истечения в виде «Nд Чч Мм».
# Срок хранится как дата (без времени), поэтому считаем до 23:59:59 этого дня.
# Возвращает «истёк», если дата в прошлом. Код 1 — если дата не задана.
format_remaining() {
    local exp="$1" exp_ts now_ts diff d h m
    [ -z "$exp" ] && return 1
    exp_ts=$(date -d "$exp 23:59:59" +%s 2>/dev/null) || return 1
    now_ts=$(date +%s)
    diff=$(( exp_ts - now_ts ))
    if [ "$diff" -le 0 ]; then
        echo "истёк"
        return 0
    fi
    d=$(( diff / 86400 ))
    h=$(( (diff % 86400) / 3600 ))
    m=$(( (diff % 3600) / 60 ))
    if [ "$d" -gt 0 ]; then
        echo "${d}д ${h}ч ${m}м"
    elif [ "$h" -gt 0 ]; then
        echo "${h}ч ${m}м"
    else
        echo "${m}м"
    fi
}

remove_user_expiry() {
    local user="$1" ts="$2"
    sed -i "/^${user}|/d" "$EXPIRY_FILE"
    expiry_set_ts "$user" "$ts"     # снятие срока — тоже «изменение» (пустая дата)
    [ -z "$ts" ] && declare -F publish_cluster_expiry >/dev/null && publish_cluster_expiry
}

check_expired_users() {
    while IFS='|' read -r user exp_date; do
        [ -z "$user" ] || [ -z "$exp_date" ] && continue
        # Ровно та же проверка, что и в freeplan_tick — иначе они разъезжаются
        # и гоняют юзера туда-сюда (см. комментарий у expiry_is_over).
        if expiry_is_over "$exp_date"; then
            # Уже на бесплатном тарифе — не наше дело: доступ ему даёт freeplan,
            # квоты считает freeplan_tick. Проверка ВЫШЕ проверки free_enabled и
            # намеренно смотрит только в freeplan.dat (файл кластерный): нода без
            # своего free-тарифа в tariffs.conf отключала такого юзера и слала
            # «⏰ Автоотключение по сроку» админу и «доступ отключён» клиенту —
            # ровно в момент, когда человек нажал «подключить бесплатный».
            if declare -F freeplan_has >/dev/null && freeplan_has "$user"; then
                continue
            fi
            # Пользователь активен (есть в базе) и ещё не отключён — отключаем.
            # Применяется сразу (база + kick), рестарт Hysteria не нужен.
            # Настроен бесплатный тариф (free=1) — не отключаем, а переводим
            # на него: доступ продолжает работать в рамках лимитов трафика.
            # См. lib/freeplan.sh (idea 02).
            if declare -F freeplan_enter >/dev/null && free_enabled; then
                if db_user_exists "$user"; then
                    freeplan_enter "$user"
                    echo "🆓 Перевод на бесплатный тариф: $user (срок: $exp_date)"
                fi
                continue
            fi
            # Пользователь активен (есть в базе) и ещё не отключён — отключаем.
            # Применяется сразу (база + kick), рестарт Hysteria не нужен.
            if ! is_user_disabled "$user" && db_user_exists "$user"; then
                disable_user "$user" silent
                echo "⏰ Автоотключение: $user (срок: $exp_date)"
                # Если настроен Telegram-бот — предупредить клиента и админов.
                declare -F bot_notify_expired >/dev/null && bot_notify_expired "$user"
            fi
        fi
    done < "$EXPIRY_FILE"
}
