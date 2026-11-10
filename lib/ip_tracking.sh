#!/bin/bash
# ================================================
# IP-трекинг: сбор и анализ IP-адресов пользователей
# ================================================

# Сколько держим запись об IP после последнего появления. Мобильный клиент
# меняет адрес по нескольку раз в день, и без срока файл только рос — а всё,
# что по нему считают (уникальные IP, «IP за неделю», антиабуз), смотрит
# максимум на неделю назад. Отсюда и срок: 30 дней были данными, которые никто
# не читает, а адрес пользователя — не тот остаток, который стоит хранить
# «на всякий случай» (P-79).
IPS_RETENTION_DAYS="${IPS_RETENTION_DAYS:-7}"

# Сколько держим записи в ЖИВОМ маппинге user→IP (authmap.dat). Он не история, а
# рабочая таблица: klimit_reconcile смотрит на час назад, счётчик устройств — на
# последние адреса юзера. Двух суток хватает обоим с большим запасом.
AUTHMAP_RETENTION_DAYS="${AUTHMAP_RETENTION_DAYS:-2}"

# Подрезка authmap.dat по возрасту (P-36). Auth-скрипт дописывает строку
# «user|ip|ts» на КАЖДОЕ подключение и сам файл не чистит — он растёт линейно от
# числа подключений, а читает его теперь ещё и каждый пересчёт онлайна.
# Гонка с auth-скриптом: строка, дописанная между чтением и mv, потеряется. Цена
# мала (вернётся со следующим подключением, а раскладка тарифов подстрахована
# ips.dat), поэтому чистим редко — из 30-минутного --collect — и только когда
# резать реально есть что.
# Карта занятых слотов растёт так же, как authmap (строка на подключение), и
# чинится тем же способом. Держим короче: для решения «слот занят» нужна только
# последняя запись, а история тут ни на что не влияет.
SLOTMAP_RETENTION_HOURS="${SLOTMAP_RETENTION_HOURS:-6}"

# Сколько живёт системный журнал ноды (P-79). Не косметика и не место на диске:
# ядро Hysteria пишет в него «client connected {addr, id}» — связку «адрес ↔ имя
# пользователя ↔ время», и без ограничения journald держит её месяцами. Выключить
# эти строки нельзя: из них collect_ips и строит ips.dat. Значит единственный
# рычаг — срок. Сбор идёт раз в 30 минут, инкрементально; трёх суток запаса
# хватает на любой простой крона, а всё, что старше, сервису уже не нужно —
# оно нужно только тому, кто придёт за журналом.
JOURNAL_RETENTION_DAYS="${JOURNAL_RETENTION_DAYS:-3}"
JOURNALD_DROPIN="/etc/systemd/journald.conf.d/10-hy2-retention.conf"

# ---------------- Адреса — только хэшем (P-176) ----------------
# Ни в файлах данных, ни в журналах, ни соседям адрес клиента открытым не
# уходит: вместо него «h<16 hex>» = HMAC(соль, адрес) — lib/iphash.py, одна
# реализация на всё. Сравнение «тот же адрес или нет» хэш сохраняет, поэтому
# счёт устройств, анти-абуз и «чужое устройство» не заметили подмены.
# Соль общая на кластер (выводится из секрета кластера) и меняется раз в месяц
# по UTC — у всех нод одновременно, без переговоров.
#
# Настоящий адрес нужен ровно одному: tc-правилам тарифной скорости. Для них —
# RAW_DIR в /run (tmpfs, не пишется на диск): маппинг Hysteria «юзер|адрес|ts»
# и лог Caddy, и тот и другой живут не дольше часа. Разбор —
# docs/guide/DATA-RETENTION.md.
# Пути (IPHASH_PY, IP_SALT_FILE, RAW_DIR, RAW_AUTHMAP, CADDY_RAW_LOG) — в config.sh.
RAW_RETENTION_SEC="${RAW_RETENTION_SEC:-3600}"
TMPFILES_CONF="${HY2M_TMPFILES_CONF:-/etc/tmpfiles.d/hy2-manager.conf}"
# Сразу после смены соли старые хэши у соседей и новые у нас — разные метки
# одного адреса, и одно устройство на пару минут выглядит двумя. Кик в это окно
# рвал бы платящего, поэтому лимит устройств его пропускает.
IP_ROTATE_QUIET_SEC="${IP_ROTATE_QUIET_SEC:-900}"

ip_scrub()    { python3 "$IPHASH_PY" scrub "$IP_SALT_FILE"; }   # stdin → адреса заменены хэшами
ip_hash_map() { python3 "$IPHASH_PY" map "$IP_SALT_FILE"; }     # адрес на строку → «адрес<TAB>хэш»

