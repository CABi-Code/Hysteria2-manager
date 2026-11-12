#!/bin/bash
# ================================================
# Самодиагноз ноды и дозор кластера
# ================================================
# Нода раз в такт --online-sync пишет о себе короткую справку (что из
# положенного не работает, когда последний раз отработали кроны, сколько
# осталось сертификату и диску) и выкладывает её разделом `health` в файловый
# канал. Соседи забирают раздел вместе с остальными и показывают чужие беды у
# себя — в шапке меню, в `--health`, в суточном отчёте и живым сообщением
# админам (`--watch`). Замысел и пороги — docs/guide/NODE-HEALTH.md.
#
# Раньше сосед знал о ноде одно: отвечает ли её :443 (peer_probe). Нода с
# упавшим ядром протокола или вставшим кроном отвечала исправно и считалась
# здоровой, пока не напишет клиент.

HEALTH_STALE_SEC=900        # справка пира старше — его крон стоит
HEALTH_HEAL_GAP_SEC=600     # не чаще одного подъёма юнита за это время
HEALTH_CERT_MIN_DAYS=14     # Caddy продлевает за 30 дней; меньше 14 — не продлил
HEALTH_DISK_MAX_PCT=90
HEALTH_TAIL_SEC=900         # сколько ещё печатать итог закрытого инцидента
HEALTH_SELF_FILE="$DATA_DIR/health.dat"
HEALTH_WATCH_KEYS="$DATA_DIR/watch_keys.dat"

# Отметка «режим крона дошёл до конца». Замок (.mode.lock) говорит о старте, а
# зависший или упавший на полпути прогон от здорового отличает только финиш.
cron_done() { touch "$DATA_DIR/.$1.done" 2>/dev/null; }
# Сколько секунд назад режим отработал. Отметки ещё нет (нода только что
# обновилась) — 0: о том, чего не знаем, не тревожим.
cron_age() {   # mode -> сек
    local m; m=$(stat -c %Y "$DATA_DIR/.$1.done" 2>/dev/null) || { echo 0; return; }
    echo $(( $(date +%s) - m ))
}

# Юниты, которые на этой ноде ОБЯЗАНЫ работать: «метка|юнит». Список живой —
# из настроек, а не перечислением: выключенный протокол бедой не считается.
health_units() {
    echo "hysteria|$SERVICE"
    sub_enabled && echo "caddy|caddy.service"
    declare -F proto_xray_needed >/dev/null 2>&1 && proto_xray_needed && echo "xray|$XRAY_SERVICE"
    declare -F proto_tuic_enabled >/dev/null 2>&1 && proto_tuic_enabled && echo "tuic|$SINGBOX_SERVICE"
    declare -F webapi_enabled >/dev/null 2>&1 && webapi_enabled && echo "webapi|hy2-webapi.service"
    declare -F bot_enabled >/dev/null 2>&1 && bot_enabled && echo "bot|hy2-bot.service"
    return 0
}

# Дней до конца сертификата домена ноды. Считается раз в час: четыре вызова
# openssl на каждый такт — не то, на что стоит тратить слабое ядро.
_health_cert_days() {
    local cache="$DATA_DIR/.health_cert" crt end
    if [ -z "$(find "$cache" -mmin -60 2>/dev/null)" ]; then
        crt=$(declare -F _proto_caddy_cert >/dev/null 2>&1 && _proto_caddy_cert "$(node_host)")
        if [ -n "$crt" ]; then
            end=$(date -d "$(openssl x509 -in "$crt" -noout -enddate 2>/dev/null | cut -d= -f2)" +%s 2>/dev/null)
            [ -n "$end" ] && echo $(( (end - $(date +%s)) / 86400 )) > "$cache"
        else
            echo none > "$cache"      # доверенного сертификата нет вовсе (P-32)
        fi
    fi
    cat "$cache" 2>/dev/null
}

# Справка о себе: строки «ключ=значение». Только факты, без оценок: пороги
# применяет читатель (health_problems), и поменять их можно, не дожидаясь
# обновления всех нод.
health_self() {
    local down="" l u healed
    while IFS='|' read -r l u; do
        systemctl is-active --quiet "$u" 2>/dev/null || down="${down:+$down,}$l"
    done < <(health_units)
    echo "ts=$(date +%s)"
    echo "ver=${MANAGER_VERSION:-unknown}"
    echo "down=$down"
    echo "cron=online-sync:$(cron_age online-sync),cluster-sync:$(cron_age cluster-sync),collect:$(cron_age collect)"
    echo "cert_days=$(sub_enabled && _health_cert_days)"
    echo "disk=$(df -P / 2>/dev/null | awk 'NR==2{print $5+0}')"
    healed=$(cat "$DATA_DIR/.health_healed" 2>/dev/null)
    echo "healed=$healed"
}

