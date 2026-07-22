#!/bin/bash
# ================================================
# Сбор и отображение трафика пользователей
# ================================================

collect_traffic() {
    local response now last_ts elapsed have_baseline=1
    response=$(api_get "/traffic?clear=1")

    # Интервал с прошлого сбора — нужен для расчёта скорости (B/s).
    # /traffic?clear=1 отдаёт трафик с момента прошлого clear и обнуляет
    # счётчики, поэтому delta за интервал = это и есть значения tx/rx ответа.
    now=$(date +%s)
    [ -s "$SPEED_TS_FILE" ] && last_ts=$(cat "$SPEED_TS_FILE" 2>/dev/null)
    if [[ "$last_ts" =~ ^[0-9]+$ ]]; then
        elapsed=$(( now - last_ts ))
    else
        # Первый запуск: базовой точки нет — скорость в этот тик не считаем,
        # иначе накопленный трафик показался бы как мгновенная скорость.
        elapsed=1
        have_baseline=0
    fi
    [ "$elapsed" -lt 1 ] && elapsed=1
    echo "$now" > "$SPEED_TS_FILE"

    # Файл скорости пересобираем каждый интервал: кого нет в ответе —
    # у того скорость 0 (get_user_speed вернёт 0 при отсутствии строки).
    : > "$SPEED_FILE"

    { [ -z "$response" ] || [ "$response" = "null" ]; } && return

    echo "$response" | jq -r 'to_entries[] | "\(.key)|\(.value.tx // 0)|\(.value.rx // 0)"' 2>/dev/null | \
    while IFS='|' read -r user tx rx; do
        [ -z "$user" ] && continue
        tx=${tx:-0}; rx=${rx:-0}
        [[ "$tx" =~ ^[0-9]+$ ]] || tx=0
        [[ "$rx" =~ ^[0-9]+$ ]] || rx=0
        [ "$tx" -eq 0 ] && [ "$rx" -eq 0 ] && continue

        if grep -q "^${user}|" "$STATS_FILE"; then
            local old_tx old_rx new_tx new_rx
            old_tx=$(grep "^${user}|" "$STATS_FILE" | head -1 | cut -d'|' -f2)
            old_rx=$(grep "^${user}|" "$STATS_FILE" | head -1 | cut -d'|' -f3)
            new_tx=$(( ${old_tx:-0} + tx ))
            new_rx=$(( ${old_rx:-0} + rx ))
            sed -i "s#^${user}|.*#${user}|${new_tx}|${new_rx}#" "$STATS_FILE"
        else
            echo "${user}|${tx}|${rx}" >> "$STATS_FILE"
        fi

        # Мгновенная скорость за интервал (байт/сек)
        if [ "$have_baseline" = 1 ]; then
            echo "${user}|$(( tx / elapsed ))|$(( rx / elapsed ))" >> "$SPEED_FILE"
        fi
    done
}