# В окне после смены соли (или первой выдачи) кикать нельзя — см. выше.
ip_rotation_quiet() {
    local ts
    ts=$(awk '{print $3; exit}' "$IP_SALT_FILE" 2>/dev/null)
    [[ "$ts" =~ ^[0-9]+$ ]] && [ $(( $(date +%s) - ts )) -lt "$IP_ROTATE_QUIET_SEC" ]
}

# Переписать файл, заменив адреса хэшами. `cat >`, а не mv: владельца и права
# (auth-скрипт пишет от юзера сервиса) сохраняем как есть.
_ip_scrub_file() {
    [ -s "$1" ] || return 0
    local tmp; tmp=$(mktemp) || return 1
    ip_scrub < "$1" > "$tmp" && cat "$tmp" > "$1"
    rm -f "$tmp"
}

# Соль текущего месяца. Идемпотентна, зовётся раз в минуту. Первая выдача —
# разовая миграция: всё, что уже лежит открытым, переводится в хэши. Смена —
# хэши прошлого месяца стираются: с новыми они не сравнимы, то есть никому не
# нужны, а держать их значит держать вечную метку адреса.
ip_salt_sync() {
    local epoch cur salt tmp first=0 f owner group
    epoch=$(date -u +%Y%m)
    cur=$(awk '{print $1; exit}' "$IP_SALT_FILE" 2>/dev/null)
    [ "$cur" = "$epoch" ] && return 0
    command -v python3 >/dev/null 2>&1 || return 1
    declare -F cluster_secret >/dev/null && cluster_secret >/dev/null
    salt=$(python3 "$IPHASH_PY" derive "$CLUSTER_SECRET_FILE" "$epoch" 2>/dev/null)
    [ -n "$salt" ] || return 1
    [ -n "$cur" ] || first=1
    tmp="${IP_SALT_FILE}.tmp.$BASHPID"
    printf '%s %s %s\n' "$epoch" "$salt" "$(date +%s)" > "$tmp" || return 1
    # Соль читают auth-скрипт и фильтр журнала Hysteria — оба от юзера сервиса.
    if declare -F service_identity >/dev/null 2>&1; then
        read -r owner group < <(service_identity)
        [ -n "$owner" ] && chown "${owner}:${group}" "$tmp" 2>/dev/null
    fi
    chmod 640 "$tmp"; mv "$tmp" "$IP_SALT_FILE"

    if [ "$first" = 1 ]; then
        # tc-раскладке нужен живой маппинг — последний час переносим в RAW_DIR
        # до того, как authmap.dat станет хэшами.
        raw_dirs_ensure
        awk -F'|' -v cut=$(( $(date +%s) - RAW_RETENTION_SEC )) 'NF>=3 && $3+0>=cut' \
            "$AUTHMAP_FILE" >> "$RAW_AUTHMAP" 2>/dev/null
        for f in "$IPS_FILE" "$SUBIPS_FILE" "$AUTHMAP_FILE" "$SLOTMAP_FILE" "$DATA_DIR/limit.log" \
                 "$PEERS_DIR"/*.stats "$PEERS_DIR"/*.ips "$PEERS_DIR"/*.subips \
                 "$DATA_DIR/self.stats" "$WEBROOT/cluster/stats" "$WEBROOT/cluster/ips" "$WEBROOT/cluster/subips"; do
            [ -f "$f" ] && _ip_scrub_file "$f"
        done
        rm -f "$DATA_DIR/onlineips.dat" 2>/dev/null    # сирота прежней схемы (P-72), только адреса
    else
        for f in "$IPS_FILE" "$SUBIPS_FILE" "$AUTHMAP_FILE" "$SLOTMAP_FILE"; do
            [ -f "$f" ] && : > "$f"
        done
        rm -f "$PEERS_DIR"/*.ips "$PEERS_DIR"/*.subips 2>/dev/null   # соседи пришлют уже новыми
    fi
}

# Каталоги для настоящих адресов: в /run, то есть в памяти. tmpfiles.d
# пересоздаёт их на загрузке ДО старта Caddy — иначе он не открыл бы свой лог
# и не поднялся бы.
raw_dirs_ensure() {
    local owner group cuser want
    owner=root; group=root
    declare -F service_identity >/dev/null 2>&1 && read -r owner group < <(service_identity)
    cuser=$(id -un caddy 2>/dev/null || echo root)
    want="# hy2-manager: настоящие адреса клиентов живут только в памяти (P-176)
d ${RAW_DIR} 0755 root root -
d ${RAW_DIR}/hy 0700 ${owner:-root} ${group:-root} -
d ${RAW_DIR}/caddy 0700 ${cuser} ${cuser} -"
    if [ "$(cat "$TMPFILES_CONF" 2>/dev/null)" != "$want" ]; then
        mkdir -p "$(dirname "$TMPFILES_CONF")" 2>/dev/null
        printf '%s\n' "$want" > "$TMPFILES_CONF" 2>/dev/null
    fi
    [ -d "$RAW_DIR/hy" ] && [ -d "$RAW_DIR/caddy" ] && return 0
    systemd-tmpfiles --create "$TMPFILES_CONF" >/dev/null 2>&1 || {
        mkdir -p "$RAW_DIR/hy" "$RAW_DIR/caddy"
        chown "${owner:-root}:${group:-root}" "$RAW_DIR/hy" 2>/dev/null
        chown "$cuser:$cuser" "$RAW_DIR/caddy" 2>/dev/null
        chmod 700 "$RAW_DIR/hy" "$RAW_DIR/caddy"
    }
}

# Настоящие адреса Hysteria старше часа не нужны и tc-раскладке.
raw_authmap_trim() {
    [ -s "$RAW_AUTHMAP" ] || return 0
    local tmp="${RAW_AUTHMAP}.tmp.$BASHPID"
    awk -F'|' -v cut=$(( $(date +%s) - RAW_RETENTION_SEC )) 'NF>=3 && $3+0>=cut' "$RAW_AUTHMAP" > "$tmp" \
        && cat "$tmp" > "$RAW_AUTHMAP"
    rm -f "$tmp"
}

# ExecStart демона, чей вывод уходит в journald только через фильтр адресов.
# Демон и фильтр — один конвейер: упал демон — закончился ввод фильтра, а
# pipefail отдаёт systemd код самого демона, так что Restart= работает как раньше.
logscrub_execstart() {   # "команда демона" -> значение ExecStart
    printf "/bin/bash -c 'set -o pipefail; %s 2>&1 | python3 -u %s scrub %s'" "$1" "$IPHASH_PY" "$IP_SALT_FILE"
}

# Вывод Hysteria — через фильтр. Юнит ставит её установщик, поэтому не правим
# его, а кладём drop-in с исходной командой из самого юнита. Поменялся — один
# рестарт Hysteria (клиенты переподключатся сами).
hy_logscrub_ensure() {
    local frag orig dropin want
    frag=$(systemctl show "$SERVICE" -p FragmentPath --value 2>/dev/null)
    [ -f "$frag" ] || return 0
    orig=$(sed -n 's/^ExecStart=\(.\+\)$/\1/p' "$frag" | head -1)
    [ -n "$orig" ] || return 0
    dropin="/etc/systemd/system/${SERVICE%.service}.service.d/20-hy2-logscrub.conf"
    want="# hy2-manager (P-176): адреса клиентов в журнал — только хэшем
[Service]
ExecStart=
ExecStart=$(logscrub_execstart "$orig")"
    [ "$(cat "$dropin" 2>/dev/null)" = "$want" ] && return 0
    mkdir -p "$(dirname "$dropin")" && printf '%s\n' "$want" > "$dropin" || return 1
    systemctl daemon-reload >/dev/null 2>&1
    systemctl restart "$SERVICE" >/dev/null 2>&1
}

# Всё, что держит адреса скрытыми, — одной идемпотентной точкой. Зовётся из
# --online-sync: на ноду, куда никто не заходит, приезжает с ближайшим кроном.
ip_privacy_ensure() {
    command -v python3 >/dev/null 2>&1 || return 0
    raw_dirs_ensure
    ip_salt_sync
    # Скрипт аутентификации старой версии пишет адреса открытыми — переложить.
    [ -f "$AUTH_SCRIPT" ] && ! grep -q '^RAWMAP=' "$AUTH_SCRIPT" 2>/dev/null \
        && declare -F install_auth_script >/dev/null && install_auth_script
    raw_authmap_trim
    hy_logscrub_ensure
    declare -F proto_logscrub_ensure >/dev/null && proto_logscrub_ensure
    declare -F caddy_rawlog_ensure >/dev/null && caddy_rawlog_ensure
    return 0
}

# Ставит срок хранения журнала. Идемпотентна: файл на месте и совпадает —
# выходим молча, поэтому её дёшево звать на каждом старте менеджера. Правит
# журнал ноды целиком, а не только своих юнитов: journald нарезает срок на
# хранилище, а не на отдельный сервис.
journal_retention_ensure() {
    command -v journalctl >/dev/null 2>&1 || return 0
    local want
    want="# Поставлено hy2-manager (P-79): в журнале лежат связки «IP ↔ юзер».
# Срок — JOURNAL_RETENTION_DAYS в lib/ip_tracking.sh.
[Journal]
MaxRetentionSec=${JOURNAL_RETENTION_DAYS}d"

    [ "$(cat "$JOURNALD_DROPIN" 2>/dev/null)" = "$want" ] && return 0

    mkdir -p "$(dirname "$JOURNALD_DROPIN")" 2>/dev/null || return 0
    printf '%s\n' "$want" > "$JOURNALD_DROPIN" 2>/dev/null || return 0
    # MaxRetentionSec применяется на ротации, то есть к уже накопленному — не
    # раньше следующего файла. Поэтому явный vacuum: он и подрезает прошлое.
    systemctl restart systemd-journald >/dev/null 2>&1
    journalctl --vacuum-time="${JOURNAL_RETENTION_DAYS}d" >/dev/null 2>&1
}
slotmap_trim() {
    [ -s "$SLOTMAP_FILE" ] || return 0
    local cut tmp owner group
    cut=$(( $(date +%s) - SLOTMAP_RETENTION_HOURS * 3600 ))
    awk -F'|' -v cut="$cut" 'NF>=4 && $4+0 < cut { found=1; exit } END { exit(found?0:1) }' \
        "$SLOTMAP_FILE" || return 0
    tmp="${SLOTMAP_FILE}.tmp.$BASHPID"
    awk -F'|' -v cut="$cut" 'NF>=4 && $1!="" && $4+0 >= cut' "$SLOTMAP_FILE" > "$tmp" \
        && mv "$tmp" "$SLOTMAP_FILE" 2>/dev/null || { rm -f "$tmp"; return 0; }
    # Дописывает файл процесс hysteria — после mv вернуть владельца обязательно.
    if declare -F service_identity >/dev/null 2>&1; then
        read -r owner group < <(service_identity)
        [ -n "$owner" ] && chown "${owner}:${group}" "$SLOTMAP_FILE" 2>/dev/null
    fi
    chmod 644 "$SLOTMAP_FILE" 2>/dev/null
}

authmap_trim() {
    [ -s "$AUTHMAP_FILE" ] || return 0
    local cut tmp owner group
    cut=$(( $(date +%s) - AUTHMAP_RETENTION_DAYS * 86400 ))
    # Есть ли хоть одна протухшая строка? Нет — файл не трогаем вовсе.
    awk -F'|' -v cut="$cut" 'NF>=3 && $3+0 < cut { found=1; exit } END { exit(found?0:1) }' \
        "$AUTHMAP_FILE" || return 0
    tmp="${AUTHMAP_FILE}.tmp.$BASHPID"
    awk -F'|' -v cut="$cut" 'NF>=3 && $1!="" && $3+0 >= cut' "$AUTHMAP_FILE" > "$tmp" \
        && mv "$tmp" "$AUTHMAP_FILE" 2>/dev/null || { rm -f "$tmp"; return 0; }
    # Файл дописывает сервис Hysteria из-под своего пользователя: после mv вернуть
    # владельца обязательно, иначе append начнёт молча падать и живой маппинг
    # user→IP умрёт (тарифный шейпинг и счёт устройств вместе с ним).
    if declare -F service_identity >/dev/null 2>&1; then
        read -r owner group < <(service_identity)
        [ -n "$owner" ] && chown "${owner}:${group}" "$AUTHMAP_FILE" 2>/dev/null
    fi
    chmod 644 "$AUTHMAP_FILE" 2>/dev/null
}

# Слияние «user|ip» (или «token|ip») со stdin в файл истории «key|ip|first|last|count».
# Одним awk: старый файл читается один раз, новые пары досчитываются в памяти,
# протухшие записи выбрасываются. Раньше на КАЖДУЮ строку журнала делались grep
# + sed -i, то есть полная перезапись файла на каждое подключение.
#
# Третий аргумент — сколько СВОЙСТВ ключа идёт после двух ключевых колонок
# (по умолчанию 0, формат старых файлов не меняется). Свойство — не часть
# ключа: оно перезаписывается при каждой встрече. Так «версия приложения» у
# того же устройства обновляется сама, не плодя вторую строку (subapps.dat).
# Формат с nattr: «key1|key2|свойства...|first|last|count».
_ips_merge() {   # файл  now  [nattr]
    local file="$1" now="$2" nattr="${3:-0}" tmp="$1.tmp.$BASHPID"
    touch "$file" 2>/dev/null || return 0
    awk -v old="$file" -v now="$now" -v na="$nattr" \
        -v cut=$(( now - IPS_RETENTION_DAYS * 86400 )) '
        BEGIN {
            FS = "\t"
            need = 5 + na            # key1 key2 [свойства] first last count
            while ((getline line < old) > 0) {
                n = split(line, p, "|")
                if (n < need || p[1] == "" || p[4 + na] + 0 < cut) continue
                k = p[1] "|" p[2]
                if (k in cnt) continue
                a = ""
                for (i = 3; i < 3 + na; i++) a = a p[i] "|"
                attr[k] = a
                first[k] = p[3 + na]; last[k] = p[4 + na]; cnt[k] = p[5 + na]
                ord[++total] = k
            }
        }
        $1 != "" && $2 != "" {
            k = $1 "|" $2
            a = ""
            for (i = 3; i < 3 + na; i++) a = a $i "|"
            attr[k] = a              # свойства всегда от последней встречи
            if (k in cnt) { last[k] = now; cnt[k] = cnt[k] + 1 }
            else { first[k] = now; last[k] = now; cnt[k] = 1; ord[++total] = k }
        }
        END {
            for (i = 1; i <= total; i++) {
                k = ord[i]; split(k, p, "|")
                printf "%s|%s|%s%s|%s|%s\n", p[1], p[2], attr[k], first[k], last[k], cnt[k]
            }
        }' > "$tmp" && mv "$tmp" "$file" || rm -f "$tmp"
}

collect_ips() {
    local since_ts=""
    if [ -f "$LAST_LOG_TS" ] && [ -s "$LAST_LOG_TS" ]; then
        since_ts=$(cat "$LAST_LOG_TS")
    else
        since_ts=$(date -d '30 days ago' '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "30 days ago")
    fi
    date '+%Y-%m-%d %H:%M:%S' > "$LAST_LOG_TS"

    # ВАЖНО: Hysteria 2 (auth.type: command) логирует подключение строкой
    #   ... msg":"client connected" ... "addr":"<IP>:<порт>" ... "id":"<user>"
    # Поля «username» в логе НЕТ — раньше тут грепали именно его, поэтому IP
    # НИКОГДА не собирались («IP-адресов нет» в карточке). Берём пару addr+id из
    # событий подключения. «client disconnected» исключаем (это не новый коннект).
    local now; now=$(date +%s)
    journalctl -u "$SERVICE" --no-pager -o cat --since="$since_ts" 2>/dev/null \
      | grep -F 'client connected' \
      | awk '{
            # addr/remote/client — на разных версиях по-разному; берём адрес до «:».
            # Значение достаём разбором по кавычкам: не зависит от пробелов.
            # Закрывающую кавычку НЕ требуем: адрес в логе с портом («ip:port»),
            # значение обрывается на первом же символе не из класса. В журнале
            # уже хэш «h<hex>» (фильтр вывода Hysteria, P-176), в строках до
            # фильтра — IPv4; их ниже переводит ip_scrub.
            ip = ""; user = ""
            if (match($0, /"(addr|remote|client)"[ \t]*:[ \t]*"[0-9a-f.h]+/)) {
                s = substr($0, RSTART, RLENGTH); n = split(s, q, "\""); ip = q[n]
            }
            # id (имя из auth-скрипта); username — на случай иного формата лога.
            if (match($0, /"(id|username)"[ \t]*:[ \t]*"[^"]*/)) {
                s = substr($0, RSTART, RLENGTH); n = split(s, q, "\""); user = q[n]
            }
            if (ip != "" && user != "" && ip != "127.0.0.1") printf "%s\t%s\n", user, ip
        }' \
      | ip_scrub \
      | _ips_merge "$IPS_FILE" "$now"
}

