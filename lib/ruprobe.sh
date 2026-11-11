#!/bin/bash
# ================================================
# Проба доступности нод изнутри российской сети
# ================================================
# Устройство и безопасность — docs/guide/RU-PROBE.md. Коротко:
#   * сервер пробы — обычный пользователь по SSH, у него нет ни менеджера, ни
#     секретов: каждый такт эта нода шлёт ему скрипт проверки вместе со списком
#     целей (публичные домены и порты) и читает ответ;
#   * ответ пробы — недоверенный: строки строго по белому списку, остальное
#     выбрасывается, текст в сообщение попадает только экранированным;
#   * `--ruprobe` печатает «ключ\nHTML» живого сообщения об инциденте, пока
#     инцидент открыт и ещё RUPROBE_TAIL_SEC после закрытия. Доставку (правка
#     одного сообщения по ключу) делает оператор кроном, как у суточного отчёта.
#
# Включается файлом $RUPROBE_CONF со строкой RUPROBE_SSH=<хост из ~/.ssh/config>.
# Нет файла — функция молчит: проба живёт на одной ноде, ключ есть только у неё.

RUPROBE_CONF="$DATA_DIR/ruprobe.conf"
RUPROBE_STATE="$DATA_DIR/ruprobe_state.dat"   # «цель|подряд_провалов|с_какого_ts|причина»
RUPROBE_EPISODE="$DATA_DIR/ruprobe_episode"   # «since|closed_ts|цели_за_эпизод(через ,)»
RUPROBE_LOG="$DATA_DIR/ruprobe.log"           # «ts|цель|итог|мс|байт» — сэмплы
RUPROBE_LOG_DAYS=8
RUPROBE_FAILS=2        # подряд провальных тактов до тревоги (одиночный провал — шум)
RUPROBE_BLIND=3        # подряд тактов «проба не видит даже РФ» до сообщения о ней самой
RUPROBE_TAIL_SEC=900   # сколько тактов после закрытия ещё печатать итог (доставка могла сорваться)
RUPROBE_PAD="/assets/data.bin"   # файл > 16 КБ на сайте ноды (nodepage_pad_ensure)
RUPROBE_PAD_BYTES=65536

ruprobe_ssh_host() {
    awk -F= '$1=="RUPROBE_SSH"{print $2; exit}' "$RUPROBE_CONF" 2>/dev/null | tr -cd 'A-Za-z0-9._@-'
}

# Цели: «нода|host|proto|port|l4» по включённым протоколам всего кластера плюс
# сайт ноды на 443 (им же клиенты забирают подписку). Только то, что и так
# публично (домен, порт), — секретов кластера проба не получает.
ruprobe_targets() {
    local self; self=$(node_host)
    cluster_protocols 2>/dev/null | awk -F'|' -v self="$self" -v me="$(node_name)" -v conf="$CLUSTER_CONF" '
        BEGIN { while ((getline l < conf) > 0) { split(l, a, "|"); if (a[1] != "") host[a[1]] = a[2] } host[me] = self }
        $3 == "1" && ($1 in host) { print $1 "|" host[$1] "|" $2 "|" $5 "|" $6 }
        ($1 in host) && !seen[$1]++ { print $1 "|" host[$1] "|https|443|tcp" }
    ' | grep -E '^[^|]{1,64}\|[A-Za-z0-9.-]{1,253}\|[a-z0-9]{1,16}\|[0-9]{1,5}\|(tcp|udp)$' | sort -u
}