# ---- Учёт АКТИВНОГО трафика для жёсткой проверки (traffic-based) ----
# Раз в минуту читаем КУМУЛЯТИВНЫЙ трафик из API БЕЗ сброса счётчиков (в отличие
# от collect_traffic, который раз в 30 мин делает ?clear=1). По дельте с прошлым
# снимком считаем скорость юзера за последнюю минуту. Если скорость ≥ порога —
# юзер СЕЙЧАС реально пользуется сетью на этой ноде (не пинг/keepalive): ставим
# active=1 и фиксируем active_since (начало активной серии) — по нему выбираем
# «первую» активную ноду в enforce_active_node_limit. Иначе active=0.
# FAIL-SAFE: если API недоступен/ответ пуст — файл активности НЕ трогаем, чтобы
# сбой мониторинга не привёл к ложным обрезаниям и не терял «первенство» ноды.
collect_activity() {
    local response now user cum prevline prevcum prevts elapsed delta rate \
          old_line old_active old_since active since thr merged
    response=$(api_get "/traffic")   # без clear=1 — не мешаем 30-мин сбору
    { [ -z "$response" ] || [ "$response" = "null" ]; } && return 0
    echo "$response" | jq empty 2>/dev/null || return 0

    # Суммарный кумулятив per-user по ВСЕМ протоколам: Hysteria (/traffic) +
    # доп. протоколы (proto_activity_cum_lines: Xray statsquery + TUIC /connections).
    # awk складывает дубли юзеров. Fail-safe сохранён: если Hysteria API отдал
    # пусто — мы уже вышли выше и НЕ трогаем activity.dat (без ложных обрезаний).
    merged=$(
        {
            echo "$response" | jq -r 'to_entries[] | "\(.key)|\((.value.tx // 0) + (.value.rx // 0))"' 2>/dev/null
            declare -F proto_activity_cum_lines >/dev/null 2>&1 && proto_activity_cum_lines 2>/dev/null
        } | awk -F'|' 'NF>=2 && $1!="" {s[$1]+=$2} END{for(u in s) printf "%s|%.0f\n", u, s[u]}'   # %.0f: mawk иначе пишет 2^31+ как «1.42856e+09»
    )

    now=$(date +%s)
    thr="${ACTIVITY_THRESHOLD_BPS:-4096}"
    [[ "$thr" =~ ^[0-9]+$ ]] || thr=4096
    local newprev="${ACTIVITY_PREV_FILE}.tmp" newact="${ACTIVITY_FILE}.tmp"
    : > "$newprev"; : > "$newact"

    # Идём по кумулятиву каждого юзера из ответа API (tx+rx суммарно).
    while IFS='|' read -r user cum; do
        [ -n "$user" ] || continue
        [[ "$cum" =~ ^[0-9]+$ ]] || cum=0

        # Прошлый снимок кумулятива — для дельты за минуту.
        prevline=$(grep "^${user}|" "$ACTIVITY_PREV_FILE" 2>/dev/null | head -1)
        prevcum=$(printf '%s' "$prevline" | cut -d'|' -f2)
        prevts=$(printf '%s' "$prevline" | cut -d'|' -f3)
        printf '%s|%s|%s\n' "$user" "$cum" "$now" >> "$newprev"

        rate=0
        if [[ "$prevcum" =~ ^[0-9]+$ ]] && [[ "$prevts" =~ ^[0-9]+$ ]]; then
            elapsed=$(( now - prevts )); [ "$elapsed" -lt 1 ] && elapsed=1
            # Счётчик мог обнулиться (collect сделал ?clear=1) — тогда дельта = cum.
            if [ "$cum" -ge "$prevcum" ]; then delta=$(( cum - prevcum )); else delta=$cum; fi
            rate=$(( delta / elapsed ))
        fi

        # Прошлое состояние активности — чтобы НЕ сбрасывать active_since, пока
        # активная серия непрерывна (иначе «первенство» терялось бы каждую минуту).
        old_line=$(grep "^${user}|" "$ACTIVITY_FILE" 2>/dev/null | head -1)
        old_active=$(printf '%s' "$old_line" | cut -d'|' -f2)
        old_since=$(printf '%s' "$old_line" | cut -d'|' -f3)

        if [ "$rate" -ge "$thr" ] 2>/dev/null; then
            active=1
            if [ "$old_active" = "1" ] && [[ "$old_since" =~ ^[0-9]+$ ]] && [ "$old_since" -gt 0 ]; then
                since=$old_since        # серия продолжается — «первенство» сохраняем
            else
                since=$now              # новая активная серия
            fi
        else
            active=0; since=0
        fi
        printf '%s|%s|%s|%s\n' "$user" "$active" "$since" "$rate" >> "$newact"
    done <<< "$merged"

    mv "$newprev" "$ACTIVITY_PREV_FILE" 2>/dev/null
    mv "$newact" "$ACTIVITY_FILE" 2>/dev/null
}

