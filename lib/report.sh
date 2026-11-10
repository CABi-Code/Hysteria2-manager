#!/bin/bash
# ================================================
# Суточный отчёт о сервисе: клиенты, сеть, кластер
# ================================================
# Устройство и формат — docs/guide/DAILY-REPORT.md. Коротко:
#   * сеть каждая нода считает о СЕБЕ (журналы есть только у неё) и публикует
#     разделом кластера netday (--collect, раз в 30 мин);
#   * клиентов, скорость и кластер считает нода, которая печатает отчёт: трафик —
#     разностью кумулятивных счётчиков всех нод со снимком прошлого отчёта,
#     скорость — по выборкам спидометра, которые копит --online-sync;
#   * `--daily-report` печатает HTML для Telegram в stdout. Куда его доставить —
#     решает оператор (крон с пайпом в своего бота), менеджер об этом не знает.

REPORT_BASE="$DATA_DIR/report_base.dat"        # «#ts», затем «узел\tюзер\ttx\trx» на момент прошлого отчёта
REPORT_SAMPLES="$DATA_DIR/report_samples.dat"  # «ts|T» тик · «ts|R|узел|bps» скорость · «ts|D|строка здоровья»
# Ноду, где отчёт не печатают, выборки не должны заполнить: старше двух суток —
# начинаем заново.
REPORT_MAX_AGE_SEC=172800