# Разобрать справку (stdin) в беды: «код<TAB>текст». Код стабилен от такта к
# такту (по нему дозор подтверждает беду вторым тактом), текст — для человека.
# Справка — данные соседа: читаем только то, что подошло под форму.
health_problems() {   # [peer] — для чужой справки проверяется ещё и её свежесть
    local peer="${1:-}"
    awk -F= -v peer="$peer" -v now="$(date +%s)" -v stale="$HEALTH_STALE_SEC" \
        -v cmin="$HEALTH_CERT_MIN_DAYS" -v dmax="$HEALTH_DISK_MAX_PCT" '
        { v[$1] = substr($0, length($1) + 2) }
        END {
            if (peer != "" && v["ts"] ~ /^[0-9]+$/ && now - v["ts"] > stale) {
                printf "stale\tсправка о себе не обновлялась %d мин — крон стоит\n", (now - v["ts"]) / 60
                exit                      # остальное в ней устарело вместе с ней
            }
            if (v["down"] ~ /^[a-z0-9,]+$/) {
                n = split(v["down"], d, ",")
                for (i = 1; i <= n; i++) printf "svc:%s\tне работает %s\n", d[i], d[i]
            }
            n = split(v["cron"], c, ",")
            lim["online-sync"] = 900; lim["cluster-sync"] = 1500; lim["collect"] = 5400
            for (i = 1; i <= n; i++) {
                split(c[i], kv, ":")
                if ((kv[1] in lim) && kv[2] ~ /^[0-9]+$/ && kv[2] + 0 > lim[kv[1]])
                    printf "cron:%s\tкрон %s не отрабатывал %d мин\n", kv[1], kv[1], kv[2] / 60
            }
            if (v["cert_days"] == "none")
                printf "cert\tнет доверенного сертификата — подписка и TLS-протоколы у клиентов не работают\n"
            else if (v["cert_days"] ~ /^-?[0-9]+$/ && v["cert_days"] + 0 < cmin)
                printf "cert\tсертификат истекает через %d дн. и не продлевается\n", v["cert_days"]
            if (v["disk"] ~ /^[0-9]+$/ && v["disk"] + 0 >= dmax)
                printf "disk\tдиск занят на %d%%\n", v["disk"]
        }'
}

# Поднять юнит, который systemd бросил поднимать (состояние failed: исчерпан
# лимит перезапусков, OOM и т.п.). Остановленный рукой юнит (inactive) не
# трогаем — админ мог остановить его намеренно. Подъём виден соседям и в
# справке (healed=), молча он не проходит.
health_heal() {
    local l u now last
    now=$(date +%s)
    while IFS='|' read -r l u; do
        systemctl is-failed --quiet "$u" 2>/dev/null || continue
        last=$(stat -c %Y "$DATA_DIR/.heal.$l" 2>/dev/null || echo 0)
        [ $(( now - last )) -ge "$HEALTH_HEAL_GAP_SEC" ] || continue
        touch "$DATA_DIR/.heal.$l"
        echo "[$(date '+%F %T')] health: $u в состоянии failed — поднимаю" >&2
        systemctl reset-failed "$u" 2>/dev/null
        systemctl start "$u" 2>/dev/null && echo "$l@$now" > "$DATA_DIR/.health_healed"
    done < <(health_units)
    # Нода с недоверенным сертификатом сама не лечится (P-32): выпуск сорвался
    # (не было A-записи, закрыт :80), Caddy откатился на свой CA и повторять не
    # спешит. Перезапуск заставляет его попробовать снова. Судья — настоящий
    # запрос к себе: рестарт только на отказе проверки цепочки (код curl 60), не
    # чаще раза в час — потолок Let's Encrypt на неудачные проверки выше.
    if sub_enabled && [ "$(cat "$DATA_DIR/.health_cert" 2>/dev/null)" = none ]; then
        last=$(stat -c %Y "$DATA_DIR/.heal.cert" 2>/dev/null || echo 0)
        if [ $(( now - last )) -ge 3600 ]; then
            curl -sS --max-time 6 -o /dev/null "https://$(node_host)/" 2>/dev/null
            if [ $? -eq 60 ]; then
                touch "$DATA_DIR/.heal.cert"
                echo "[$(date '+%F %T')] health: сертификат домена недоверенный — перезапускаю Caddy для нового выпуска" >&2
                systemctl restart caddy 2>/dev/null && echo "cert@$now" > "$DATA_DIR/.health_healed"
                rm -f "$DATA_DIR/.health_cert"
            fi
        fi
    fi
    return 0
}