# Окно, в котором адрес ещё РАБОТАЕТ, а не просто лежит историей. Столько же
# смотрит счёт устройств в webapi (DEVICES_WINDOW_SEC): адрес свежее суток —
# это «устройство, которое сейчас пользуется», по нему считается лимит и по нему
# же раскладываются пер-IP правила скорости.
IPS_ACTIVE_WINDOW_SEC="${IPS_ACTIVE_WINDOW_SEC:-86400}"

# Забыть адреса пользователя по его же просьбе (кабинет, экран «Мои данные»).
#
# Удаляем ТОЛЬКО записи старше активного окна — и это не осторожность, а
# граница, за которой начинается абуз:
#   • счёт устройств смотрит на сутки назад. Разреши удалять свежие записи —
#     и лимит устройств снимается одной кнопкой: раздал подписку десятерым,
#     нажал «забыть», счётчик чист;
#   • привязка трафика на общих адресах и пер-IP шейпинг тоже читают свежие
#     строки (protocols.sh, perf.sh) — вырванная из-под них запись ломает учёт;
#   • всё, что старше суток, не читает НИКТО: подозрение на общий доступ давно
#     считается по одновременной активности на нодах, а не по числу адресов
#     (см. шапку lib/antiabuse.sh). Поэтому удаление старого не ослабляет
#     защиту вовсе — оно просто убирает историю, которая никому не нужна.
#
# Гонка с --collect: оба переписывают файл целиком, разошедшиеся строки в
# худшем случае доживут до следующего запуска. Цена — полчаса; плата за
# честный flock здесь была бы дороже самой операции.
#
# Печатает «удалено|осталось». Соседние узлы держат СВОИ копии: их эта функция
# не трогает и трогать не может — они вернутся ближайшей синхронизацией.
ips_forget() {   # user
    local user="$1" cut tmp before after removed left
    [ -n "$user" ] || return 1
    cut=$(( $(date +%s) - IPS_ACTIVE_WINDOW_SEC ))

    before=$(get_user_ip_count "$user")
    tmp="${IPS_FILE}.tmp.$BASHPID"
    awk -F'|' -v user="$user" -v cut="$cut" \
        '!($1 == user && NF >= 4 && $4 + 0 < cut)' "$IPS_FILE" > "$tmp" \
        && mv "$tmp" "$IPS_FILE" || { rm -f "$tmp"; return 1; }
    after=$(get_user_ip_count "$user")
    removed=$(( before - after ))

    # Адреса, скачивавшие подписку по ссылкам этого юзера, — та же история и тот
    # же срок. Ключ там токен, поэтому сначала собираем токены пользователя.
    local tokens
    tokens=$(awk -F: -v u="$user" '$1 == u { print $2 }' "$SUBTOKENS_DB" 2>/dev/null | tr '\n' ' ')
    if [ -n "${tokens// /}" ] && [ -s "$SUBIPS_FILE" ]; then
        tmp="${SUBIPS_FILE}.tmp.$BASHPID"
        awk -F'|' -v toks=" $tokens " -v cut="$cut" '
            NF >= 4 && index(toks, " " $1 " ") && $4 + 0 < cut { next }
            { print }
        ' "$SUBIPS_FILE" > "$tmp" && mv "$tmp" "$SUBIPS_FILE" || rm -f "$tmp"
    fi

    left="$after"
    printf '%s|%s\n' "$removed" "$left"
}