# Кумулятивный трафик юзеров по всем нодам кластера: «узел\tюзер\ttx\trx».
_report_traffic() {
    local f name label
    if [ -f "$DATA_DIR/self.stats" ]; then
        awk -F'\t' -v n="$(node_label)" 'NF>=4 && $1!="" {print n"\t"$1"\t"$3"\t"$4}' "$DATA_DIR/self.stats"
    else
        awk -F'|' -v n="$(node_label)" 'NF>=3 && $1!="" {print n"\t"$1"\t"$2"\t"$3}' "$STATS_FILE" 2>/dev/null
    fi
    for f in "$PEERS_DIR"/*.stats; do
        [ -f "$f" ] || continue
        name=$(basename "$f" .stats)
        label=$(_report_peer_label "$name")
        awk -F'\t' -v n="$label" 'NF>=4 && $1!="" {print n"\t"$1"\t"$3"\t"$4}' "$f"
    done
}

_report_peer_label() {   # имя пира -> метка
    local l; l=$(awk -F'=' '$1=="LABEL"{sub(/^[^=]*=/,""); print; exit}' "$PEERS_DIR/$1.nodeinfo" 2>/dev/null)
    printf '%s' "${l:-$1}"
}

_report_rebase() {   # now
    { echo "#$1"; _report_traffic; } > "$REPORT_BASE.tmp.$$" && mv "$REPORT_BASE.tmp.$$" "$REPORT_BASE"
    : > "$REPORT_SAMPLES"
}

# Выборка для отчёта, зовётся каждым --online-sync. Скорость берём только
# «в работе» (порог collect_activity), иначе медиану утопят keepalive-нули.
report_sample() {
    local now base_ts
    now=$(date +%s)
    base_ts=$(head -1 "$REPORT_BASE" 2>/dev/null | tr -dc '0-9')
    if [ -z "$base_ts" ] || [ $(( now - base_ts )) -gt "$REPORT_MAX_AGE_SEC" ]; then
        _report_rebase "$now"
    fi
    {
        echo "$now|T"
        awk -F'|' -v now="$now" -v thr="${ACTIVITY_THRESHOLD_BPS:-4096}" '
            FNR==1        { node=FILENAME }
            /^#label\|/   { node=substr($0, 8); next }
            /^#/          { next }
            # Строка пира старше 5 мин — пир молчит, его «скорость» уже неправда.
            $2+0 >= thr && now-$4 <= 300 { print now "|R|" node "|" $2 }
        ' "$RATES_FILE" "$PEERS_DIR"/*.rates 2>/dev/null
        cluster_health_report 2>/dev/null | sed "s/^/$now|D|/"
    } >> "$REPORT_SAMPLES"
}

# Сеть ЭТОЙ ноды за сутки: строки «ключ=значение». Публикуется пирам (netday).
report_netday() {
    local since="-24h" since_s u
    since_s=$(date -d '-24 hours' '+%F %T')
    echo "ts=$(date +%s)"
    journalctl -u "$SERVICE" --since "$since" --no-pager -o cat 2>/dev/null | awk '
        /client connected/ { conn++; next }
        /client disconnected/ {
            if      ($0 !~ /"error"/)                   cl++
            else if ($0 ~ /no recent network activity/) idle++
            else if ($0 ~ /\(local\)/)                  srv++
            else if ($0 ~ /\(remote\)/)                 cl++
            else                                        oth++
            next
        }
        /(TCP|UDP) error/ {
            if ($0 ~ /"error": "rejected"/) blk++
            else if ($0 ~ /dial |connection refused|connection reset|no such host/) dial++
            next
        }
        END { printf "hy_conn=%d\nhy_idle=%d\nhy_srv=%d\nhy_cli=%d\nhy_oth=%d\nsite_fail=%d\nsite_blk=%d\n",
                     conn, idle, srv, cl, oth, dial, blk }'
    journalctl -u hy2-xray --since "$since" --no-pager -o cat 2>/dev/null | awk '
        /TLS handshake error/ { tls++; if (/i\/o timeout/) tlst++ }
        /\[Error\]/           { err++ }
        END { printf "xr_tls=%d\nxr_tls_to=%d\nxr_err=%d\n", tls, tlst, err }'
    # «Started» в журнале юнита — запуск (ручной, по обновлению или после
    # падения), «Failed with result» — именно падение.
    local st="" fl="" dn="" n h end
    for u in "$SERVICE" hy2-xray hy2-singbox caddy hy2-webapi hy2-bot; do
        systemctl cat "$u" >/dev/null 2>&1 || continue
        # Включена, но не работает ПРЯМО СЕЙЧАС — главное «срочно» отчёта.
        systemctl is-enabled --quiet "$u" 2>/dev/null && ! systemctl is-active --quiet "$u" 2>/dev/null \
            && dn="$dn${dn:+,}${u%.service}"
        n=$(journalctl -u "$u" --since "$since" --no-pager -o cat 2>/dev/null | grep -c '^Started ')
        [ "$n" -gt 0 ] && st="$st${st:+,}${u%.service}:$n"
        n=$(journalctl -u "$u" --since "$since" --no-pager -o cat 2>/dev/null | grep -c 'Failed with result')
        [ "$n" -gt 0 ] && fl="$fl${fl:+,}${u%.service}:$n"
    done
    echo "starts=$st"
    echo "fails=$fl"
    echo "down=$dn"
    # Сертификат — тем же путём, каким его видит клиент: истёк — встают все TLS-протоколы.
    h=$(node_host 2>/dev/null)
    if [ -n "$h" ]; then
        end=$(echo | timeout 5 openssl s_client -connect "$h:443" -servername "$h" 2>/dev/null \
              | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
        [ -n "$end" ] && echo "cert_days=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))"
    fi
    # Автообновление за сутки: «код|версия» последнего прогона (update.sh).
    awk -v s="=== $since_s" '/^=== .* готово, код / && ($1" "$2" "$3) >= s {
            l=$0; sub(/.*готово, код /, "", l); sub(/, версия /, "|", l); sub(/ ===.*/, "", l); u=l }
        END { if (u != "") print "upd=" u }' /var/log/hy2-manager/update.log 2>/dev/null
    awk -v s="$since_s" '($1" "$2) >= s && /кик/ {n++} END{print "kicks=" n+0}' "$DATA_DIR/limit.log" 2>/dev/null \
        || echo "kicks=0"
    # Метку времени несут только строки самого менеджера; остальное в error.log —
    # stderr TUI без даты, его к суткам не привязать.
    awk -v s="[$since_s" '/^\[[0-9][0-9][0-9][0-9]-/ && ($1" "$2) >= s { if (/тик пропущен/) sk++; else e++ } END{printf "mgr_err=%d\nmgr_skip=%d\n", e, sk}' \
        "${LOG_FILE:-/var/log/hy2-manager/error.log}" 2>/dev/null || printf 'mgr_err=0\nmgr_skip=0\n'
    echo "oom=$(journalctl -k --since "$since" --no-pager 2>/dev/null | grep -ci 'out of memory')"
    echo "load=$(cut -d' ' -f2 /proc/loadavg)"
    free 2>/dev/null | awk '/^Mem:/{printf "mem=%d\n", ($2-$7)*100/$2} /^Swap:/ && $2>0 {printf "swap=%d\n", $3*100/$2}'
    echo "cpus=$(nproc 2>/dev/null || echo 1)"
    df -P / 2>/dev/null | awk 'NR==2{sub(/%/,"",$5); print "disk=" $5}'
    echo "uptime=$(cut -d. -f1 /proc/uptime)"
}

