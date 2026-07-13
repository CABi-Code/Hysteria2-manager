#!/bin/bash
# ================================================
# Производительность и защита слабого сервера.
#
# Пишет в config.yaml ЭТОЙ ноды три вещи:
#   1) bandwidth: up/down — ПОТОЛОК СКОРОСТИ НА КАЖДОГО клиента (up = скачивание
#      клиента, down = отдача). Пусто/снято = без лимита. Это прямой ограничитель:
#      ни один клиент не выжмет больше и не положит CPU/канал слабого сервера.
#   2) ignoreClientBandwidth: true/false — режим управления перегрузкой. false =
#      Brutal/по заявке клиента (с жёстким потолком из п.1). true = сервер
#      игнорирует заявленную клиентом скорость и делит канал ЧЕСТНО (BBR) —
#      полезно, когда один жадный клиент душит остальных.
#   3) quic: recv-окна — размер буферов. Большие окна = выше пик throughput, но
#      больше памяти на поток (на 2 ГБ ОЗУ один быстрый клиент раздувает буферы).
#      Профиль «Слабый сервер» ставит щадящие окна.
#
# Параметры ЗАВИСЯТ ОТ ЖЕЛЕЗА ноды, поэтому НЕ синхронизируются по кластеру —
# задаются на каждой ноде отдельно. Любое изменение требует разового перезапуска
# Hysteria (используется общий механизм mark_restart_pending / restart_hysteria).
# ================================================

# Наборы QUIC recv-окон: (initStream maxStream initConn maxConn idle keepalive).
# NORMAL — как в install.sh (большой throughput). WEAK — щадящий для 1 ядра/2 ГБ:
# окна меньше (меньше памяти/CPU на поток), но 32 MiB на соединение при RTT 100мс
# это всё ещё сотни Мбит/с — на слабый сервер с запасом.
QUIC_NORMAL=(16777216 1073741824 33554432 1073741824 30s 10s)
QUIC_WEAK=(8388608 16777216 16777216 33554432 30s 10s)

# ---- Чтение текущих значений из config.yaml ----
# Значение под-ключа из top-level блока (bandwidth/quic). Пусто, если нет.
_perf_block_get() {   # block field
    awk -v b="$1" -v f="$2" '
        $0 ~ "^"b":" {inb=1; next}
        inb && /^[^[:space:]]/ {inb=0}
        inb && $0 ~ "^[[:space:]]+"f":" { sub(/^[[:space:]]+[^:]+:[[:space:]]*/,""); print; exit }
    ' "$CONFIG" 2>/dev/null
}
bw_up_get()    { _perf_block_get bandwidth up; }
bw_down_get()  { _perf_block_get bandwidth down; }
quic_get()     { _perf_block_get quic "$1"; }
icbw_get()     { grep -oP '^ignoreClientBandwidth:\s*\K\S+' "$CONFIG" 2>/dev/null | head -1; }

# ---- Правка config.yaml (surgical: удалить top-level ключ/блок + дописать заново) ----
# Удаляет top-level ключ key: и все его вложенные (с отступом) строки.
_perf_del_block() {   # key
    local key="$1" tmp
    tmp=$(mktemp) || return 1
    awk -v k="$key" '
        $0 ~ "^"k":" { skip=1; next }          # начало (или повтор) блока — вырезаем
        skip && /^[[:space:]]/ { next }          # вложенные строки блока — вырезаем
        { skip=0; print }                        # top-level строка — блок кончился
    ' "$CONFIG" > "$tmp" && cat "$tmp" > "$CONFIG"
    rm -f "$tmp"
}

_perf_backup() { cp -a "$CONFIG" "${CONFIG}.perfbak" 2>/dev/null; }
# Базовая целостность конфига после правки (иначе откат из бэкапа).
_perf_sane()   { grep -q '^listen:' "$CONFIG" && grep -q '^auth:' "$CONFIG" && grep -q '^tls:' "$CONFIG"; }
_perf_restore(){ [ -f "${CONFIG}.perfbak" ] && cp -a "${CONFIG}.perfbak" "$CONFIG" 2>/dev/null; }
# Схлопнуть повторные пустые строки (удаление+дозапись блоков их плодит). cat -s
# трогает только пустые строки — YAML не ломает.
_perf_tidy()   { local t; t=$(mktemp) && cat -s "$CONFIG" > "$t" && cat "$t" > "$CONFIG"; rm -f "$t"; }

# Установить лимит скорости на клиента. up/down — строки вида "30 mbps" (пусто =
# сторона без лимита). Оба пустые -> блок bandwidth снимается (без лимита).
set_bandwidth() {   # up down
    _perf_backup
    _perf_del_block bandwidth
    local up="$1" down="$2"
    if [ -n "$up" ] || [ -n "$down" ]; then
        {   echo ""
            echo "bandwidth:"
            [ -n "$up" ]   && echo "  up: $up"
            [ -n "$down" ] && echo "  down: $down"
        } >> "$CONFIG"
    fi
    _perf_tidy
    _perf_sane || { _perf_restore; return 1; }
    mark_restart_pending
}

# Режим управления перегрузкой: true = BBR-честность, false = Brutal/по клиенту.
set_ignore_client_bw() {   # true|false
    _perf_backup
    _perf_del_block ignoreClientBandwidth
    case "$1" in
        true|false) { echo ""; echo "ignoreClientBandwidth: $1"; } >> "$CONFIG" ;;
    esac
    _perf_tidy
    _perf_sane || { _perf_restore; return 1; }
    mark_restart_pending
}

# Переписать блок quic: шестью значениями (initStream maxStream initConn maxConn idle keepalive).
set_quic() {
    _perf_backup
    _perf_del_block quic
    {   echo ""
        echo "quic:"
        echo "  initStreamReceiveWindow: $1"
        echo "  maxStreamReceiveWindow: $2"
        echo "  initConnReceiveWindow: $3"
        echo "  maxConnReceiveWindow: $4"
        echo "  maxIdleTimeout: $5"
        echo "  keepAlivePeriod: $6"
    } >> "$CONFIG"
    _perf_tidy
    _perf_sane || { _perf_restore; return 1; }
    mark_restart_pending
}

# Применить готовый набор QUIC-окон по имени профиля (weak|normal).
apply_quic_profile() {   # weak|normal
    case "$1" in
        weak)   set_quic "${QUIC_WEAK[@]}" ;;
        normal) set_quic "${QUIC_NORMAL[@]}" ;;
        *) return 1 ;;
    esac
}