# Забыть, какими приложениями скачивали подписку (кабинет, «Мои данные»).
#
# Здесь, в отличие от ips_forget, удаляем ВСЁ, а не только старое: на этих
# записях ничего не стоит. Лимит устройств считается по адресам и слотам, кик и
# анти-абуз их не читают, тариф от них не зависит — стереть можно без дыры.
# Правило экрана «Мои данные» ровно такое: не стоит ничего — удаляем целиком,
# половинчатое «сотрём, но данные ещё поработают» и есть дыра в лимитах.
#
# Отметки «об этом устройстве уже писали» (SUBAPPS_SEEN_FILE) НЕ трогаем: это не
# сведения о человеке, а предохранитель от спама. Сотри их вместе со строками —
# и следующее же обновление подписки принесёт владельцу заново то самое
# уведомление, от которого он только что избавился. Полное забвение (erase_user)
# чистит и их: там человека не остаётся вовсе, спамить некому.
#
# Печатает число удалённых строк.
apps_forget() {   # user
    local user="$1" tokens tmp before after
    [ -n "$user" ] || return 1
    [ -s "$SUBAPPS_FILE" ] || { echo 0; return 0; }
    tokens=$(sub_tokens_cluster "$user" 2>/dev/null | tr '\n' ' ')
    [ -n "${tokens// /}" ] || { echo 0; return 0; }

    before=$(grep -c . "$SUBAPPS_FILE" 2>/dev/null || echo 0)
    tmp="${SUBAPPS_FILE}.tmp.$BASHPID"
    awk -F'|' -v toks=" $tokens " '!index(toks, " " $1 " ")' "$SUBAPPS_FILE" > "$tmp" \
        && mv "$tmp" "$SUBAPPS_FILE" || { rm -f "$tmp"; return 1; }
    after=$(grep -c . "$SUBAPPS_FILE" 2>/dev/null || echo 0)
    echo $(( before - after ))
}