publish_netday() {
    sub_enabled || return 0
    mkdir -p "$WEBROOT/cluster"
    report_netday > "$WEBROOT/cluster/netday.tmp.$$" 2>/dev/null \
        && mv "$WEBROOT/cluster/netday.tmp.$$" "$WEBROOT/cluster/netday"
    secure_web_files
}

# Пороги «срочно» и «посмотреть». Срочно — то, что уже бьёт по клиентам или
# ударит в ближайшие дни; посмотреть — то, что ухудшается, но терпит.
REPORT_DISK_URGENT=90;  REPORT_DISK_WARN=75
REPORT_MEM_URGENT=92;   REPORT_SWAP_WARN=50
REPORT_CERT_URGENT=7;   REPORT_CERT_WARN=20
REPORT_KICKS_WARN=30;   REPORT_SKIP_WARN=10

# Сигналы одной ноды: строки «U|текст» (срочно) и «W|текст» (посмотреть).
_report_node_alerts() {   # метка файл_netday
    local label="$1" f="$2" age
    if [ ! -s "$f" ]; then
        printf 'W|%s: нет сетевых данных (старая версия менеджера?)\n' "$label"; return
    fi
    age=$(( $(date +%s) - $(awk -F= '$1=="ts"{print $2+0}' "$f") ))
    awk -F'=' -v L="$label" -v age="$age" \
        -v du="$REPORT_DISK_URGENT" -v dw="$REPORT_DISK_WARN" -v mu="$REPORT_MEM_URGENT" -v sw="$REPORT_SWAP_WARN" \
        -v cu="$REPORT_CERT_URGENT" -v cw="$REPORT_CERT_WARN" -v kw="$REPORT_KICKS_WARN" -v skw="$REPORT_SKIP_WARN" '
        { v[$1]=$2 }
        function n(k) { return v[k]+0 }
        END {
            if (v["down"] != "")       printf "U|%s: не работает %s\n", L, v["down"]
            if (v["fails"] != "")      printf "U|%s: падения служб за сутки — %s\n", L, v["fails"]
            if (n("oom"))              printf "U|%s: OOM-убийств %d — не хватает памяти\n", L, n("oom")
            if (n("disk") >= du)       printf "U|%s: диск занят на %d%%\n", L, n("disk")
            else if (n("disk") >= dw)  printf "W|%s: диск занят на %d%%\n", L, n("disk")
            if (n("mem") >= mu)        printf "U|%s: память занята на %d%%\n", L, n("mem")
            if (n("swap") >= sw)       printf "W|%s: swap занят на %d%%\n", L, n("swap")
            if (n("cpus") && v["load"]+0 > n("cpus")) printf "W|%s: нагрузка %s при %d ядрах\n", L, v["load"], n("cpus")
            if ("cert_days" in v) {
                if (n("cert_days") <= cu)      printf "U|%s: сертификат истекает через %d дн.\n", L, n("cert_days")
                else if (n("cert_days") <= cw) printf "W|%s: сертификат истекает через %d дн. (автопродление не сработало?)\n", L, n("cert_days")
            }
            if (v["upd"] != "" && v["upd"] !~ /^0\|/) { split(v["upd"], a, "|"); printf "W|%s: автообновление завершилось с кодом %s\n", L, a[1] }
            if (n("mgr_err"))          printf "W|%s: ошибок менеджера %d (error.log)\n", L, n("mgr_err")
            if (n("mgr_skip") >= skw)  printf "W|%s: пропущено тиков крона %d — прогон не укладывается\n", L, n("mgr_skip")
            if (n("kicks") >= kw)      printf "W|%s: киков по лимиту устройств %d\n", L, n("kicks")
            if (n("xr_err"))           printf "W|%s: ошибок Xray %d\n", L, n("xr_err")
            if (age > 3600)            printf "W|%s: сетевые данные %d ч назад\n", L, age/3600
        }' "$f"
}