# Активен ли юзер на ЭТОЙ ноде прямо сейчас (0/1) — по трафику за последнюю минуту.
get_user_active() {
    local v; v=$(grep "^${1}|" "$ACTIVITY_FILE" 2>/dev/null | head -1 | cut -d'|' -f2)
    [ "$v" = "1" ] && echo 1 || echo 0
}
# С какого момента идёт текущая активная серия (unix ts; 0 — не активен).
get_user_active_since() {
    local v; v=$(grep "^${1}|" "$ACTIVITY_FILE" 2>/dev/null | head -1 | cut -d'|' -f3)
    [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" || echo 0
}

# ---- Спидометр: «скорость прямо сейчас» (RATES_FILE) ----
# Отдельный узкий тик раз в RATES_TICK_SEC секунд. Почему не переиспользовать
# collect_activity: тот считает ещё active/active_since для жёсткой проверки и
# делает grep на КАЖДОГО юзера — на минутной каденции это нормально, на
# 15-секундной растёт с числом юзеров. Здесь всё одним проходом awk, поэтому
# стоимость тика — это стоимость опроса API протоколов (~0.45 c), почти не
# зависящая от размера базы.
collect_rates() {
    local now merged hy
    now=$(date +%s)
    hy=$(api_get "/traffic")   # без clear=1: сброс делает 30-минутный collect_traffic
    # Fail-safe как в collect_activity: API молчит — файлы НЕ трогаем, спидометр
    # покажет прошлое значение, а не фальшивый ноль.
    { [ -z "$hy" ] || [ "$hy" = "null" ]; } && return 0
    echo "$hy" | jq empty 2>/dev/null || return 0

    merged=$(
        {
            echo "$hy" | jq -r 'to_entries[] | "\(.key)|\((.value.tx // 0) + (.value.rx // 0))"' 2>/dev/null
            declare -F proto_activity_cum_lines >/dev/null 2>&1 && proto_activity_cum_lines 2>/dev/null
        } | awk -F'|' 'NF>=2 && $1!="" {s[$1]+=$2} END{for(u in s) printf "%s|%.0f\n", u, s[u]}'   # %.0f: mawk иначе пишет 2^31+ как «1.42856e+09»
    )
    [ -n "$merged" ] || return 0

    # Дельта с прошлым снимком одним проходом. Счётчик УМЕНЬШИЛСЯ (30-минутный
    # ?clear=1 обнулил Hysteria; закрылись TUIC-соединения) — считаем 0, а не
    # дельту от нуля: на спидометре фантомный всплеск заметнее, чем один
    # пропущенный тик раз в полчаса. Этим и отличаемся от collect_activity,
    # которому важнее не пропустить активность.
    printf '%s\n' "$merged" | awk -F'|' -v now="$now" -v prevf="$RATES_PREV_FILE" \
        -v rates="${RATES_FILE}.tmp" -v prevout="${RATES_PREV_FILE}.tmp" '
        BEGIN {
            while ((getline line < prevf) > 0) {
                n = split(line, p, "|")
                if (n >= 3) { pc[p[1]] = p[2] + 0; pt[p[1]] = p[3] + 0 }
            }
        }
        NF >= 2 && $1 != "" {
            cum = $2 + 0
            rate = 0
            if ($1 in pt) {
                el = now - pt[$1]
                if (el < 1) el = 1
                if (cum > pc[$1]) rate = int((cum - pc[$1]) / el)
            }
            printf "%s|%d|%d\n", $1, rate, now > rates
            printf "%s|%d|%d\n", $1, cum, now > prevout
        }'
    mv "${RATES_FILE}.tmp" "$RATES_FILE" 2>/dev/null
    mv "${RATES_PREV_FILE}.tmp" "$RATES_PREV_FILE" 2>/dev/null
}

# Мгновенная скорость юзера на ЭТОЙ ноде (байт/сек) из RATES_FILE.
get_user_rate() {
    local v; v=$(grep "^${1}|" "$RATES_FILE" 2>/dev/null | head -1 | cut -d'|' -f2)
    [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" || echo 0
}

# Юнит-таймер тика. Ставится сам при первом же прогоне после обновления —
# отдельного шага установки на нодах не нужно.
RATES_UNIT="/etc/systemd/system/hy2-rates.service"
RATES_TIMER="/etc/systemd/system/hy2-rates.timer"
rates_timer_ensure() {
    local want="OnUnitActiveSec=${RATES_TICK_SEC}s"
    grep -q "^${want}$" "$RATES_TIMER" 2>/dev/null && return 0
    cat > "$RATES_UNIT" <<EOF
[Unit]
Description=hy2-manager: пересчёт текущей скорости юзеров (спидометр мини-аппа)

[Service]
Type=oneshot
ExecStart=/bin/bash ${SCRIPT_DIR}/hy2-manager.sh --rates-tick
EOF
    cat > "$RATES_TIMER" <<EOF
[Unit]
Description=hy2-manager: тик скорости каждые ${RATES_TICK_SEC}s

[Timer]
OnBootSec=30s
${want}
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload 2>/dev/null
    systemctl enable --now hy2-rates.timer &>/dev/null
}

# Текущая скорость пользователя: "user|tx_rate|rx_rate" в байт/сек
get_user_speed() {
    local line
    line=$(grep "^${1}|" "$SPEED_FILE" 2>/dev/null | head -1)
    if [ -n "$line" ]; then
        echo "$line"
    else
        echo "${1}|0|0"
    fi
}

get_user_traffic() {
    local line
    line=$(grep "^${1}|" "$STATS_FILE" 2>/dev/null | head -1)
    if [ -n "$line" ]; then
        echo "$line"
    else
        echo "${1}|0|0"
    fi
}

format_bytes() {
    local bytes=${1:-0}
    [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
    if [ "$bytes" -ge 1073741824 ]; then
        awk "BEGIN {printf \"%.1fG\", $bytes / 1073741824}"
    elif [ "$bytes" -ge 1048576 ]; then
        awk "BEGIN {printf \"%.1fM\", $bytes / 1048576}"
    elif [ "$bytes" -ge 1024 ]; then
        awk "BEGIN {printf \"%.1fK\", $bytes / 1024}"
    else
        echo "${bytes}B"
    fi
}

# Компактная скорость для таблицы: 1.2M, 340K, 12 (B/s), без суффикса «/s»
format_speed_short() {
    local bps=${1:-0}
    [[ "$bps" =~ ^[0-9]+$ ]] || bps=0
    if [ "$bps" -ge 1048576 ]; then
        awk "BEGIN {printf \"%.1fM\", $bps / 1048576}"
    elif [ "$bps" -ge 1024 ]; then
        awk "BEGIN {printf \"%.0fK\", $bps / 1024}"
    else
        echo "${bps}"
    fi
}

# Скорость в человекочитаемом виде: B/s, KiB/s, MiB/s (двоичные единицы)
format_speed() {
    local bps=${1:-0}
    [[ "$bps" =~ ^[0-9]+$ ]] || bps=0
    if [ "$bps" -ge 1048576 ]; then
        awk "BEGIN {printf \"%.2f MiB/s\", $bps / 1048576}"
    elif [ "$bps" -ge 1024 ]; then
        awk "BEGIN {printf \"%.2f KiB/s\", $bps / 1024}"
    else
        echo "${bps} B/s"
    fi
}