# Скрипт, который исполняется НА пробе. Цели приходят строками после маркера.
# Итог: «host|proto|port|итог|мс|байт», где итог:
#   ok    — TLS и скачивание больше 16 КБ прошли;   okt — TLS прошёл, большого файла нет;
#   frz   — соединение замерло после N байт (так режет ТСПУ иностранный хостинг);
#   cls   — порт не отвечает;  tls — TCP есть, TLS рвётся;  skip — UDP, проверить нечем.
# Плюс «host|ping|0|ok/cls|мс|потери%» и контроль «_ru» / «_world».
_ruprobe_remote_script() {
    cat <<'SH'
PAD="$1"; PADB="$2"
chk() { # host proto port l4
    local h=$1 p=$2 port=$3 l4=$4 out rc code sz tc tt
    if [ "$l4" = udp ]; then echo "$h|$p|$port|skip|0|0"; return; fi
    if [ "$p" = ss ]; then
        s=$(date +%s%N); nc -z -w5 "$h" "$port" 2>/dev/null && r=okt || r=cls
        echo "$h|$p|$port|$r|$(( ($(date +%s%N)-s)/1000000 ))|0"; return
    fi
    out=$(curl -sk -o /dev/null --connect-timeout 6 --max-time 20 -w '%{http_code} %{size_download} %{time_connect} %{time_total}' "https://$h:$port$PAD" 2>/dev/null); rc=$?
    read -r code sz tc tt <<<"$out"
    ms=$(awk -v t="${tt:-0}" 'BEGIN{printf "%d", t*1000}')
    if [ "$rc" = 0 ] && [ "${sz:-0}" -ge "$PADB" ]; then r=ok
    elif [ "$rc" = 0 ]; then r=okt
    elif [ "$rc" = 28 ] && [ "${sz:-0}" -gt 0 ]; then r=frz
    elif awk -v t="${tc:-0}" 'BEGIN{exit !(t>0)}'; then r=tls
    else r=cls; fi
    echo "$h|$p|$port|$r|$ms|${sz:-0}"
}
png() { local o; o=$(ping -n -c3 -W2 -q "$1" 2>/dev/null)
    l=$(echo "$o" | grep -o '[0-9]*% packet loss' | tr -dc 0-9); a=$(echo "$o" | awk -F/ '/rtt|round-trip/{printf "%d", $5}')
    [ "${l:-100}" -lt 100 ] && echo "$1|ping|0|ok|${a:-0}|${l:-0}" || echo "$1|ping|0|cls|0|100"; }
ctl() { curl -s -o /dev/null --max-time 10 "$2" 2>/dev/null && echo "$1|ctl|0|ok|0|0" || echo "$1|ctl|0|cls|0|0"; }
ctl _ru https://ya.ru </dev/null & ctl _world https://www.google.com </dev/null &
declare -A hs
while IFS='|' read -r h p port l4; do
    [ -n "$h" ] || continue
    chk "$h" "$p" "$port" "$l4" </dev/null &
    [ -n "${hs[$h]:-}" ] || { hs[$h]=1; png "$h" </dev/null & }
done
wait
SH
}

# Один заход на пробу. Подменяется в тесте. Пробе не даём ничего, кроме
# stdout: ни агента, ни проброса портов, ни интерактива; ответ обрезан по размеру.
_ruprobe_exec() {   # ssh_host  <targets
    local host="$1" script
    script=$(_ruprobe_remote_script)
    timeout 90 ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes \
        -o ForwardAgent=no -o ForwardX11=no -o ClearAllForwardings=yes -o RequestTTY=no \
        "$host" "bash -c $(printf '%q' "$script") _ $RUPROBE_PAD $RUPROBE_PAD_BYTES" 2>/dev/null | head -c 65536
}

_ruprobe_proto_label() {
    case "$1" in
        hy2) echo Hysteria ;; vless) echo VLESS ;; vlessx) echo VLESS-X ;; trojan) echo Trojan ;;
        ss) echo SS ;; tuic) echo TUIC ;; https) echo "сайт/подписка" ;; ping) echo "адрес (ping)" ;; *) echo "$1" ;;
    esac
}

_ruprobe_reason() {   # итог байт
    case "$1" in
        frz) echo "обрыв после $(( $2 / 1024 )) КБ — так режет ТСПУ" ;;
        cls) echo "не отвечает" ;;
        tls) echo "TLS рвётся" ;;
        *)   echo "$1" ;;
    esac
}