# Подробности сети одной ноды.
_report_net_block() {   # метка файл_netday
    local label="$1" f="$2"
    [ -s "$f" ] || { printf '<b>%s</b> · данных нет\n' "$(tg_esc "$label")"; return; }
    awk -F'=' -v label="$(tg_esc "$label")" '
        { v[$1]=$2 }
        function n(k) { return v[k]+0 }
        function list(s,   a, i, o, kv) {
            if (s == "") return "нет"
            split(s, a, ","); o=""
            for (i in a) { split(a[i], kv, ":"); o = o (o?", ":"") kv[1] " " kv[2] }
            return o
        }
        function pct(a, b) { return b ? sprintf(" (%d%%)", a*100/b) : "" }
        END {
            d = n("hy_idle") + n("hy_srv") + n("hy_cli") + n("hy_oth")
            printf "<b>%s</b>\n", label
            printf "Hysteria: подключений %d · обрывов по тишине %d%s · закрыл сервер %d · клиент %d", \
                   n("hy_conn"), n("hy_idle"), pct(n("hy_idle"), d), n("hy_srv"), n("hy_cli")
            if (n("hy_oth")) printf " · прочие %d", n("hy_oth")
            printf "\nXray: сорвано TLS-рукопожатий %d (по таймауту %d)\n", n("xr_tls"), n("xr_tls_to")
            printf "До сайтов: не достучались %d · отсечено правилами %d\n", n("site_fail"), n("site_blk")
            printf "Кики по лимиту: %d · запуски служб: %s\n", n("kicks"), list(v["starts"])
            printf "LA %s/%d · RAM %d%% · swap %d%% · диск %d%% · аптайм %d дн.", \
                   v["load"], n("cpus"), n("mem"), n("swap"), n("disk"), n("uptime")/86400
            if ("cert_days" in v) printf " · серт %d дн.", n("cert_days")
            print ""
        }' "$f"
}