get_user_ip_count() {
    local count
    count=$(grep -c "^${1}|" "$IPS_FILE" 2>/dev/null || true)
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    echo "$count"
}

get_user_ips() {
    grep "^${1}|" "$IPS_FILE" 2>/dev/null
}

# Собирает из access-лога Caddy ДВА файла разом: кто скачивал подписку по
# конкретному токену (SUBIPS_FILE, «token|ip|...») и чем скачивал
# (SUBAPPS_FILE, «token|hwid|приложение|версия|ОС|модель|...»).
#
# Caddy пишет access-лог в stderr → journald (в файл /var/log/caddy писать нельзя:
# процессу caddy под systemd туда нет доступа, и это роняет старт Caddy). Читаем
# журнал так же, как collect_ips читает лог hysteria. Инкрементально по метке
# SUBLOG_TS (человекочитаемая дата --since). Время — момент сбора (как в collect_ips).
#
# Почему приложение видно ТОЛЬКО здесь: на туннеле клиента не опознать вовсе.
# Hysteria зовёт auth-скрипт с тремя аргументами (адрес, кред, tx), у Xray
# клиентской идентичности нет, у sing-box в метаданных нет даже юзера (P-17),
# а TLS-отпечаток REALITY специально мимикрирует под браузер. Единственный
# момент, когда приложение само себя называет, — HTTP-запрос за подпиской.
#
# Что реально присылают (замерено на живом логе): Happ, v2raytun и INCY шлют
# X-Hwid + модель + версию ОС; Hiddify и v2rayNG — только User-Agent. Поэтому
# hwid может быть пустым, и «-» тут не «неизвестное устройство», а «клиент не
# представился»: все такие запросы по одному токену сливаются в одну строку.
# Отдаёт накопленный лог Caddy и обнуляет его. Caddy пишет с O_APPEND, поэтому
# обнуление безопасно: следующая строка ляжет в начало. Строка, пришедшая между
# cat и обнулением, теряется — это одна загрузка подписки, IP вернётся со
# следующей. Ротированные куски (roll_size) забираем и удаляем.
_caddy_rawlog_take() {
    local f
    for f in "${CADDY_RAW_LOG%.log}"-*.log "$CADDY_RAW_LOG"; do
        [ -s "$f" ] || continue
        cat "$f"
        if [ "$f" = "$CADDY_RAW_LOG" ]; then : > "$f"; else rm -f "$f"; fi
    done
}