# Такт: полечить, записать справку, выложить соседям. Зовётся из --online-sync.
publish_cluster_health() {
    health_heal
    health_self > "$HEALTH_SELF_FILE.tmp.$BASHPID" && mv -f "$HEALTH_SELF_FILE.tmp.$BASHPID" "$HEALTH_SELF_FILE"
    sub_enabled || return 0
    mkdir -p "$WEBROOT/cluster"
    cp -f "$HEALTH_SELF_FILE" "$WEBROOT/cluster/health" 2>/dev/null
    chmod 640 "$WEBROOT/cluster/health" 2>/dev/null || true
}

# Беды по справкам: своя (живая, а не из файла — меню должно видеть упавший юнит
# сразу) и каждого пира из реестра. Строки «код<TAB>Имя (хост) — текст».
health_lines() {
    local name host code text
    while IFS=$'\t' read -r code text; do
        [ -n "$code" ] && printf 'self:%s\t%s (эта нода) — %s\n' "$code" "$(node_name)" "$text"
    done < <(health_self | health_problems)
    [ -f "$CLUSTER_CONF" ] || return 0
    while IFS='|' read -r name host; do
        [ -n "$host" ] && [ "$host" != "$(node_host)" ] || continue
        name=$(cluster_peer_name "$host")
        [ -s "$PEERS_DIR/${name}.health" ] || continue
        while IFS=$'\t' read -r code text; do
            [ -n "$code" ] && printf '%s:%s\t%s (%s) — %s\n' "$host" "$code" "$name" "$host" "$text"
        done < <(health_problems peer < "$PEERS_DIR/${name}.health")
    done < "$CLUSTER_CONF"
}

# Живое сообщение инцидента для доставки по ключу: первая строка «имя:начало»,
# дальше HTML. Беды есть — сообщение печатается каждый такт (получатель правит
# одно и то же); бед не стало — тем же ключом уходит итог и повторяется
# HEALTH_TAIL_SEC на случай сорванной доставки. Пусто — сказать нечего.
incident_message() {   # имя заголовок ; stdin — подтверждённые беды, по строке
    local name="$1" title="$2" f="$DATA_DIR/${1}_episode" now since closed body l
    now=$(date +%s); body=$(grep .)
    since=""; closed=""
    [ -f "$f" ] && IFS='|' read -r since closed < "$f"
    [[ "$since" =~ ^[0-9]+$ ]] || since=""
    if [ -n "$body" ]; then
        if [ -z "$since" ] || [ -n "$closed" ]; then
            # Новый эпизод. Ключ строго растёт: закрытие и открытие в одну
            # секунду не должны дать новому сообщению старый ключ.
            since=$(( now > ${since:-0} ? now : ${since:-0} + 1 )); closed=""
        fi
        printf '%s|\n' "$since" > "$f"
        printf '%s:%s\n‼️ <b>%s</b>\n' "$name" "$since" "$title"
        while IFS= read -r l; do printf '%s\n' "$(tg_esc "$l")"; done <<< "$body"
        printf '<i>с %s · проверено %s</i>\n' "$(date -d "@$since" '+%d.%m %H:%M')" "$(date -d "@$now" +%H:%M)"
        return 0
    fi
    [ -n "$since" ] || return 0
    [ -n "$closed" ] || { closed=$now; printf '%s|%s\n' "$since" "$closed" > "$f"; }
    [ $(( now - closed )) -le "$HEALTH_TAIL_SEC" ] || return 0
    printf '%s:%s\n✅ <b>%s — снова в порядке</b>\n<i>было с %s по %s</i>\n' "$name" "$since" "$title" \
        "$(date -d "@$since" '+%d.%m %H:%M')" "$(date -d "@$closed" +%H:%M)"
}

# Дозор: печатает живое сообщение о бедах кластера (--watch). Беда объявляется
# со ВТОРОГО такта подряд — одиночный провал пробы или перезапуск юнита посреди
# обновления сообщения не стоят.
watch_run() {
    local cur prev confirmed
    cur=$(_cluster_health_lines)
    prev=$(cat "$HEALTH_WATCH_KEYS" 2>/dev/null)
    printf '%s\n' "$(cut -f1 <<< "$cur")" > "$HEALTH_WATCH_KEYS"
    confirmed=$(awk -F'\t' 'NR==FNR { seen[$0] = 1; next } ($1 in seen) { print $2 }' \
        <(printf '%s\n' "$prev") <(printf '%s\n' "$cur"))
    printf '%s\n' "$confirmed" | incident_message watch "Неполадки в кластере"
}
