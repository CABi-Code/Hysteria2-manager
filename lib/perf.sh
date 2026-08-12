#!/bin/bash
# ================================================
# Производительность и защита слабого сервера.
#
# ВАЖНО — как НА САМОМ ДЕЛЕ работает лимит скорости в Hysteria 2:
#   Серверный bandwidth (up/down) применяется ТОЛЬКО к клиентам, которые сами
#   прислали свою полосу (Brutal-переговоры: итог = min(клиент, сервер)).
#   Клиенты, добавленные по ссылке hysteria2:// (Hiddify/Nekobox/Streisand),
#   полосу НЕ шлют → сервер использует BBR → серверный bandwidth ИГНОРИРУЕТСЯ.
#   Именно поэтому «лимит 10 Мбит» раньше не работал и спидтест показывал сотни
#   мегабит, укладывая 1-ядерный сервер в 100% CPU.
#
# Поэтому лимит теперь ДВУХУРОВНЕВЫЙ:
#   1) Hysteria bandwidth + ignoreClientBandwidth:false — вежливый потолок для
#      клиентов с Brutal (пишется в config.yaml, применяется после рестарта).
#   2) Kernel-лимит — РЕАЛЬНЫЙ потолок для всех, включая BBR-клиентов, на каждый
#      IP клиента. Работает сразу, без рестарта Hysteria, переживает ребут
#      (systemd-юнит hy2-limit). Реализован через tc (HTB + fq_codel) — это
#      ШЕЙПИНГ: пакеты сверх скорости придерживаются в очереди и выдаются ровно
#      на заданной полосе, БЕЗ потери пакетов. (Раньше был дроп-полисинг nftables:
#      он резал пакеты сверх лимита, а для QUIC это = потеря пакетов, обрывы,
#      socket error в спидтесте. Дроп оставлен только фолбэком, если нет tc/HTB.)
#
# Плюс защита слабого сервера:
#   - щадящие QUIC recv-окна (меньше памяти на поток);
#   - системный тюнинг: CPUQuota (Hysteria не съест 100% CPU и не повесит SSH),
#     GOMEMLIMIT (Go-runtime не раздувается на 2 ГБ ОЗУ);
#   - sysctl-буферы UDP (rmem/wmem) — убирает «failed to set receive buffer»
#     и потери пакетов на бурстах.
#
# Параметры зависят от железа ноды и по кластеру НЕ синхронизируются.
# ================================================

# Наборы QUIC recv-окон: (initStream maxStream initConn maxConn idle keepalive).
# Дефолты Hysteria: 8/8 MiB stream, 20/20 MiB conn.
# NORMAL — большие окна для мощного сервера, но ОГРАНИЧЕННЫЕ сверху (раньше max
# был 1 GiB — пара быстрых клиентов могла раздуть память на все 2 ГБ ОЗУ).
# WEAK — щадящие окна для 1 ядра / 2 ГБ: 8 MiB на stream при RTT 100 мс — это
# всё ещё ~600 Мбит/с на поток, слабому серверу хватает с запасом.
QUIC_NORMAL=(8388608 33554432 20971520 67108864 30s 10s)
QUIC_WEAK=(2097152 8388608 8388608 16777216 30s 10s)

# Файлы kernel-лимита и системного тюнинга.
KLIMIT_CONF="$DATA_DIR/klimit.conf"          # DOWN_MBIT / UP_MBIT / PORT / TIERS / TARIFFS
KLIMIT_SCRIPT="$DATA_DIR/klimit.sh"          # применяет/снимает tc/nft-правила
KLIMIT_SIG="$DATA_DIR/klimit_reconcile.sig"  # подпись последней раскладки IP→тариф (klimit_reconcile)
KLIMIT_UNIT="/etc/systemd/system/hy2-limit.service"
PERF_DROPIN_DIR="/etc/systemd/system/${SERVICE}.d"
PERF_DROPIN="$PERF_DROPIN_DIR/zz-hy2-perf.conf"
PERF_SYSCTL="/etc/sysctl.d/99-hy2-quic.conf"

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

# «10 mbps» / «1 gbps» / «500 kbps» → целые Мбит/с (пусто/не распарсилось → 0).
bw_to_mbps() {
    local v="$1" n unit
    n=$(printf '%s' "$v" | grep -oE '^[0-9]+' | head -1)
    [ -n "$n" ] || { echo 0; return; }
    unit=$(printf '%s' "$v" | grep -oiE '[kmgt]bps' | head -1 | tr 'A-Z' 'a-z')
    case "$unit" in
        gbps) echo $(( n * 1000 )) ;;
        kbps) echo $(( n / 1000 )) ;;
        tbps) echo $(( n * 1000000 )) ;;
        *)    echo "$n" ;;
    esac
}

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
_perf_restore(){ [ -f "${CONFIG}.perfbak" ] && cp -a "${CONFIG}.perfbak" "$CONFIG" 2>/dev/null; }

# Целостность конфига после правки. Обязательные секции на месте + валидный YAML
# (если на сервере есть python3 c PyYAML — почти везде есть; иначе только grep).
_perf_sane() {
    grep -q '^listen:' "$CONFIG" && grep -q '^auth:' "$CONFIG" && grep -q '^tls:' "$CONFIG" || return 1
    if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
        python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$CONFIG" 2>/dev/null || return 1
    fi
    return 0
}

# Схлопнуть повторные пустые строки (удаление+дозапись блоков их плодит). cat -s
# трогает только пустые строки — YAML не ломает.
_perf_tidy()   { local t; t=$(mktemp) && cat -s "$CONFIG" > "$t" && cat "$t" > "$CONFIG"; rm -f "$t"; }

# Финал каждой правки: прибрать, проверить целостность (иначе откат), пометить рестарт.
_perf_commit() {
    _perf_tidy
    if ! _perf_sane; then
        _perf_restore
        return 1
    fi
    mark_restart_pending
    return 0
}

# Установить лимит скорости на клиента в КОНФИГЕ Hysteria. up/down — строки вида
# "30 mbps" (пусто = сторона без лимита). Оба пустые -> блок bandwidth снимается.
# При УСТАНОВКЕ лимита принудительно выключаем ignoreClientBandwidth: потолок
# работает только в режиме Brutal-переговоров; в BBR-режиме он игнорируется.
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
        # Лимит без Brutal не работает — форсируем правильный режим сразу же,
        # а не через отдельный пункт меню (раньше об этом легко было забыть).
        _perf_del_block ignoreClientBandwidth
        { echo ""; echo "ignoreClientBandwidth: false"; } >> "$CONFIG"
    fi
    _perf_commit || return 1
    # Проверяем, что записанное реально читается обратно из конфига.
    if [ -n "$up" ]   && [ "$(bw_up_get)" != "$up" ];   then _perf_restore; return 1; fi
    if [ -n "$down" ] && [ "$(bw_down_get)" != "$down" ]; then _perf_restore; return 1; fi
    return 0
}