collect_sub_ips() {
    command -v jq >/dev/null 2>&1 || return 0
    command -v journalctl >/dev/null 2>&1 || return 0
    touch "$SUBIPS_FILE" "$SUBAPPS_FILE" 2>/dev/null
    local since now raw
    if [ -s "$SUBLOG_TS" ]; then
        since=$(cat "$SUBLOG_TS")
    else
        since=$(date -d '7 days ago' '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "7 days ago")
    fi
    date '+%Y-%m-%d %H:%M:%S' > "$SUBLOG_TS"
    now=$(date +%s)

    # Один проход по журналу на оба файла: journalctl по трём суткам лога — самая
    # дорогая часть сбора, и делать её дважды только ради второй проекции нельзя.
    # Промежуточный файл держит настоящие адреса — значит, он в памяти (RAW_DIR).
    raw_dirs_ensure
    raw=$(mktemp -p "$RAW_DIR" 2>/dev/null) || return 0

    # Источник — лог Caddy в RAW_DIR (caddy_rawlog_ensure, P-176): забираем и
    # обнуляем, так адреса в нём живут до ближайшего сбора. Журнал — для ноды,
    # где Caddy ещё не переключён, и для строк, записанных до переключения.
    # fromjson? пропускает не-JSON и служебные строки Caddy. remote_ip (новые
    # версии) или remote_addr «ip:port» (старые). Значения заголовков у Caddy —
    # массивы, отсюда `// [""] | .[0]`.
    { _caddy_rawlog_take
      journalctl -u caddy --no-pager -o cat --since="$since" 2>/dev/null; } \
      | grep -F '/sub/' \
      | jq -rR 'fromjson?
                | select(.request?.uri != null)
                | select(.request.uri | startswith("/sub/"))
                | .request as $r | ($r.headers // {}) as $h
                | [ ($r.remote_ip // (($r.remote_addr // "") | split(":")[0]) // ""),
                    $r.uri,
                    (($h["User-Agent"]     // [""]) | .[0]),
                    (($h["X-Hwid"]         // [""]) | .[0]),
                    (($h["X-Client"]       // [""]) | .[0]),
                    (($h["X-App-Version"]  // [""]) | .[0]),
                    (($h["X-Device-Os"]    // [""]) | .[0]),
                    (($h["X-Ver-Os"]       // [""]) | .[0]),
                    (($h["X-Device-Model"] // [""]) | .[0]) ] | @tsv' 2>/dev/null \
      | awk -F'\t' -v OFS='\t' '
            # «|» — наш разделитель полей, таб — разделитель на входе слияния.
            # Всё, что пришло от клиента, обязано их лишиться до записи в файл.
            function clean(s) { gsub(/[|\t]/, " ", s); gsub(/^ +| +$/, "", s); return s }
            function word(s) { sub(/ .*$/, "", s); return s }
            {
                ip = $1; uri = $2; ua = $3; hwid = $4
                xclient = $5; xappver = $6; xos = $7; xosver = $8; model = $9
                sub(/^\/sub\//, "", uri); sub(/[?\/].*$/, "", uri)
                if (uri !~ /^[A-Za-z0-9]+$/) next
                if (ip != "" && ip != "127.0.0.1") print "IP", uri, ip

                # Имя приложения: заголовок X-Client честнее UA (INCY),
                # иначе — часть UA до первого «/».
                n = split(ua, u, "/")
                app = xclient != "" ? xclient : word(u[1])
                # Версия: свой заголовок, иначе второй кусок UA, если он похож
                # на версию («v2raytun/android» — это ОС, а не версия).
                # Только первое СЛОВО: у Hiddify весь хвост идёт без слэша
                # («4.1.1 (windows) like ClashMeta …»), и целиком он не версия.
                ver = xappver
                if (ver == "" && n >= 2 && word(u[2]) ~ /^[0-9][0-9.]*$/) ver = word(u[2])
                # ОС: свой заголовок; иначе скобки Hiddify «(windows)»;
                # иначе третий кусок UA (Happ, INCY); иначе второй, если он
                # не версия (v2raytun).
                os = xos
                if (os == "" && match(ua, /\([A-Za-z]+\)/))
                    os = substr(ua, RSTART + 1, RLENGTH - 2)
                if (os == "" && n >= 3) os = word(u[3])
                if (os == "" && n >= 2 && u[2] !~ /^[0-9][0-9.]*$/) os = word(u[2])
                # Версия ОС: Happ шлёт голое «15», v2raytun — «Android 11».
                if (xosver != "") os = (xosver ~ /^[0-9]/) ? os " " xosver : xosver

                if (app == "") app = "-"
                app = clean(app); ver = clean(ver); os = clean(os)
                # Клиент не назвал устройство — ключом становится «~приложение/ОС».
                # Просто «-» на всех сразу нельзя: ключ строки — токен+hwid, и
                # Hiddify на ноутбуке с Hiddify на телефоне слились бы в одну
                # запись, где выигрывает последний увиденный. «~» помечает, что
                # это НЕ идентификатор устройства: два одинаковых Hiddify на
                # одной ОС так и останутся одной строкой, различить их нечем.
                # Поэтому такие строки не считаются устройствами и никогда не
                # поднимают тревогу (lib/notify.sh).
                if (hwid == "") hwid = "~" app (os != "" ? "/" os : "")
                print "APP", uri, clean(hwid), app, ver, os, clean(model)
            }' > "$raw"

    awk -F'\t' -v OFS='\t' '$1 == "IP" { print $2, $3 }' "$raw" \
      | ip_scrub \
      | _ips_merge "$SUBIPS_FILE" "$now"
    awk -F'\t' -v OFS='\t' '$1 == "APP" { print $2, $3, $4, $5, $6, $7 }' "$raw" \
      | _ips_merge "$SUBAPPS_FILE" "$now" 4
    rm -f "$raw"
}

# Чем юзер скачивал подписку: строки SUBAPPS_FILE по всем его токенам.
# Печатает «hwid|приложение|версия|ОС|модель|first|last|count», свежие сверху.
#
# Токены берём КЛАСТЕРНЫЕ, а не только свои: наша нода отдаёт подписку и по
# токенам, выданным соседями (regen_user_subscription), — значит их скачивания
# тоже попали в наш лог и в SUBAPPS_FILE.
get_user_apps() {   # user
    local tokens
    tokens=$(sub_tokens_cluster "$1" 2>/dev/null | tr '\n' ' ')
    [ -n "${tokens// /}" ] || return 0
    [ -s "$SUBAPPS_FILE" ] || return 0
    awk -F'|' -v toks=" $tokens " 'NF >= 9 && index(toks, " " $1 " ") {
            sub(/^[^|]*\|/, ""); print
        }' "$SUBAPPS_FILE" 2>/dev/null | sort -t'|' -k7,7nr
}