# Ноды кластера для отчёта: «метка\tфайл_netday\tимя_пира» (у своей имени нет).
_report_nodes() {
    local f name
    printf '%s\t%s\t\n' "$(node_label)" "$DATA_DIR/.netday.self"
    for f in "$PEERS_DIR"/*.nodeinfo; do
        [ -f "$f" ] || continue
        name=$(basename "$f" .nodeinfo)
        printf '%s\t%s\t%s\n' "$(_report_peer_label "$name")" "$PEERS_DIR/$name.netday" "$name"
    done
}

# Экономическая часть: профили, кто пользовался, трафик, топ.
_report_clients() {   # now base_ts текущие_счётчики
    local now="$1" base_ts="$2" cur="$3" u kind exp
    printf '💰 <b>Клиенты и трафик</b> · %s\n' "$(date '+%d.%m %H:%M')"
    {
        while read -r u; do
            [ -n "$u" ] || continue
            if grep -q "^${u}|" "$DISABLED_FILE" 2>/dev/null; then echo off; continue; fi
            IFS='|' read -r kind exp _ _ <<< "$(user_plan_facts "$u")"
            case "$kind" in
                paid) if [ "${exp:-0}" = 0 ]; then echo nolimit
                      elif [ "$exp" -le "$now" ]; then echo expired
                      elif [ "$exp" -le $(( now + 3*86400 )) ]; then echo paid; echo soon
                      else echo paid; fi ;;
                *)    echo "$kind" ;;
            esac
        done <<< "$(get_all_users)"
    } | awk '{c[$1]++; if ($1 != "soon") t++} END {
        printf "Профилей %d: оплачено %d · без срока %d · истёк %d · бесплатный %d · демо %d · отключено %d\n",
               t, c["paid"], c["nolimit"], c["expired"], c["free"], c["demo"], c["off"]
        if (c["soon"]) printf "Оплата кончается в ближайшие 3 дня: %d\n", c["soon"] }'

    if [ -z "$base_ts" ]; then
        printf '<i>Трафик — со следующего отчёта: снимок счётчиков сделан сейчас.</i>\n'
        return
    fi
    printf '<i>окно %d ч %d мин</i>\n' $(( (now-base_ts)/3600 )) $(( (now-base_ts)%3600/60 ))
    # Разность счётчиков по (узел, юзер). Счётчик меньше снимка — его обнулили
    # (сброс трафика), тогда весь текущий — трафик окна.
    printf '%s\n' "$cur" | awk -F'\t' '
        NR==FNR { if ($0 !~ /^#/) { bt[$1"\t"$2]=$3; br[$1"\t"$2]=$4 }; next }
        {
            k=$1"\t"$2; dt=$3-bt[k]; dr=$4-br[k]
            if (dt < 0) dt=$3; if (dr < 0) dr=$4
            u[$2]+=dt+dr; T+=dt; R+=dr; node[$1]+=dt+dr
        }
        function h(b) { return b>=1073741824 ? sprintf("%.1f ГБ", b/1073741824) : sprintf("%.0f МБ", b/1048576) }
        END {
            for (x in u) if (u[x] >= 1048576) used++
            printf "Пользовались за сутки: %d\n", used
            printf "Трафик: %s (↓%s ↑%s)", h(T+R), h(T), h(R)
            o=""; for (x in node) o = o (o ? " · " : "") x " " h(node[x]); print (o ? "\n" o : "")
            for (i=1; i<=3; i++) {
                best=""; for (x in u) if (u[x] > 0 && (best=="" || u[x] > u[best])) best=x
                if (best == "") break
                top = top (top ? " · " : "") "<code>" best "</code> " h(u[best]); delete u[best]
            }
            if (top) print "Больше всех: " top
        }' "$REPORT_BASE" -
}

# Отчёт: две части через строку «\f» — экономическая и техническая (их шлют
# отдельными сообщениями). Затем новый снимок для следующих суток.
daily_report() {
    local now base_ts cur mine label nd name ver alerts
    now=$(date +%s)
    base_ts=$(head -1 "$REPORT_BASE" 2>/dev/null | tr -dc '0-9')
    cur=$(_report_traffic)
    mine="${MANAGER_VERSION:-unknown}"
    report_netday > "$DATA_DIR/.netday.self"

    _report_clients "$now" "$base_ts" "$cur"
    printf '\f\n'

    # ── Сигналы: ноды + кластер
    alerts=$(
        while IFS=$'\t' read -r label nd name; do
            _report_node_alerts "$label" "$nd"
            [ -n "$name" ] || continue
            ver=$(peer_version "$name")
            [ -n "$ver" ] && [ "$ver" != "$mine" ] && printf 'W|%s: версия %s, у нас %s\n' "$label" "$ver" "$mine"
            cluster_health_report 2>/dev/null | grep -F "($name)" | sed "s/^[^—]*— /U|$label: сейчас /"
            awk -F'|' -v h="($name)" -v L="$label" '$2=="T"{t++} $2=="D" && index($0,h){d++}
                END { if (d) printf "W|%s: была недоступна в %d из %d проверок\n", L, d, t }' "$REPORT_SAMPLES" 2>/dev/null
        done < <(_report_nodes)
        cluster_coverage_report 2>/dev/null | sed 's/^/W|/'
    )
    printf '🛠 <b>Техника</b> · %s\n' "$(date '+%d.%m %H:%M')"
    if ! grep -q . <<< "$alerts"; then
        printf '💚 Всё в порядке\n'
    else
        grep '^U|' <<< "$alerts" | sed 's/^U|//' | while IFS= read -r l; do printf '🔴 %s\n' "$(tg_esc "$l")"; done
        grep '^W|' <<< "$alerts" | sed 's/^W|//' | while IFS= read -r l; do printf '🟡 %s\n' "$(tg_esc "$l")"; done
    fi

    printf '\n'
    awk -F'|' '$2=="R"{print $4}' "$REPORT_SAMPLES" 2>/dev/null | sort -n | awk '
        { a[++n]=$1; s+=$1 }
        function sp(b) { return b>=1048576 ? sprintf("%.1f МБ/с", b/1048576) : sprintf("%.0f КБ/с", b/1024) }
        END {
            if (!n) { print "Скорость у клиентов: выборок нет"; exit }
            m = (n%2) ? a[(n+1)/2] : (a[n/2]+a[n/2+1])/2
            printf "Скорость у клиентов: средняя %s · медиана %s · худшие 10%% ниже %s (выборок %d)\n",
                   sp(s/n), sp(m), sp(a[int(n*0.1)+1]), n
        }'
    printf 'Версия: %s\n' "$mine"
    while IFS=$'\t' read -r label nd name; do
        echo
        _report_net_block "$label" "$nd"
    done < <(_report_nodes)

    rm -f "$DATA_DIR/.netday.self"
    _report_rebase "$now"
}