# Такт: сходить на пробу, обновить состояние, напечатать сообщение, если нужно.
ruprobe_run() {
    local ssh_host; ssh_host=$(ruprobe_ssh_host)
    [ -n "$ssh_host" ] || return 0
    local now targets raw; now=$(date +%s)
    targets=$(ruprobe_targets)
    [ -n "$targets" ] || return 0
    # Пробе уходят только host|proto|port|l4 — без имён нод.
    raw=$(cut -d'|' -f2- <<<"$targets" | _ruprobe_exec "$ssh_host" \
        | grep -E '^[A-Za-z0-9._-]{1,253}\|[a-z0-9]{1,16}\|[0-9]{1,5}\|(ok|okt|frz|cls|tls|skip)\|[0-9]{1,7}\|[0-9]{1,9}$')
    _ruprobe_apply "$now" "$targets" "$raw"
}

# Чистая часть такта (её и проверяет тест): ответ пробы → состояние → сообщение.
_ruprobe_apply() {   # now targets raw
    local now="$1" targets="$2" raw="$3"
    mkdir -p "$DATA_DIR"
    local blind=0
    grep -q '^_ru|ctl|0|ok|' <<<"$raw" || blind=1

    # Итоги по целям «нода/proto» (адрес — «нода/ping»). Проба слепа — вердикты
    # не трогаем: её отказ ничего не говорит о нодах.
    local res
    res=$(awk -F'|' -v raw="$raw" '
        BEGIN { n = split(raw, L, "\n"); for (i = 1; i <= n; i++) { split(L[i], f, "|"); if (f[1] != "") r[f[1] "|" f[2] "|" f[3]] = f[4] "|" f[5] "|" f[6] } }
        { k = $2 "|" $3 "|" $4; if (k in r) print $1 "/" $3 "|" r[k]
          if (!($1 in pinged)) { pinged[$1] = 1; k = $2 "|ping|0"; if (k in r) print $1 "/ping|" r[k] } }
    ' <<<"$targets")

    [ "$blind" = 0 ] && [ -n "$res" ] && awk -F'|' -v now="$now" '{print now "|" $0}' <<<"$res" >> "$RUPROBE_LOG"
    _ruprobe_trim_log "$now"

    local tmp; tmp=$(mktemp) || return 0
    if [ "$blind" = 1 ]; then
        # Счётчик слепоты — отдельной строкой состояния, прочие строки как были.
        awk -F'|' -v now="$now" '
            $1 == "_blind" { b = $2 + 1; s = $3; next } { print }
            END { if (!b) { b = 1; s = now } print "_blind|" b "|" s "|" }' "$RUPROBE_STATE" 2>/dev/null > "$tmp"
    else
        awk -F'|' -v now="$now" -v res="$res" '
            BEGIN { n = split(res, L, "\n"); for (i = 1; i <= n; i++) { split(L[i], f, "|"); if (f[1] != "") { r[f[1]] = f[2]; b[f[1]] = f[4] } } }
            $1 == "_blind" { next }
            { old[$1] = $2 "|" $3 }
            END {
                for (k in r) {
                    if (r[k] == "ok" || r[k] == "okt" || r[k] == "skip") continue
                    split((k in old) ? old[k] : "0|" now, o, "|")
                    print k "|" o[1] + 1 "|" o[2] "|" r[k] ":" b[k]
                }
            }' "$RUPROBE_STATE" 2>/dev/null | sort > "$tmp"
    fi
    mv "$tmp" "$RUPROBE_STATE"
    _ruprobe_message "$now" "$(cut -d'|' -f1 <<<"$targets" | sort -u | grep -c .)"
}

_ruprobe_trim_log() {   # now
    [ -f "$RUPROBE_LOG" ] || return 0
    # Раз в сутки достаточно: старая голова лога ничего не ломает.
    local first; first=$(head -c 12 "$RUPROBE_LOG" | cut -d'|' -f1)
    [[ "$first" =~ ^[0-9]+$ ]] && [ $(( $1 - first )) -gt $(( (RUPROBE_LOG_DAYS + 1) * 86400 )) ] || return 0
    awk -F'|' -v min=$(( $1 - RUPROBE_LOG_DAYS * 86400 )) '$1 >= min' "$RUPROBE_LOG" > "$RUPROBE_LOG.tmp" \
        && mv "$RUPROBE_LOG.tmp" "$RUPROBE_LOG"
}

# Живое сообщение эпизода: открывается первой подтверждённой бедой, правится
# каждым тактом, закрывается, когда бед не осталось. Ключ — начало эпизода,
# поэтому новый эпизод — новое сообщение, а внутри эпизода — правки.
_ruprobe_message() {   # now число_нод
    local now="$1" nodes_all="$2" since="" closed="" seen="" bad blind_line
    [ -f "$RUPROBE_EPISODE" ] && IFS="|" read -r since closed seen < "$RUPROBE_EPISODE"
    bad=$(awk -F'|' -v n="$RUPROBE_FAILS" '$1 != "_blind" && $2 >= n' "$RUPROBE_STATE" 2>/dev/null)
    blind_line=$(awk -F'|' -v n="$RUPROBE_BLIND" '$1 == "_blind" && $2 >= n' "$RUPROBE_STATE" 2>/dev/null)

    if [ -n "$bad" ] || [ -n "$blind_line" ]; then
        if [ -z "$since" ] || [ -n "$closed" ]; then since=$now; seen=""; fi
        closed=""
        local k; while IFS= read -r k; do
            [ -n "$k" ] && [[ ",$seen," != *",$k,"* ]] && seen="${seen:+$seen,}$k"
        done < <(cut -d'|' -f1 <<<"$bad")
    elif [ -n "$since" ] && [ -z "$closed" ]; then
        closed=$now
    fi
    [ -n "$since" ] || return 0
    printf '%s|%s|%s\n' "$since" "$closed" "$seen" > "$RUPROBE_EPISODE"
    # Закрыт давно — молчим; эпизод остаётся на диске до следующего.
    [ -n "$closed" ] && [ $(( now - closed )) -gt "$RUPROBE_TAIL_SEC" ] && return 0

    echo "ruprobe:$since"
    if [ -n "$closed" ]; then
        printf '✅ <b>Из РФ снова всё доступно</b>\n'
        printf 'было с %s по %s (%d мин): %s\n' "$(date -d "@$since" +%H:%M)" "$(date -d "@$closed" +%H:%M)" \
            $(( (closed - since) / 60 )) "$(tg_esc "$(_ruprobe_keys_human "$seen")")"
        return 0
    fi
    local nodes_down
    nodes_down=$(awk -F'|' '$1 ~ /\/ping$/' <<<"$bad" | grep -c .)
    if [ -n "$bad" ] && [ "$nodes_all" -gt 0 ] && [ "$nodes_down" -ge "$nodes_all" ]; then
        printf '‼️ <b>Из РФ недоступен весь кластер</b> (%d из %d нод)\n' "$nodes_down" "$nodes_all"
    elif [ -n "$bad" ]; then
        printf '‼️ <b>Из РФ недоступно</b>\n'
    fi
    local key cnt from why node proto
    while IFS='|' read -r key cnt from why; do
        [ -n "$key" ] || continue
        node=${key%/*}; proto=${key##*/}
        printf '%s · %s — %s · с %s\n' "$(tg_esc "$node")" "$(_ruprobe_proto_label "$proto")" \
            "$(_ruprobe_reason "${why%%:*}" "${why##*:}")" "$(date -d "@$from" +%H:%M)"
    done <<<"$bad"
    if [ -n "$blind_line" ]; then
        printf '🟡 Проба сама не на связи с %s — данных о нодах нет\n' "$(date -d "@$(cut -d'|' -f3 <<<"$blind_line")" +%H:%M)"
    fi
    printf '<i>проверено %s из российской сети</i>\n' "$(date -d "@$now" +%H:%M)"
}

_ruprobe_keys_human() {   # "нода/proto,..." -> «нода: VLESS, TUIC; ...»
    tr ',' '\n' <<<"$1" | grep . | while IFS= read -r k; do
        printf '%s|%s\n' "${k%/*}" "$(_ruprobe_proto_label "${k##*/}")"
    done | awk -F'|' '{ if (!($1 in a)) o[++n] = $1; a[$1] = a[$1] ? a[$1] ", " $2 : $2 }
        END { for (i = 1; i <= n; i++) printf "%s%s: %s", (i > 1 ? "; " : ""), o[i], a[o[i]] }'
    [ -n "$1" ] || printf 'только проба'
}