# Режим управления перегрузкой: true = BBR-честность, false = Brutal/по клиенту.
set_ignore_client_bw() {   # true|false
    _perf_backup
    _perf_del_block ignoreClientBandwidth
    case "$1" in
        true|false) { echo ""; echo "ignoreClientBandwidth: $1"; } >> "$CONFIG" ;;
    esac
    _perf_commit || return 1
    [ -n "$1" ] && [ "$(icbw_get)" != "$1" ] && { _perf_restore; return 1; }
    return 0
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
    _perf_commit || return 1
    [ "$(quic_get initStreamReceiveWindow)" = "$1" ] || { _perf_restore; return 1; }
    return 0
}

# Применить готовый набор QUIC-окон по имени профиля (weak|normal).
apply_quic_profile() {   # weak|normal
    case "$1" in
        weak)   set_quic "${QUIC_WEAK[@]}" ;;
        normal) set_quic "${QUIC_NORMAL[@]}" ;;
        *) return 1 ;;
    esac
}

# ================================================================
# KERNEL-ЛИМИТ (nftables): реальный потолок скорости на КАЖДЫЙ IP клиента.
# Работает для ЛЮБЫХ клиентов (в т.ч. BBR), сразу, без рестарта Hysteria.
# ================================================================

klimit_get() { conf_get "$KLIMIT_CONF" "$1"; }
klimit_down() { local v; v=$(klimit_get DOWN_MBIT); [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" || echo 0; }
klimit_up()   { local v; v=$(klimit_get UP_MBIT);   [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" || echo 0; }
# Потолок ВСЕЙ ноды на туннельный трафик, Мбит/с. 0 = не ограничивать (физический
# потолок — сам аплинк). Держит сумму пер-IP классов: сто клиентов по 30 не
# вынесут канал, если тут стоит осмысленное число. Правится в klimit.conf и
# переживает перегенерацию — klimit_apply читает старое значение перед записью.
KLIMIT_NODE_DEFAULT=10000
klimit_node() { local v; v=$(klimit_get NODE_MBIT); [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -gt 0 ] && echo "$v" || echo "$KLIMIT_NODE_DEFAULT"; }

# Активен ли kernel-лимит прямо сейчас? Основной сигнал — oneshot-юнит hy2-limit
# успешно применился (RemainAfterExit); плюс прямые проверки tc/nft/iptables на
# случай запуска вне systemd.
klimit_active() {
    systemctl is-active --quiet hy2-limit.service 2>/dev/null && return 0
    if command -v tc >/dev/null 2>&1 && command -v ip >/dev/null 2>&1; then
        local d; d=$(ip -o route show default 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)
        [ -n "$d" ] && tc qdisc show dev "$d" 2>/dev/null | grep -q 'htb 1:' && return 0
    fi
    command -v nft >/dev/null 2>&1 && nft list table inet hy2limit &>/dev/null && return 0
    command -v iptables >/dev/null 2>&1 && iptables -S HY2LIMIT_OUT &>/dev/null && return 0
    return 1
}

# Генерирует скрипт применения лимита и systemd-юнит для восстановления после ребута.
#
# ГЛАВНОЕ: лимит теперь ШЕЙПИТ (tc HTB + fq_codel), а не ДРОПАЕТ. Раньше kernel-лимит
# резал пакеты сверх скорости (nft/iptables ... drop) — для UDP/QUIC это прямая потеря
# пакетов: спидтест писал socket error, страницы «то грузят, то нет». tc вместо дропа
# ставит пакеты в очередь и выдаёт их РОВНО на заданной скорости (fq_codel держит
# задержку низкой) — данные идут БЕЗ потерь. Дроп-полисинг (nft/iptables) оставлен
# только фолбэком, если в системе нет tc/HTB.
#   • Скачивание (сервер->клиент): шейпим egress реального интерфейса, класс на IP клиента.
#   • Отдача (клиент->сервер): ingress нельзя шейпить напрямую — заворачиваем на IFB и
#     шейпим там. Если IFB недоступен — на отдачу падаем в дроп-фолбэк.
#   • Классы (htb rate=ceil, листовой fq_codel): общий класс туннеля + по классу на каждый
#     тариф из TARIFFS; пер-IP раскладку по тарифным классам ставит klimit_reconcile.
#     Не-туннельный трафик (SSH, сайт-маскировка) идёт в дефолт-класс на полной
#     скорости — ничего лишнего не режем.
#   • IPv4 шейпится через tc; IPv6-клиентов (редко) добираем лёгким nft-дропом, чтобы
#     они не проходили мимо лимита.
# down_mbit — скачивание клиента (сервер -> клиент), up_mbit — отдача клиента.
_klimit_write_script() {   # down_mbit up_mbit port [tariffs] [shape] [node_mbit]
    local down="$1" up="$2" port="$3" tariffs="$4" shape="$5" node="$6"
    [[ "$node" =~ ^[0-9]+$ ]] && [ "$node" -gt 0 ] || node="$KLIMIT_NODE_DEFAULT"
    # Для дроп-фолбэка (nft/iptables): Мбит/с -> KiB/s (~13% запас на заголовки).
    local dkb=$(( down * 138 ))
    local ukb=$(( up * 138 ))
    local dburst=$(( dkb / 4 )); [ "$dburst" -lt 256 ] && dburst=256
    local uburst=$(( ukb / 4 )); [ "$uburst" -lt 256 ] && uburst=256

    {
        echo '#!/bin/bash'
        echo "# Сгенерировано hy2-manager. Пер-IP ПОТОЛОК скорости (шейпинг, без потерь) для порта ${port}/udp."
        echo "# apply — включить, clear — выключить. Идемпотентно."
        echo "PORT=${port}"
        echo "SHAPE=\"${shape}\"   # protonum:port всех шейпимых протоколов (17=udp,6=tcp); пусто -> 17:PORT"
        echo "DMBIT=${down}    # Мбит/с на IP: скачивание клиента, дефолт-класс туннеля (0 = без лимита)"
        echo "UMBIT=${up}      # Мбит/с на IP: отдача клиента,     дефолт-класс туннеля (0 = без лимита)"
        echo "NODEMBIT=${node}   # потолок ВСЕЙ ноды на туннельный трафик (класс 1:1, родитель пер-IP классов)"
        echo "TARIFFS=\"${tariffs}\"   # тарифные тиры (Мбит) — по классу на каждый; пер-IP раскладку ставит klimit_reconcile"
        echo "DKB=${dkb} UKB=${ukb} DBURST=${dburst} UBURST=${uburst}   # для дроп-фолбэка"
        echo "IFB=ifb-hy2"
        echo "SIG=${KLIMIT_SIG}   # подпись раскладки IP→тариф: apply её СНОСИТ, чтобы klimit_reconcile"
        echo "                    # заново разложил пер-IP фильтры (apply пересобирает каркас и стирает prio-1)"
        # Дальше — статичное тело (ничего не подставляем: 'KEOF' в кавычках).
        cat <<'KEOF'

# ---- Основной путь: tc-ШЕЙПИНГ (очередь, без дропов) --------------------------

detect_dev() {
    command -v ip >/dev/null 2>&1 || return 1
    DEV=$(ip -o route show default 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)
    [ -n "$DEV" ]
}

# Есть ли рабочий tc с htb + fq_codel (пробуем на реальном DEV и сразу убираем).
# ВАЖНО: fq_codel вешаем на КЛАСС, а не на qdisc напрямую — поэтому класс 1:9999
# надо создать перед пробой (как это делает shape()). Без него tc отвечает
# "Specified class not found", проба падала → лимит уходил в дроп-фолбэк (nft),
# а дроп для QUIC = обрывы и socket error в спидтесте.
tc_ok() {
    command -v tc >/dev/null 2>&1 || return 1
    # Идемпотентность: если от прошлого apply остался root-qdisc, `add root` упал бы
    # ("Exclusivity flag on"), проба вернула бы ошибку и весь лимит сорвался бы в
    # дроп-фолбэк, хотя tc исправен. Сносим остаток перед пробой (tc_apply всё равно
    # чистит и пересобирает заново).
    tc qdisc del dev "$DEV" root 2>/dev/null
    tc qdisc add dev "$DEV" root handle 1: htb default 9999 2>/dev/null || return 1
    tc class add dev "$DEV" parent 1: classid 1:9999 htb rate 10000mbit ceil 10000mbit 2>/dev/null
    tc qdisc add dev "$DEV" parent 1:9999 fq_codel 2>/dev/null; local rc=$?
    tc qdisc del dev "$DEV" root 2>/dev/null
    return $rc
}

# Строит дерево классов на устройстве $1 для ОДНОГО направления:
#   1:9999 — без лимита (не-туннельный трафик: SSH, маскировка-сайт) = htb default
#   1:1    — ПОТОЛОК НОДЫ ($NODEMBIT Мбит) на весь туннельный трафик. Класс
#            внутренний: листового qdisc у него нет, под ним живут дети.
#   1:ffff — общий класс направления ($2 Мбит) для туннельного трафика с адреса,
#            которого нет в раскладке. Цель catch-all (prio 2).
#   1:2xxx — по классу НА КАЖДЫЙ активный адрес; их ставит klimit_reconcile.
# $3/$4 — селектор порта туннеля (sport/PORT для скачивания, dport/PORT для отдачи).
#
# Класс на АДРЕС, а не на величину тарифа. Раньше classid считался из скорости
# (0x1000+rate), поэтому все адреса одного тарифа делили один класс, а все
# бестарифные — один класс 1:1 на всю ноду: десять человек онлайн при лимите 30
# получали по 3 Мбит/с вместо 30 каждый. Запасные пути (nft meter по ip daddr,
# iptables --hashlimit-mode dstip) всегда считали по адресу — теперь и tc.
build_dev() {   # dev global_mbit portsel portval
    local D="$1" G="$2" PSEL="$3" PV="$4" GG
    # Гарантия = десятая доля потолка (не меньше 1): всё сверх неё класс занимает
    # у родителя, и только так потолок ноды вообще действует. Та же формула — в
    # _klimit_guarantee (perf.sh) для пер-IP классов.
    GG=$(( G / 10 )); [ "$GG" -lt 1 ] && GG=1
    tc qdisc add dev "$D" root handle 1: htb default 9999 || return 1
    tc class add dev "$D" parent 1: classid 1:9999 htb rate 10000mbit ceil 10000mbit || return 1
    tc qdisc add dev "$D" parent 1:9999 fq_codel
    tc class add dev "$D" parent 1: classid 1:1 htb rate "${NODEMBIT}mbit" ceil "${NODEMBIT}mbit" || return 1
    tc class add dev "$D" parent 1:1 classid 1:ffff htb rate "${GG}mbit" ceil "${G}mbit" || return 1
    tc qdisc add dev "$D" parent 1:ffff fq_codel
    # catch-all: весь туннель (все протоколы/порты из SHAPE) без пер-IP правила
    # -> общий класс 1:ffff. SHAPE = список "protonum:port" (17=udp, 6=tcp);
    # фолбэк на один udp/PORT, если SHAPE пуст (старый конфиг без мультипротокола).
    local _tok _pr _po
    [ -n "$SHAPE" ] || SHAPE="17:${PORT}"
    for _tok in $SHAPE; do
        _pr=${_tok%%:*}; _po=${_tok##*:}
        tc filter add dev "$D" parent 1: prio 2 protocol ip u32 \
            match ip protocol "$_pr" 0xff match ip "$PSEL" "$_po" 0xffff flowid 1:ffff || return 1
    done
}

# Ingress реального DEV зеркалим на IFB, чтобы ШЕЙПИТЬ отдачу (иначе только дроп).
setup_ifb() {
    command -v ip >/dev/null 2>&1 || return 1
    modprobe ifb numifbs=0 2>/dev/null
    ip link show "$IFB" >/dev/null 2>&1 || ip link add "$IFB" type ifb 2>/dev/null || return 1
    ip link set "$IFB" up 2>/dev/null || return 1
    tc qdisc add dev "$DEV" handle ffff: ingress 2>/dev/null
    # Зеркалим ingress по всем протоколам/портам из SHAPE (dport = порт сервера).
    local _tok _pr _po
    [ -n "$SHAPE" ] || SHAPE="17:${PORT}"
    for _tok in $SHAPE; do
        _pr=${_tok%%:*}; _po=${_tok##*:}
        tc filter add dev "$DEV" parent ffff: protocol ip prio 1 u32 \
            match ip protocol "$_pr" 0xff match ip dport "$_po" 0xffff \
            action mirred egress redirect dev "$IFB" 2>/dev/null || return 1
    done
}

tc_clear() {
    if command -v tc >/dev/null 2>&1; then
        [ -n "$DEV" ] && { tc qdisc del dev "$DEV" root 2>/dev/null; tc qdisc del dev "$DEV" ingress 2>/dev/null; }
        tc qdisc del dev "$IFB" root 2>/dev/null
    fi
    command -v ip >/dev/null 2>&1 && ip link del "$IFB" 2>/dev/null
}

tc_apply() {   # -> 0 ок; 1 не смогли (нужен фолбэк); 2 отдача без шейпинга (нужен дроп на up)
    tc_clear
    local hastar=0 dg ug
    [ -n "$TARIFFS" ] && hastar=1
    dg=$DMBIT; [ "$dg" -gt 0 ] 2>/dev/null || dg=10000   # нет глоб. лимита -> дефолт туннеля без лимита
    ug=$UMBIT; [ "$ug" -gt 0 ] 2>/dev/null || ug=10000
    # Строим классы, если есть глобальный лимит стороны ИЛИ хотя бы один тариф
    # (тарифным классам нужен каркас на обоих направлениях).
    if [ "$DMBIT" -gt 0 ] || [ "$hastar" = 1 ]; then
        build_dev "$DEV" "$dg" sport "$PORT" || { tc_clear; return 1; }
    fi
    if [ "$UMBIT" -gt 0 ] || [ "$hastar" = 1 ]; then
        if setup_ifb && build_dev "$IFB" "$ug" dport "$PORT"; then :; else return 2; fi
    fi
    return 0
}

# ---- Фолбэк: ДРОП-полисинг (nft, затем iptables+hashlimit) --------------------
# Хуже шейпинга (режет пакеты), но лучше, чем совсем без лимита. Семейство на каждую
# сторону задаётся отдельно: skip = без правил, v6 = только IPv6 (добор к tc-шейпингу
# IPv4), all = IPv4+IPv6 (полный дроп там, где tc не сработал).

nft_apply() {   # dlfam ulfam ; fam = skip|v6|all
    local dlf="$1" ulf="$2" dl_rules="" ul_rules=""
    if [ "$DMBIT" -gt 0 ]; then
        [ "$dlf" = all ] && dl_rules="udp sport $PORT meter hy2dl4 size 65535 { ip daddr timeout 2m limit rate over $DKB kbytes/second burst $DBURST kbytes } counter drop"
        [ "$dlf" = skip ] || dl_rules="$dl_rules
        udp sport $PORT meter hy2dl6 size 65535 { ip6 daddr timeout 2m limit rate over $DKB kbytes/second burst $DBURST kbytes } counter drop"
    fi
    if [ "$UMBIT" -gt 0 ]; then
        [ "$ulf" = all ] && ul_rules="udp dport $PORT meter hy2ul4 size 65535 { ip saddr timeout 2m limit rate over $UKB kbytes/second burst $UBURST kbytes } counter drop"
        [ "$ulf" = skip ] || ul_rules="$ul_rules
        udp dport $PORT meter hy2ul6 size 65535 { ip6 saddr timeout 2m limit rate over $UKB kbytes/second burst $UBURST kbytes } counter drop"
    fi
    nft -f - <<NFT
table inet hy2limit
delete table inet hy2limit
table inet hy2limit {
    chain download {
        type filter hook output priority filter; policy accept;
        $dl_rules
    }
    chain upload {
        type filter hook input priority filter; policy accept;
        $ul_rules
    }
}
NFT
}

ipt_clear() {
    iptables -D OUTPUT -p udp --sport "$PORT" -j HY2LIMIT_OUT 2>/dev/null
    iptables -D INPUT  -p udp --dport "$PORT" -j HY2LIMIT_IN  2>/dev/null
    iptables -F HY2LIMIT_OUT 2>/dev/null; iptables -X HY2LIMIT_OUT 2>/dev/null
    iptables -F HY2LIMIT_IN  2>/dev/null; iptables -X HY2LIMIT_IN  2>/dev/null
}

ipt_apply() {
    ipt_clear
    if [ "$DKB" -gt 0 ]; then
        iptables -N HY2LIMIT_OUT 2>/dev/null
        iptables -A HY2LIMIT_OUT -m hashlimit --hashlimit-name hy2dl --hashlimit-mode dstip \
            --hashlimit-above "${DKB}kb/s" --hashlimit-burst "${DBURST}kb" -j DROP
        iptables -I OUTPUT -p udp --sport "$PORT" -j HY2LIMIT_OUT
    fi
    if [ "$UKB" -gt 0 ]; then
        iptables -N HY2LIMIT_IN 2>/dev/null
        iptables -A HY2LIMIT_IN -m hashlimit --hashlimit-name hy2ul --hashlimit-mode srcip \
            --hashlimit-above "${UKB}kb/s" --hashlimit-burst "${UBURST}kb" -j DROP
        iptables -I INPUT -p udp --dport "$PORT" -j HY2LIMIT_IN
    fi
}

case "$1" in
    apply)
        # Пересборка каркаса (на бут/рестарт сервиса hy2-limit) стирает пер-IP
        # раскладку тарифов (prio-1). Сносим подпись, чтобы следующий проход
        # klimit_reconcile (cron/rates-tick, ≤15с) НЕ счёл раскладку актуальной и
        # разложил фильтры заново — иначе после ребута тарифные клиенты молча
        # уезжают в глобальный класс вместо своего лимита.
        rm -f "$SIG" 2>/dev/null
        DEV=""
        if detect_dev && tc_ok; then
            tc_apply; rc=$?
            if [ "$rc" = 0 ]; then
                # IPv4 (обе стороны) шейпится tc; IPv6-клиентов добираем дропом (если есть nft).
                command -v nft >/dev/null 2>&1 && nft_apply v6 v6 2>/dev/null
                exit 0
            elif [ "$rc" = 2 ]; then
                # Скачивание шейпится tc (IPv4); отдачу шейпить не вышло — её дропаем.
                if command -v nft >/dev/null 2>&1; then nft_apply v6 all 2>/dev/null
                else ipt_apply 2>/dev/null; fi   # ipt-порог выше tc-скорости -> скачивание не режет
                exit 0
            else
                tc_clear   # tc не смог — полный дроп-фолбэк ниже
            fi
        fi
        # Полный дроп-фолбэк: tc недоступен/не сработал.
        if command -v nft >/dev/null 2>&1; then nft_apply all all; else ipt_apply; fi ;;
    clear)
        DEV=""; detect_dev 2>/dev/null
        command -v tc >/dev/null 2>&1 && tc_clear
        command -v nft >/dev/null 2>&1 && nft delete table inet hy2limit 2>/dev/null
        command -v iptables >/dev/null 2>&1 && ipt_clear
        exit 0 ;;
    *) echo "usage: $0 apply|clear"; exit 1 ;;
esac
KEOF
    } > "$KLIMIT_SCRIPT"
    chmod 750 "$KLIMIT_SCRIPT"
}

_klimit_write_unit() {
    cat > "$KLIMIT_UNIT" <<EOF
[Unit]
Description=Hysteria2 per-client kernel speed limit (hy2-manager)
After=network-pre.target nftables.service ufw.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash ${KLIMIT_SCRIPT} apply
ExecStop=/bin/bash ${KLIMIT_SCRIPT} clear
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload 2>/dev/null
}

# ---- Тарифные тиры (доступные пресеты скорости) ----
# Набор классов скорости, для которых строится HTB-каркас. По умолчанию 100/200/500.
# Хранится в KLIMIT_CONF (TIERS). Эффективный набор (TARIFFS) = тиры ∪ фактически
# назначенные юзерам ставки — так у любого назначенного тарифа гарантированно есть класс.
klimit_tiers() {
    local t; t=$(klimit_get TIERS)
    [ -n "$t" ] && echo "$t" || echo "100 200 500"
}
klimit_set_tiers() {   # "100 200 500"
    local list; list=$(printf '%s' "$1" | tr ',' ' ' | tr -s ' ')
    KLIMIT_SET_TIERS="$list"   # подхватит klimit_apply ниже
    klimit_apply "$(klimit_down)" "$(klimit_up)"
}
# Проверка: rate есть среди классов TARIFFS ($2 — список).
# Есть ли хоть у одного юзера ненулевой тариф.
_any_user_tariff() {
    local u
    while IFS= read -r u; do
        [ -n "$u" ] || continue
        [ "$(get_user_rate "$u")" -gt 0 ] 2>/dev/null && return 0
    done < <(get_all_users)
    return 1
}
# Эффективный набор тарифов = тиры ∪ распределённые ставки юзеров (Мбит, sort -n -u).
_all_rates() {   # tiers_list
    {   printf '%s\n' $1
        local u
        while IFS= read -r u; do [ -n "$u" ] && get_user_rate "$u"; done < <(get_all_users)
    } | grep -E '^[0-9]+$' | awk '$1>0' | sort -n -u | tr '\n' ' ' | sed 's/ *$//'
}

# Список "protonum:port" всех протоколов, которые шейпим (17=udp, 6=tcp).
# Hysteria всегда (udp, $1=порт). Доп. протоколы — только включённые. По этому
# списку строятся catch-all и пер-IP tc-фильтры, поэтому лимит скорости (и
# глобальный, и пер-IP тариф) действует на VLESS/SS/Trojan/TUIC так же, как на
# Hysteria. Раньше шейпился только udp-порт Hysteria — остальные шли мимо лимита.
_klimit_shape_ports() {   # hysteria_port
    local out="17:$1" p
    if declare -F proto_tuic_enabled >/dev/null 2>&1 && proto_tuic_enabled; then
        p=$(proto_tuic_port); out="$out 17:$p"
    fi
    if declare -F proto_ss_enabled >/dev/null 2>&1 && proto_ss_enabled; then
        p=$(proto_ss_port); out="$out 17:$p 6:$p"       # SS: tcp+udp
    fi
    if declare -F proto_vless_enabled >/dev/null 2>&1 && proto_vless_enabled; then
        p=$(proto_vless_port); out="$out 6:$p"
    fi
    if declare -F proto_trojan_enabled >/dev/null 2>&1 && proto_trojan_enabled; then
        p=$(proto_trojan_port); out="$out 6:$p"
    fi
    echo "$out"
}

# Включить/обновить kernel-лимит. Применяется НЕМЕДЛЕННО + переживает ребут.
# Строится, если задан глобальный лимит ЛИБО у кого-то есть персональный тариф.
klimit_apply() {   # down_mbit up_mbit
    local down="$1" up="$2" port tiers tariffs shape
    [[ "$down" =~ ^[0-9]+$ ]] || down=0
    [[ "$up"   =~ ^[0-9]+$ ]] || up=0
    tiers="${KLIMIT_SET_TIERS:-$(klimit_tiers)}"; unset KLIMIT_SET_TIERS
    if [ "$down" -eq 0 ] && [ "$up" -eq 0 ] && ! _any_user_tariff; then klimit_clear; return 0; fi
    if ! command -v tc >/dev/null 2>&1 && ! command -v nft >/dev/null 2>&1 && ! command -v iptables >/dev/null 2>&1; then
        return 2   # нечем ограничивать на уровне ядра (нет tc/nft/iptables)
    fi
    port=$(get_port)
    tariffs=$(_all_rates "$tiers")
    shape=$(_klimit_shape_ports "$port")
    local node; node=$(klimit_node)      # читаем ДО перезаписи конфига — иначе потеряется
    {   echo "DOWN_MBIT=$down"
        echo "UP_MBIT=$up"
        echo "NODE_MBIT=$node"
        echo "PORT=$port"
        echo "SHAPE=$shape"
        echo "TIERS=$tiers"
        echo "TARIFFS=$tariffs"
    } > "$KLIMIT_CONF"
    _klimit_write_script "$down" "$up" "$port" "$tariffs" "$shape" "$node"
    _klimit_write_unit
    systemctl enable hy2-limit.service &>/dev/null
    bash "$KLIMIT_SCRIPT" apply 2>/dev/null
    rm -f "$KLIMIT_SIG" 2>/dev/null      # каркас пересобран — форсируем раскладку заново
    klimit_reconcile
    klimit_active
}

# Полностью снять kernel-лимит (сразу + из автозагрузки).
klimit_clear() {
    [ -f "$KLIMIT_SCRIPT" ] && bash "$KLIMIT_SCRIPT" clear 2>/dev/null
    command -v nft >/dev/null 2>&1 && nft delete table inet hy2limit 2>/dev/null
    systemctl disable hy2-limit.service &>/dev/null
    rm -f "$KLIMIT_UNIT" "$KLIMIT_CONF" "$KLIMIT_SCRIPT" "$KLIMIT_SIG" 2>/dev/null
    systemctl daemon-reload 2>/dev/null
    return 0
}

# ================================================================
# РЕКОНСИЛЯЦИЯ ТАРИФОВ: разложить активные IP клиентов по тарифным классам.
# Дёшево: шейпинг в ядре уже готов (build_dev создал классы), тут лишь ставим
# пер-IP u32-фильтры (prio 1, IP → класс тарифа). Источник связки user→IP —
# AUTHMAP_FILE (пишет auth-скрипт в реальном времени) + IPS_FILE как фолбэк.
# Идемпотентно: пересобираем prio-1 ТОЛЬКО когда набор «IP→тариф» изменился
# (сверяем подпись) — в спокойном состоянии 0 команд tc.
# ================================================================

# Пересобрать пер-IP фильтры (prio 1) на устройстве для одного направления.
# Использует глобальный ассоц-массив DES (ip→rate). $2 ipkey(dst|src), $3/$4 порт.
# ПЛОСКИЕ фильтры (без u32-хеша): каждый — «match udp + PORT + IP клиента → класс
# тарифа». Флат-фильтры u32 при отсутствии совпадения ГАРАНТИРОВАННО проваливаются
# на следующий приоритет (catch-all prio-2 → глобальный класс 1:1) — в отличие от
# хеш-таблицы, где fall-through зависит от версии ядра. Для десятков тарифных IP
# накладные расходы минимальны (не-udp пакеты отсекаются на первом селекторе).
# Бонус: `tc filter del prio 1` начисто сносит флат-фильтры (у хеша divisor-таблица
# «залипала» в ядре и ломала пересборку).
# Класс на КАЖДЫЙ активный адрес: миноры 0x2001..0x8fff, дети потолка ноды 1:1.
# Нумеруем подряд: раскладка каждый раз сносится целиком и строится заново, так
# что привязывать минор к самому адресу незачем. Диапазон ОГРАНИЧЕН сверху — за
# ним лежат чужие миноры каркаса (0x9999 «без лимита», 0xffff общий класс), и
# уборка не должна их задеть. 28 тысяч адресов на направление хватает с запасом.
KLIMIT_IPCLASS_BASE=8192          # 0x2000
KLIMIT_IPCLASS_MAX=36863          # 0x8fff

# Гарантия класса (htb rate) при потолке ceil. Десятая доля, но не меньше 1 Мбит.
# Почему rate НЕ равен ceil: пока класс укладывается в собственный rate, HTB не
# спрашивает родителя — и потолок ноды на таких классах не действует вовсе
# (проверено: два клиента по 30 при потолке 40 давали 53.7 Мбит/с). Всё, что
# выше гарантии, класс ЗАНИМАЕТ у родителя, и там потолок уже держит: те же два
# клиента при rate 3 / ceil 30 дали 36.8. Один клиент в тишине по-прежнему
# разгоняется до своего ceil.
_klimit_guarantee() {   # ceil_mbit -> rate_mbit
    local g=$(( ${1:-0} / 10 )); [ "$g" -lt 1 ] && g=1; echo "$g"
}
_reconcile_dev() {   # dev ipkey portsel shape("protonum:port ...") default_mbit
    local D="$1" IPK="$2" PSEL="$3" SH="$4" DEF="$5" ip rate cid tok pr po n=0 minor
    tc qdisc show dev "$D" 2>/dev/null | grep -q 'htb 1:' || return 0   # каркас классов есть?
    tc filter del dev "$D" parent 1: prio 1 2>/dev/null                 # снести старые пер-IP
    # Снести пер-IP классы прошлого прохода. Строго после фильтров: класс, на
    # который ещё ссылается фильтр, ядро удалить не даст.
    for cid in $(tc class show dev "$D" 2>/dev/null | awk '$1=="class" && $2=="htb" {print $3}'); do
        minor=$(( 0x${cid#*:} )) 2>/dev/null || continue
        [ "$minor" -ge "$KLIMIT_IPCLASS_BASE" ] && [ "$minor" -le "$KLIMIT_IPCLASS_MAX" ] \
            && tc class del dev "$D" classid "$cid" 2>/dev/null
    done
    for ip in "${!DES[@]}"; do
        case "$ip" in *:*) continue ;; esac      # IPv6 не шейпим на tc (→ общий класс)
        rate="${DES[$ip]}"
        [ "$rate" -gt 0 ] 2>/dev/null || rate="$DEF"   # без тарифа — общий лимит направления
        [ "$rate" -gt 0 ] 2>/dev/null || continue      # направление без лимита — класс не нужен
        n=$(( n + 1 ))
        [ $(( KLIMIT_IPCLASS_BASE + n )) -le "$KLIMIT_IPCLASS_MAX" ] || break   # диапазон кончился
        cid=$(printf '1:%x' $(( KLIMIT_IPCLASS_BASE + n )))
        tc class add dev "$D" parent 1:1 classid "$cid" \
            htb rate "$(_klimit_guarantee "$rate")mbit" ceil "${rate}mbit" 2>/dev/null || continue
        tc qdisc add dev "$D" parent "$cid" fq_codel 2>/dev/null
        # по фильтру на каждый (proto,port): один IP шейпится на всех протоколах.
        for tok in $SH; do
            pr=${tok%%:*}; po=${tok##*:}
            tc filter add dev "$D" parent 1: prio 1 protocol ip u32 \
                match ip protocol "$pr" 0xff match ip "$PSEL" "$po" 0xffff \
                match ip "$IPK" "${ip}/32" flowid "$cid" 2>/dev/null
        done
    done
    return 0
}

# Разложить активные IP по собственным классам (вызывается из cron --online-sync
# и после смены тарифа/каркаса). Без каркаса — тихий no-op.
#
# Раскладываем ВСЕ активные адреса, а не только тарифные: адрес без тарифа
# получает свой класс на общий лимит направления. Раньше такие адреса оставались
# на catch-all и делили между собой ОДИН класс на всю ноду — это и был обвал
# скорости при нескольких клиентах онлайн.
klimit_reconcile() {
    [ -f "$KLIMIT_CONF" ] || return 0
    command -v tc >/dev/null 2>&1 || return 0
    local tariffs port dev ifb shape down up
    tariffs=$(klimit_get TARIFFS)
    down=$(klimit_down); up=$(klimit_up)
    port=$(klimit_get PORT); [ -n "$port" ] || return 0
    shape=$(klimit_get SHAPE); [ -n "$shape" ] || shape="17:${port}"   # фолбэк: старый конфиг
    dev=$(ip -o route show default 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)
    [ -n "$dev" ] || return 0
    ifb="ifb-hy2"

    # 1) desired: ip -> тариф (0 = тарифа нет, класс будет на общий лимит).
    declare -A DES=()
    # Тариф юзера запоминаем: в authmap десятки строк на одного человека (по
    # строке на IP), а тик спидометра зовёт reconcile каждые 5 секунд.
    declare -A URATE=()
    local u ip ts rate now cutoff
    now=$(date +%s); cutoff=$(( now - 3600 ))     # маппинги свежее часа
    while IFS='|' read -r u ip ts _; do
        [ -n "$u" ] && [ -n "$ip" ] || continue
        [[ "$ts" =~ ^[0-9]+$ ]] && [ "$ts" -lt "$cutoff" ] && continue
        [ -n "${URATE[$u]:-}" ] || URATE[$u]=$(get_user_rate "$u")
        rate="${URATE[$u]}"
        [[ "$rate" =~ ^[0-9]+$ ]] || rate=0
        # Несколько юзеров за одним IP с разным тарифом — берём максимум (не режем сильнее).
        if [ -z "${DES[$ip]:-}" ] || [ "$rate" -gt "${DES[$ip]}" ]; then DES[$ip]="$rate"; fi
    done < <( { [ -f "$AUTHMAP_FILE" ] && cat "$AUTHMAP_FILE"
                [ -f "$IPS_FILE" ] && awk -F'|' 'NF>=4{printf "%s|%s|%s\n",$1,$2,$4}' "$IPS_FILE"; } 2>/dev/null )

    # 2) подпись; если не изменилась — обычно ничего не трогаем (0 команд tc).
    # НО: каркас классов мог быть пересобран (рестарт/бут сервиса hy2-limit,
    # ручной сброс tc, флап интерфейса) и стереть пер-IP фильтры (prio-1), тогда как
    # подпись осталась прежней. Слепо поверив подписи, мы бы НЕ восстановили
    # раскладку — и тарифные клиенты молча уехали бы в глобальный класс. Поэтому
    # при совпадении подписи дополнительно убеждаемся, что фильтры реально на месте.
    local sig stored=""
    # Лимиты направлений — часть подписи: они задают скорость классов у адресов
    # без тарифа, и смена лимита в меню обязана пересобрать раскладку.
    sig=$( { for ip in "${!DES[@]}"; do echo "${ip}=${DES[$ip]}"; done | sort
            echo "T=$tariffs P=$port S=$shape D=$down U=$up"; } | md5sum 2>/dev/null | cut -d' ' -f1)
    [ -f "$KLIMIT_SIG" ] && stored=$(cat "$KLIMIT_SIG" 2>/dev/null)
    if [ -n "$sig" ] && [ "$sig" = "$stored" ]; then
        # Нет активных адресов — раскладывать нечего. Есть — и фильтры prio-1 стоят —
        # действительно актуально, выходим. Иначе (фильтры пропали) пересобираем.
        if [ "${#DES[@]}" -eq 0 ] || tc filter show dev "$dev" parent 1: prio 1 2>/dev/null | grep -q .; then
            return 0
        fi
    fi

    # 3) пересобрать пер-IP раскладку на обоих направлениях (по всем портам SHAPE).
    _reconcile_dev "$dev" dst sport "$shape" "$down"   # скачивание: клиент — получатель
    _reconcile_dev "$ifb" src dport "$shape" "$up"     # отдача: клиент — источник (через IFB)
    [ -n "$sig" ] && echo "$sig" > "$KLIMIT_SIG"
    return 0
}

# Тихо чинит рассинхрон kernel-лимита с реальной раскладкой протоколов:
#   • сменился порт Hysteria, а лимит настроен на старый; ИЛИ
#   • включили/выключили протокол (VLESS/SS/Trojan/TUIC), но SHAPE запечён без его
#     порта — тогда трафик этого протокола идёт МИМО шейпинга (ни глобальный лимит,
#     ни тариф не действуют). Сверяем запечённый SHAPE со свежевычисленным.
# Вызывается при старте менеджера и в --online-sync (протокол могли включить из
# веб-аппа/бота, без перезапуска TUI).
#
# ОТСУТСТВИЕ SHAPE — тоже дрейф, и самый частый. klimit.conf, записанный до
# появления SHAPE, откатывается на фолбэк «17:$PORT»: шейпится один Hysteria, а
# VLESS/Trojan/TUIC/SS идут мимо лимита. Раньше ветку закрывал guard
# [ -n "$saved_shape" ] — нода со старым конфигом не лечилась НИКОГДА: SHAPE ей
# было взять неоткуда, а без него сравнение не запускалось. Так нода и стояла с
# глобальным лимитом, который действовал ровно на один протокол из пяти.
klimit_sync_port() {
    [ -f "$KLIMIT_CONF" ] || return 0
    local saved cur saved_shape cur_shape
    saved=$(klimit_get PORT); cur=$(get_port)
    [ -n "$cur" ] || return 0     # порт Hysteria не читается — пересобирать не на чем
    saved_shape=$(klimit_get SHAPE); cur_shape=$(_klimit_shape_ports "$cur")
    if { [ -n "$saved" ] && [ "$saved" != "$cur" ]; } || \
       [ "$saved_shape" != "$cur_shape" ]; then
        klimit_apply "$(klimit_down)" "$(klimit_up)"
    fi
    return 0
}

# ================================================================
# СИСТЕМНЫЙ ТЮНИНГ (профиль «Слабый сервер»): CPUQuota + GOMEMLIMIT + sysctl.
# ================================================================

perf_tune_active() { [ -f "$PERF_DROPIN" ]; }

# sysctl-буферы UDP — нужны всегда (quic-go просит >= 7 МБ; иначе warning в
# журнале и потери на бурстах). Не влияет на CPU, безопасно для слабых машин.
perf_sysctl_apply() {
    cat > "$PERF_SYSCTL" <<EOF
# hy2-manager: буферы UDP для QUIC (Hysteria 2)
net.core.rmem_max=16777216
net.core.wmem_max=16777216
EOF
    sysctl -p "$PERF_SYSCTL" >/dev/null 2>&1 || true
}

# Включить системную защиту слабого сервера:
#  - CPUQuota: Hysteria получает не больше (ядра*100 - 15)% CPU — при спидтесте
#    сервер остаётся отзывчивым (SSH/менеджер живут в оставшихся 15%);
#  - GOMEMLIMIT: мягкий потолок памяти Go-runtime (~40% ОЗУ) — GC не даёт
#    процессу раздуться и уйти в OOM на 2 ГБ.
perf_tune_weak() {
    local ncpu memkb memmb quota gml
    ncpu=$(nproc 2>/dev/null); [[ "$ncpu" =~ ^[0-9]+$ ]] || ncpu=1
    quota=$(( ncpu * 100 - 15 )); [ "$quota" -lt 50 ] && quota=50
    memkb=$(grep -oP '^MemTotal:\s*\K[0-9]+' /proc/meminfo 2>/dev/null); [[ "$memkb" =~ ^[0-9]+$ ]] || memkb=2097152
    memmb=$(( memkb / 1024 ))
    gml=$(( memmb * 40 / 100 )); [ "$gml" -lt 128 ] && gml=128; [ "$gml" -gt 2048 ] && gml=2048
    mkdir -p "$PERF_DROPIN_DIR"
    cat > "$PERF_DROPIN" <<EOF
# hy2-manager: защита слабого сервера (профиль «Слабый сервер»)
[Service]
CPUQuota=${quota}%
Environment=GOMEMLIMIT=${gml}MiB
EOF
    perf_sysctl_apply
    systemctl daemon-reload 2>/dev/null
    mark_restart_pending
}

# Убрать системные ограничения (профиль «Обычный сервер»).
perf_tune_normal() {
    rm -f "$PERF_DROPIN" 2>/dev/null
    rmdir "$PERF_DROPIN_DIR" 2>/dev/null
    perf_sysctl_apply
    systemctl daemon-reload 2>/dev/null
    mark_restart_pending
}

# ================================================================
# ПРОВЕРКА ПРИМЕНЕНИЯ — «почему лимит (не) работает» одним экраном.
# ================================================================
perf_report() {
    echo "  ══ Проверка производительности/лимитов ══════════════════"
    local bu bd icb kd ku
    bu=$(bw_up_get); bd=$(bw_down_get); icb=$(icbw_get)
    kd=$(klimit_down); ku=$(klimit_up)

    # 1. Конфиг Hysteria
    echo "  ── Конфиг Hysteria (для Brutal-клиентов) ──"
    if [ -n "$bu" ] || [ -n "$bd" ]; then
        echo "  ✅ bandwidth: ↓клиента ${bu:-∞} · ↑клиента ${bd:-∞}"
        if [ "$icb" = "true" ]; then
            echo "  ❌ ignoreClientBandwidth=true — потолок в этом режиме НЕ действует!"
            echo "     Выключите BBR-режим (пункт 3), иначе работает только kernel-лимит."
        else
            echo "  ✅ Режим Brutal-переговоров (ignoreClientBandwidth=false/выкл)"
        fi
    else
        echo "  ⚪ bandwidth в конфиге не задан (лимит на уровне протокола выключен)"
    fi

    # 2. Kernel-лимит
    echo "  ── Kernel-лимит (реальный потолок для ВСЕХ клиентов) ──"
    local ktar; ktar=$(klimit_get TARIFFS)
    if [ "$kd" -gt 0 ] || [ "$ku" -gt 0 ] || [ -n "$ktar" ]; then
        if klimit_active; then
            echo "  ✅ Активен: глоб. ↓ ${kd:-0} · ↑ ${ku:-0} Мбит/с (дефолт туннеля без тарифа)"
        else
            echo "  ❌ Настроен (↓$kd/↑$ku), но правила НЕ загружены!"
            echo "     Попробуйте: systemctl restart hy2-limit  ·  журнал: journalctl -u hy2-limit"
        fi
        if [ -n "$ktar" ]; then
            local nfd nfu
            nfd=$(tc filter show dev "$(ip -o route show default 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)" parent 1: 2>/dev/null | grep -c 'flowid 1:1[0-9a-f]')
            echo "  🚀 Тарифы (Мбит/с): $ktar · активных пер-IP правил (↓): ${nfd:-0}"
        fi
        if systemctl is-enabled --quiet hy2-limit.service 2>/dev/null; then
            echo "  ✅ Автозагрузка после ребута включена (hy2-limit.service)"
        else
            echo "  ⚠️  Автозагрузка выключена — после ребута лимит пропадёт"
        fi
        local sp cp; sp=$(klimit_get PORT); cp=$(get_port)
        [ -n "$sp" ] && [ "$sp" != "$cp" ] && echo "  ❌ Лимит настроен на порт $sp, а Hysteria слушает $cp — задайте лимит заново!"
    else
        echo "  ⚪ Выключен (скорость клиентов ядром не ограничивается)"
    fi

    # 3. Применён ли конфиг (рестарт)
    echo "  ── Применение конфига ──"
    if is_restart_pending; then
        echo "  ⚠️  Есть изменения конфига, ожидающие перезапуска Hysteria (пункт 8)"
    else
        echo "  ✅ Изменений, ожидающих перезапуска, нет"
    fi
    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        local started cfgts
        started=$(date -d "$(systemctl show -p ActiveEnterTimestamp --value "$SERVICE" 2>/dev/null)" +%s 2>/dev/null)
        cfgts=$(stat -c %Y "$CONFIG" 2>/dev/null)
        if [ -n "$started" ] && [ -n "$cfgts" ] && [ "$cfgts" -gt "$started" ] 2>/dev/null; then
            echo "  ⚠️  config.yaml изменён ПОСЛЕ старта Hysteria — сервер работает со старыми"
            echo "     значениями, перезапустите (пункт 8)."
        else
            echo "  ✅ Hysteria работает с актуальным конфигом"
        fi
    else
        echo "  ❌ Hysteria не запущена!"
    fi

    # 4. Системный тюнинг
    echo "  ── Системный тюнинг ──"
    if perf_tune_active; then
        local q g
        q=$(grep -oP 'CPUQuota=\K\S+' "$PERF_DROPIN" 2>/dev/null)
        g=$(grep -oP 'GOMEMLIMIT=\K\S+' "$PERF_DROPIN" 2>/dev/null)
        echo "  ✅ Профиль «Слабый сервер»: CPUQuota=$q · GOMEMLIMIT=$g"
    else
        echo "  ⚪ Системные ограничения CPU/RAM не заданы (профиль «Обычный»)"
    fi
    local rmem; rmem=$(sysctl -n net.core.rmem_max 2>/dev/null)
    if [ "${rmem:-0}" -ge 7340032 ] 2>/dev/null; then
        echo "  ✅ UDP-буферы: rmem_max=$rmem"
    else
        echo "  ⚠️  UDP-буферы малы (rmem_max=${rmem:-?}) — применяю..."
        perf_sysctl_apply
    fi
    echo "  ══════════════════════════════════════════════════════════"
}
