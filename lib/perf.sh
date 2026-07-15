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
#   2) Kernel-лимит (nftables per-IP token bucket) — РЕАЛЬНЫЙ потолок для всех,
#      включая BBR-клиентов. Каждому IP клиента — свой бакет. Работает сразу,
#      без рестарта Hysteria, переживает ребут (systemd-юнит hy2-limit).
#      Ставится с запасом ~18% над лимитом, чтобы не душить Brutal-клиентов,
#      которые уже ограничены на уровне протокола (без двойного урезания).
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
KLIMIT_CONF="$DATA_DIR/klimit.conf"          # DOWN_MBIT / UP_MBIT / PORT
KLIMIT_SCRIPT="$DATA_DIR/klimit.sh"          # применяет/снимает nft-правила
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

klimit_get() {   # key -> value
    [ -f "$KLIMIT_CONF" ] && grep "^${1}=" "$KLIMIT_CONF" 2>/dev/null | head -1 | cut -d= -f2-
}
klimit_down() { local v; v=$(klimit_get DOWN_MBIT); [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" || echo 0; }
klimit_up()   { local v; v=$(klimit_get UP_MBIT);   [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" || echo 0; }

# Активен ли kernel-лимит прямо сейчас (таблица nftables загружена)?
klimit_active() {
    command -v nft >/dev/null 2>&1 && nft list table inet hy2limit &>/dev/null && return 0
    command -v iptables >/dev/null 2>&1 && iptables -S HY2LIMIT_OUT &>/dev/null && return 0
    return 1
}

# Генерирует скрипт применения лимита (nft, fallback iptables+hashlimit) и
# systemd-юнит для восстановления после ребута.
# down_mbit — скачивание клиента (сервер -> клиент), up_mbit — отдача клиента.
_klimit_write_script() {   # down_mbit up_mbit port
    local down="$1" up="$2" port="$3"
    # Перевод Мбит/с -> KiB/s (nft меряет kbytes = 1024 B на проводе):
    #   1 Мбит/с = 122 KiB/s полезной нагрузки. Берём 138 (~13% запас): nft
    #   считает и UDP/QUIC-заголовки, а Brutal-клиент уже ограничен протоколом
    #   и не должен упираться ещё и в дропы ядра. Потолок держим близко к цели.
    local dkb=$(( down * 138 ))
    local ukb=$(( up * 138 ))
    local dburst=$(( dkb / 4 )); [ "$dburst" -lt 256 ] && dburst=256
    local uburst=$(( ukb / 4 )); [ "$uburst" -lt 256 ] && uburst=256

    {
        echo '#!/bin/bash'
        echo "# Сгенерировано hy2-manager. Пер-IP потолок скорости для порта Hysteria ${port}/udp."
        echo "# apply — включить, clear — выключить. Идемпотентно."
        echo "PORT=${port}"
        echo "DKB=${dkb}      # KiB/s на IP: скачивание клиента (0 = без лимита)"
        echo "UKB=${ukb}      # KiB/s на IP: отдача клиента (0 = без лимита)"
        echo "DBURST=${dburst}"
        echo "UBURST=${uburst}"
        # Дальше — статичное тело (ничего не подставляем: 'KEOF' в кавычках).
        cat <<'KEOF'

nft_apply() {
    local dl_rules="" ul_rules=""
    if [ "$DKB" -gt 0 ]; then
        dl_rules="udp sport $PORT meter hy2dl4 size 65535 { ip daddr timeout 2m limit rate over $DKB kbytes/second burst $DBURST kbytes } counter drop
        udp sport $PORT meter hy2dl6 size 65535 { ip6 daddr timeout 2m limit rate over $DKB kbytes/second burst $DBURST kbytes } counter drop"
    fi
    if [ "$UKB" -gt 0 ]; then
        ul_rules="udp dport $PORT meter hy2ul4 size 65535 { ip saddr timeout 2m limit rate over $UKB kbytes/second burst $UBURST kbytes } counter drop
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
        if command -v nft >/dev/null 2>&1; then nft_apply; else ipt_apply; fi ;;
    clear)
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

# Включить/обновить kernel-лимит. Применяется НЕМЕДЛЕННО + переживает ребут.
klimit_apply() {   # down_mbit up_mbit
    local down="$1" up="$2" port
    [[ "$down" =~ ^[0-9]+$ ]] || down=0
    [[ "$up"   =~ ^[0-9]+$ ]] || up=0
    if [ "$down" -eq 0 ] && [ "$up" -eq 0 ]; then klimit_clear; return 0; fi
    if ! command -v nft >/dev/null 2>&1 && ! command -v iptables >/dev/null 2>&1; then
        return 2   # нечем ограничивать на уровне ядра
    fi
    port=$(get_port)
    {   echo "DOWN_MBIT=$down"
        echo "UP_MBIT=$up"
        echo "PORT=$port"
    } > "$KLIMIT_CONF"
    _klimit_write_script "$down" "$up" "$port"
    _klimit_write_unit
    systemctl enable hy2-limit.service &>/dev/null
    bash "$KLIMIT_SCRIPT" apply 2>/dev/null
    klimit_active
}

# Полностью снять kernel-лимит (сразу + из автозагрузки).
klimit_clear() {
    [ -f "$KLIMIT_SCRIPT" ] && bash "$KLIMIT_SCRIPT" clear 2>/dev/null
    command -v nft >/dev/null 2>&1 && nft delete table inet hy2limit 2>/dev/null
    systemctl disable hy2-limit.service &>/dev/null
    rm -f "$KLIMIT_UNIT" "$KLIMIT_CONF" "$KLIMIT_SCRIPT" 2>/dev/null
    systemctl daemon-reload 2>/dev/null
    return 0
}

# Если порт Hysteria сменился, а kernel-лимит настроен на старый — перегенерировать.
# Вызывается при старте менеджера (тихо чинит рассинхрон).
klimit_sync_port() {
    [ -f "$KLIMIT_CONF" ] || return 0
    local saved cur
    saved=$(klimit_get PORT); cur=$(get_port)
    [ -n "$saved" ] && [ "$saved" != "$cur" ] && klimit_apply "$(klimit_down)" "$(klimit_up)"
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
    if [ "$kd" -gt 0 ] || [ "$ku" -gt 0 ]; then
        if klimit_active; then
            echo "  ✅ Активен: ↓ ${kd:-0} Мбит/с · ↑ ${ku:-0} Мбит/с на каждый IP клиента"
        else
            echo "  ❌ Настроен (↓$kd/↑$ku), но правила НЕ загружены!"
            echo "     Попробуйте: systemctl restart hy2-limit  ·  журнал: journalctl -u hy2-limit"
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
