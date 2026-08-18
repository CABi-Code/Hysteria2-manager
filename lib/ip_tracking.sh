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
_ips_merge() {   # файл  now
    local file="$1" now="$2" tmp="$1.tmp.$BASHPID"
    touch "$file" 2>/dev/null || return 0
    awk -v old="$file" -v now="$now" -v cut=$(( now - IPS_RETENTION_DAYS * 86400 )) '
        BEGIN {
            FS = "\t"
            while ((getline line < old) > 0) {
                n = split(line, p, "|")
                if (n < 5 || p[1] == "" || p[4] + 0 < cut) continue
                k = p[1] "|" p[2]
                if (k in cnt) continue
                first[k] = p[3]; last[k] = p[4]; cnt[k] = p[5]; ord[++total] = k
            }
        }
        $1 != "" && $2 != "" {
            k = $1 "|" $2
            if (k in cnt) { last[k] = now; cnt[k] = cnt[k] + 1 }
            else { first[k] = now; last[k] = now; cnt[k] = 1; ord[++total] = k }
        }
        END {
            for (i = 1; i <= total; i++) {
                k = ord[i]; split(k, p, "|")
                printf "%s|%s|%s|%s|%s\n", p[1], p[2], first[k], last[k], cnt[k]
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
            # addr/remote/client — на разных версиях по-разному; берём IPv4 до «:».
            # Значение достаём разбором по кавычкам: не зависит от пробелов.
            # Закрывающую кавычку НЕ требуем: адрес в логе с портом («ip:port»),
            # значение обрывается на первом же символе не из класса.
            ip = ""; user = ""
            if (match($0, /"(addr|remote|client)"[ \t]*:[ \t]*"[0-9.]+/)) {
                s = substr($0, RSTART, RLENGTH); n = split(s, q, "\""); ip = q[n]
            }
            # id (имя из auth-скрипта); username — на случай иного формата лога.
            if (match($0, /"(id|username)"[ \t]*:[ \t]*"[^"]*/)) {
                s = substr($0, RSTART, RLENGTH); n = split(s, q, "\""); user = q[n]
            }
            if (ip != "" && user != "" && ip != "127.0.0.1") printf "%s\t%s\n", user, ip
        }' \
      | _ips_merge "$IPS_FILE" "$now"
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

# Собирает IP, скачавшие подписку по КОНКРЕТНОМУ токену, из access-лога Caddy.
# Caddy пишет access-лог в stderr → journald (в файл /var/log/caddy писать нельзя:
# процессу caddy под systemd туда нет доступа, и это роняет старт Caddy). Читаем
# журнал так же, как collect_ips читает лог hysteria. Инкрементально по метке
# SUBLOG_TS (человекочитаемая дата --since). Формат SUBIPS_FILE — как IPS_FILE:
# «token|ip|first|last|count». Время — момент сбора (как в collect_ips).
collect_sub_ips() {
    command -v jq >/dev/null 2>&1 || return 0
    command -v journalctl >/dev/null 2>&1 || return 0
    touch "$SUBIPS_FILE" 2>/dev/null
    local since now
    if [ -s "$SUBLOG_TS" ]; then
        since=$(cat "$SUBLOG_TS")
    else
        since=$(date -d '7 days ago' '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "7 days ago")
    fi
    date '+%Y-%m-%d %H:%M:%S' > "$SUBLOG_TS"
    now=$(date +%s)

    # Одним проходом jq: из журнала Caddy берём JSON access-записи к /sub/*.
    # fromjson? пропускает не-JSON и служебные строки Caddy. remote_ip (новые
    # версии) или remote_addr «ip:port» (старые). Печатаем «ip<TAB>uri».
    journalctl -u caddy --no-pager -o cat --since="$since" 2>/dev/null \
      | grep -F '/sub/' \
      | jq -rR 'fromjson?
                | select(.request?.uri != null)
                | select(.request.uri | startswith("/sub/"))
                | [ (.request.remote_ip // ((.request.remote_addr // "") | split(":")[0]) // ""),
                    (.request.uri) ] | @tsv' 2>/dev/null \
      | awk -F'\t' '{
            ip = $1; uri = $2
            if (ip == "" || ip == "127.0.0.1") next
            sub(/^\/sub\//, "", uri); sub(/[?\/].*$/, "", uri)
            if (uri ~ /^[A-Za-z0-9]+$/) printf "%s\t%s\n", uri, ip
        }' \
      | _ips_merge "$SUBIPS_FILE" "$now"
}
