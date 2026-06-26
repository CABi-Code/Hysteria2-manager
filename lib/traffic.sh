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
