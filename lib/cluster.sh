#!/bin/bash
# ================================================
# Кластеризация нод для единой подписки.
# Ноды обмениваются манифестами ключей (за заголовком X-Cluster-Auth поверх TLS).
# Каждая нода держит полный кэш ключей кластера, поэтому ЛЮБАЯ нода отдаёт
# объединённую подписку. Обмен — периодический (cluster_sync, cron) + при правках.
# Активного удалённого CRUD в v1 нет (статика Caddy не исполняет код): юзера
# заводят на каждой ноде локально тем же именем, подписка объединяет их ключи.
# ================================================

# Общий секрет кластера (создаётся при первом обращении).
cluster_secret() {
    if [ ! -s "$CLUSTER_SECRET_FILE" ]; then
        pwgen -s 48 1 > "$CLUSTER_SECRET_FILE" 2>/dev/null
        chmod 600 "$CLUSTER_SECRET_FILE" 2>/dev/null
    fi
    cat "$CLUSTER_SECRET_FILE" 2>/dev/null
}

# Добавляет пир в реестр (без дублей по host).
cluster_add_peer() {   # name host
    local name="$1" host="$2"
    [ -n "$host" ] || return 1
    [ -n "$name" ] || name="$host"
    touch "$CLUSTER_CONF"
    grep -q "|${host}\$" "$CLUSTER_CONF" 2>/dev/null && return 0
    printf '%s|%s\n' "$name" "$host" >> "$CLUSTER_CONF"
}

# host'ы пиров, кроме самого себя.
cluster_peers() {
    local self; self=$(node_host)
    awk -F'|' -v s="$self" '$2!="" && $2!=s {print $2}' "$CLUSTER_CONF" 2>/dev/null | sort -u
}

# Удаляет пир из реестра + чистит его кэш. ВНИМАНИЕ: если пир «живой» и ещё есть
# в реестрах других нод, gossip вернёт его обратно — удаляйте на всех нодах.
# Недоступный/ошибочный пир после удаления просто перестаёт опрашиваться.
cluster_remove_peer() {   # host
    local host="$1" name tmp
    [ -n "$host" ] || return 1
    name=$(awk -F'|' -v h="$host" '$2==h{print $1; exit}' "$CLUSTER_CONF" 2>/dev/null)
    tmp=$(mktemp) || return 1
    awk -F'|' -v h="$host" '$2!=h' "$CLUSTER_CONF" > "$tmp" && cat "$tmp" > "$CLUSTER_CONF"
    rm -f "$tmp"
    if [ -n "$name" ]; then
        rm -f "$PEERS_DIR/${name}.manifest" "$PEERS_DIR/${name}.stats" "$PEERS_DIR/${name}.subtokens" "$PEERS_DIR/${name}.roster" "$PEERS_DIR/${name}.state" "$PEERS_DIR/${name}.ips" "$PEERS_DIR/${name}.expiry" "$PEERS_DIR/${name}.settings" "$PEERS_DIR/${name}.userlimits" "$PEERS_DIR/${name}.subips" "$PEERS_DIR/${name}.tgbind" 2>/dev/null
    fi
    publish_peers_list
    regen_subscriptions
}

# Публикует реестр пиров статикой (для gossip между нодами).
publish_peers_list() {
    sub_enabled || return 0
    mkdir -p "$WEBROOT/cluster"
    cp -f "$CLUSTER_CONF" "$WEBROOT/cluster/peers.list" 2>/dev/null || true
    secure_web_files
}

# Запрос к пиру с кластерной аутентификацией.
cluster_call() {   # host path [timeout] -> stdout
    local host="$1" path="$2" to="${3:-8}" secret
    secret=$(cluster_secret)
    curl -fsS --max-time "$to" -H "X-Cluster-Auth: $secret" "https://${host}${path}" 2>/dev/null
}

# ---- Здоровье пиров -----------------------------------------------------
# Диагноз по пиру. DNS проверяем ОТДЕЛЬНО от HTTPS: пропавшая A-запись (смена
# NS, домен за прокси-CDN) выглядит так же, как «пир выключен», но чинится
# совсем иначе — и клиенты при этом ловят ровно тот же обрыв, что и мы.
peer_probe() {   # host -> 0/1, печатает причину при отказе
    local host="$1"
    # Сначала реальный запрос: он единственный судья доступности. DNS проверяем
    # ТОЛЬКО чтобы объяснить уже случившийся отказ — иначе флапающий резолвер
    # (негативный кэш апстрима после смены NS отдаёт NXDOMAIN через раз)
    # хоронил бы живого пира, до которого curl достучался бы сам.
    cluster_call "$host" "/cluster/manifest" 8 >/dev/null 2>&1 && return 0
    local tls_ok=1
    echo | timeout 8 openssl s_client -connect "${host}:443" -servername "$host" \
        >/dev/null 2>&1 || tls_ok=0
    if ! getent hosts "$host" >/dev/null 2>&1; then
        echo "домен не резолвится (нет A-записи / DNS)"
    elif [ "$tls_ok" = 0 ]; then
        echo "не отвечает на :443 (нода лежит / файрвол)"
    elif ! echo | timeout 8 openssl s_client -connect "${host}:443" -servername "$host" \
              -verify_return_error >/dev/null 2>&1; then
        # Рукопожатие проходит, проверка цепочки — нет. Так выглядит нода,
        # которой Caddy не смог выписать Let's Encrypt и откатился на свой CA:
        # клиенты при этом не могут ни забрать подписку, ни поднять TLS-протокол.
        echo "сертификат невалиден (самоподписанный / не переоформлен)"
    else
        echo "сертификат ок, но данные не отдаёт (секрет кластера / Caddy)"
    fi
    return 1
}

# Итог опроса пира на диск. Пишется и при молчаливом cron-прогоне — иначе
# недоступность видно только в verbose-логе ручной синхронизации.
peer_health_set() {   # host name ok reason
    mkdir -p "$PEERS_DIR" 2>/dev/null
    local tmp; tmp=$(mktemp) || return 0
    grep -v "^$1|" "$PEERS_HEALTH_FILE" 2>/dev/null > "$tmp"
    printf '%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$(date +%s)" "$4" >> "$tmp"
    cat "$tmp" > "$PEERS_HEALTH_FILE"; rm -f "$tmp"
}

# Сводка для TUI/бота: пусто = всё в порядке. Иначе строки «name (host) — причина».
# Пир, по которому синхронизации не было дольше PEER_STALE_SEC, тоже проблема:
# cron мог не отработать вовсе, и тогда свежего вердикта просто нет.
PEER_STALE_SEC=900
cluster_health_report() {
    [ -s "$PEERS_HEALTH_FILE" ] || return 0
    local now; now=$(date +%s)
    local host name ok ts reason age
    while IFS='|' read -r host name ok ts reason; do
        [ -n "$host" ] || continue
        [ "$host" = "$(node_host)" ] && continue          # мы сами
        # Пир удалён из реестра — старый вердикт не повод для тревоги.
        grep -q "|$host\$" "$CLUSTER_CONF" 2>/dev/null || continue
        [[ "$ts" =~ ^[0-9]+$ ]] || ts=0
        age=$(( now - ts ))
        if [ "$ok" != "1" ]; then
            printf '%s (%s) — %s\n' "${name:-$host}" "$host" "${reason:-недоступен}"
        elif [ "$age" -gt "$PEER_STALE_SEC" ]; then
            printf '%s (%s) — нет синхронизации %d мин\n' "${name:-$host}" "$host" "$((age / 60))"
        fi
    done < "$PEERS_HEALTH_FILE"
}

# Одна строка для шапки главного меню. Пусто = проблем нет.
cluster_health_banner() {
    local bad; bad=$(cluster_health_report | grep -c .) || true
    [ "${bad:-0}" -gt 0 ] || return 0
    printf '%s' "🔴 Пиров с проблемой: $bad — ключи этих нод могут не работать у клиентов"
}

# Живой опрос статистики пиров — для интерактивных экранов, где видно онлайн/
# скорость/трафик по кластеру. Троттлинг: не чаще раза в LIVE_THROTTLE сек, чтобы
# не дёргать пиров на каждый перерисов. Тайм-аут короткий (живые пиры отвечают
# быстро; недоступные не вешают интерфейс надолго).
LIVE_THROTTLE=4
cluster_stats_live() {
    sub_enabled || return 0
    local now last fp="$PEERS_DIR/.live_ts"
    now=$(date +%s); last=$(cat "$fp" 2>/dev/null); [[ "$last" =~ ^[0-9]+$ ]] || last=0
    [ $((now - last)) -lt "${LIVE_THROTTLE:-4}" ] && return 0
    mkdir -p "$PEERS_DIR"; echo "$now" > "$fp"
    publish_stats
    local host name data
    while IFS= read -r host; do
        [ -n "$host" ] || continue
        name=$(awk -F'|' -v h="$host" '$2==h{print $1; exit}' "$CLUSTER_CONF" 2>/dev/null)
        [ -z "$name" ] && name=$(printf '%s' "$host" | tr -c 'a-zA-Z0-9_.-' '_')
        data=$(cluster_call "$host" "/cluster/stats" 3)
        [ -n "$data" ] && printf '%s' "$data" > "$PEERS_DIR/${name}.stats"
    done < <(cluster_peers)
}

# Инициализация кластера на первой ноде. Печатает join-токен для остальных.
cluster_init() {
    sub_enabled || { echo "Сначала настройте домен ноды."; return 1; }
    cluster_secret >/dev/null
    cluster_add_peer "$(node_name)" "$(node_host)"
    publish_peers_list
    publish_manifest
    printf '%s|%s' "$(node_host)" "$(cluster_secret)" | base64 -w0
    echo
}

# Подключение к существующему кластеру по join-токену.
cluster_join() {   # token
    local token="$1" decoded host secret
    decoded=$(printf '%s' "$token" | base64 -d 2>/dev/null) || { echo "❌ Битый токен"; return 1; }
    host="${decoded%%|*}"; secret="${decoded#*|}"
    if [ -z "$host" ] || [ -z "$secret" ] || [ "$host" = "$secret" ]; then
        echo "❌ Битый токен"; return 1
    fi
    sub_enabled || { echo "Сначала настройте домен ноды."; return 1; }
    printf '%s' "$secret" > "$CLUSTER_SECRET_FILE"; chmod 600 "$CLUSTER_SECRET_FILE"
    setup_caddy "$(node_host)"          # перенастроить Caddy с новым секретом
    cluster_add_peer "$(node_name)" "$(node_host)"
    cluster_add_peer "seed" "$host"
    publish_peers_list
    publish_manifest
    cluster_sync
    echo "✅ Подключено к $host."
    echo "   На seed-ноде один раз добавьте этот сервер: Подписка → Добавить пир → $(node_host)"
}

# Метки разделов данных для подробного лога синхронизации. Порядок = порядок опроса.
CLUSTER_SYNC_SECTIONS="manifest subtokens roster state pwreset freeplan ips expiry settings userlimits subips abuse tgbind version"
_section_label() {
    case "$1" in
        manifest)   echo "ключи" ;;
        subtokens)  echo "токены подписки" ;;
        roster)     echo "реестр юзеров" ;;
        state)      echo "состояния (вкл/выкл/удал.)" ;;
        pwreset)    echo "сбросы ключей" ;;
        freeplan)   echo "бесплатный тариф (квоты)" ;;
        ips)        echo "IP-адреса" ;;
        expiry)     echo "сроки действия" ;;
        settings)   echo "настройки/лимиты" ;;
        userlimits) echo "устройства/жёсткая проверка" ;;
        subips)     echo "IP по ссылкам" ;;
        abuse)      echo "анти-абуз (балл/окно)" ;;
        tgbind)     echo "привязки Telegram" ;;
        version)    echo "версия менеджера" ;;
        *)          echo "$1" ;;
    esac
}

# Периодическая синхронизация: стянуть реестр (gossip) и манифесты пиров, затем
# пересобрать подписки. Недоступный пир пропускаем (отдаём остальные ключи).
# Первый аргумент «verbose» — подробный лог по каждой ноде и каждому действию,
# плюс жёсткая проверка: реальная доступность каждого пира и нашего HTTPS.
# Возвращает 0, если все пиры на связи (или их нет), иначе 1.
cluster_sync() {
    local V=""; [ "$1" = "verbose" ] && V=1
    _vp() { [ -n "$V" ] && printf '%s\n' "$*"; }
    sub_enabled || { _vp "  ⚪ Подписка/кластер не настроены — синхронизировать нечего."; return 0; }
    mkdir -p "$PEERS_DIR"

    _vp "  ── Синхронизация кластера ──────────────────────────────"
    _vp "  📤 Публикую наши данные (ключи, токены, лимиты, состояния, IP)..."
    publish_peers_list
    publish_manifest
    publish_subtokens
    publish_roster
    publish_cluster_state
    publish_cluster_pwreset
    declare -F publish_cluster_freeplan >/dev/null 2>&1 && publish_cluster_freeplan
    publish_cluster_expiry
    publish_cluster_settings
    publish_cluster_userlimits
    publish_cluster_abuse
    publish_ips
    publish_subips
    publish_cluster_tgbind
    publish_cluster_version

    # Жёсткая проверка НАШЕГО эндпоинта: без валидного HTTPS пиры физически не
    # смогут забрать наши данные — синхронизация будет односторонней.
    if [ -n "$V" ]; then
        printf '     Проверяю наш HTTPS-эндпоинт (%s)... ' "$(node_host)"
        if cluster_call "$(node_host)" "/cluster/userlimits" 6 >/dev/null 2>&1 || cert_ready "$(node_host)"; then
            echo "✅ данные доступны для пиров"
        else
            echo "❌ НЕ отдаётся!"
            _vp "     Пиры не смогут забрать наши изменения. Почините HTTPS (Диагностика → 8),"
            _vp "     иначе наши правки к ним не попадут."
        fi
    fi

    local host name data cnt total=0 okp=0 badp=0 s reason
    while IFS= read -r host; do
        [ -n "$host" ] || continue
        total=$((total + 1))
        name=$(awk -F'|' -v h="$host" '$2==h{print $1; exit}' "$CLUSTER_CONF" 2>/dev/null)
        [ -z "$name" ] && name=$(printf '%s' "$host" | tr -c 'a-zA-Z0-9_.-' '_')

        _vp ""
        _vp "  🔗 Нода «$name» ($host)"
        if [ -n "$V" ]; then printf '     Подключение... '; fi
        # Жёсткая проверка связи с пиром (DNS, затем TLS + секрет кластера).
        # Вердикт кладём на диск ВСЕГДА, не только в verbose: cron-прогон молчит,
        # и без этого недоступный пир ничем себя не выдавал.
        if ! reason=$(peer_probe "$host"); then
            [ -n "$V" ] && echo "❌ $reason"
            peer_health_set "$host" "$name" 0 "$reason"
            badp=$((badp + 1))
            continue
        fi
        peer_health_set "$host" "$name" 1 ""
        [ -n "$V" ] && echo "✅ подключено"

        # gossip реестра
        [ -n "$V" ] && printf '     ⬇ реестр пиров (gossip)... '
        data=$(cluster_call "$host" "/cluster/peers.list")
        if [ -n "$data" ]; then
            printf '%s\n' "$data" | while IFS='|' read -r pn ph; do
                [ -n "$ph" ] && cluster_add_peer "$pn" "$ph"
            done
            [ -n "$V" ] && echo "ок"
        else
            [ -n "$V" ] && echo "пусто"
        fi

        # Тянем все разделы данных пира в кэш, с отчётом по каждому.
        for s in $CLUSTER_SYNC_SECTIONS; do
            [ -n "$V" ] && printf '     ⬇ %s... ' "$(_section_label "$s")"
            data=$(cluster_call "$host" "/cluster/$s")
            if [ -n "$data" ]; then
                printf '%s\n' "$data" > "$PEERS_DIR/${name}.${s}"
                if [ -n "$V" ]; then cnt=$(printf '%s\n' "$data" | grep -c .); echo "получено (${cnt} зап.)"; fi
            else
                [ -n "$V" ] && echo "нет данных"
            fi
        done
        [ -n "$V" ] && echo "     ✅ данные ноды «$name» получены"
        okp=$((okp + 1))
    done < <(cluster_peers)

    _vp ""
    _vp "  🔧 Применяю изменения локально..."
    cluster_apply_state      # точка правды: вкл/выкл/удаление с других нод
    cluster_apply_pwreset    # сброс ключей, начатый на другой ноде
    declare -F cluster_apply_freeplan >/dev/null 2>&1 && cluster_apply_freeplan   # окна/расход бесплатного тарифа
    cluster_apply_roster     # завести у себя кластерных юзеров, которых нет
    cluster_apply_expiry     # подтянуть единый срок действия по кластеру
    cluster_apply_settings   # подтянуть общее оформление подписки
    cluster_apply_userlimits # подтянуть персональные лимиты устройств
    abuse_apply              # подтянуть состояние анти-абуза (балл/окно авто-HC)
    cluster_apply_tgbind     # слить привязки Telegram↔пользователь (LWW по tg_id)
    regen_subscriptions
    cluster_online_sync      # заодно обновим онлайн и применим лимит устройств
    write_authlimits         # обновить снимок для жёсткой проверки
    _vp "  ✅ Локально применено."

    if [ -n "$V" ]; then
        _vp ""
        if [ "$total" -eq 0 ]; then
            _vp "  ── Итог: пиров нет (одиночная нода). ──"
        else
            _vp "  ── Итог: пиров на связи $okp из $total$([ "$badp" -gt 0 ] && echo ", недоступны: $badp") ──"
            _vp "  ℹ️  Мы забрали данные с доступных пиров. НАШИ изменения появятся на"
            _vp "     каждом пире, когда он выполнит свою синхронизацию (авто ~1 мин по"
            _vp "     online-sync, полная ~5 мин, или по кнопке «Синхронизировать» у него)."
        fi
    fi
    [ "$badp" -gt 0 ] && return 1 || return 0
}

# ---- Кластерные пользователи (живут на ВСЕХ нодах) ----
# Подход pull: нода-владелец помечает юзера в roster и публикует его; остальные
# ноды на своём cluster_sync видят это и заводят юзера ЛОКАЛЬНО (свой пароль).
# Авто-заведённые в свой roster НЕ добавляются — источник истины один (владелец),
# чтобы удаление у владельца не приводило к бесконечному пересозданию.
roster_add()    { mkdir -p "$DATA_DIR"; touch "$CLUSTER_USERS_FILE"; grep -qxF "$1" "$CLUSTER_USERS_FILE" 2>/dev/null || echo "$1" >> "$CLUSTER_USERS_FILE"; }
roster_has()    { grep -qxF "$1" "$CLUSTER_USERS_FILE" 2>/dev/null; }
roster_remove() {
    [ -f "$CLUSTER_USERS_FILE" ] || return 0
    grep -vxF "$1" "$CLUSTER_USERS_FILE" > "${CLUSTER_USERS_FILE}.t" 2>/dev/null || true
    mv "${CLUSTER_USERS_FILE}.t" "$CLUSTER_USERS_FILE" 2>/dev/null || true
}

# ---- ТОЧКА ПРАВДЫ: жизненный цикл кластерного юзера (active/disabled/deleted) ----
# Нода, на которой произошло действие, бампает ts=now и публикует. Остальные на
# своём sync применяют у себя запись с наибольшим ts (last-write-wins). Так
# отключение/удаление/включение распространяются по кластеру, а deleted-tombstone
# не даёт манифесту/roster пира воскресить юзера обратно.
cstate_get()    { awk -F'|' -v u="$1" '$1==u{print $2; exit}' "$CLUSTER_STATE_FILE" 2>/dev/null; }
cstate_get_ts() { local t; t=$(awk -F'|' -v u="$1" '$1==u{print $3; exit}' "$CLUSTER_STATE_FILE" 2>/dev/null); [[ "$t" =~ ^[0-9]+$ ]] && echo "$t" || echo 0; }
cstate_set() {   # user state [ts]
    local u="$1" s="$2" ts="${3:-$(date +%s)}"
    mkdir -p "$DATA_DIR"; touch "$CLUSTER_STATE_FILE"
    sed -i "/^${u}|/d" "$CLUSTER_STATE_FILE" 2>/dev/null
    printf '%s|%s|%s\n' "$u" "$s" "$ts" >> "$CLUSTER_STATE_FILE"
}

# Зафиксировать новое состояние юзера ЛОКАЛЬНЫМ действием и тут же опубликовать.
# Только для кластерных юзеров — локальные (одна нода) не распространяем.
# Для delete вызывать ДО снятия метки (membership проверяется по roster).
cstate_mark() {   # user state
    sub_enabled || return 0
    is_cluster_user "$1" || return 0
    cstate_set "$1" "$2"
    publish_cluster_state
}

publish_cluster_state() {
    sub_enabled || return 0
    mkdir -p "$WEBROOT/cluster"; touch "$CLUSTER_STATE_FILE"
    cp -f "$CLUSTER_STATE_FILE" "$WEBROOT/cluster/state" 2>/dev/null || : > "$WEBROOT/cluster/state"
    chmod 640 "$WEBROOT/cluster/state" 2>/dev/null || true
    secure_web_files
}

# ---- СБРОС КЛЮЧЕЙ ПО КЛАСТЕРУ (ротация пароля на ВСЕХ нодах) ----
# Пароль одного и того же юзера на каждой ноде СВОЙ (см. cluster_apply_state:
# нода заводит юзера локально со своим pwgen), а подписка склеивает ключи всех
# нод. Значит локальный change_user_password гасит только «свою треть» утёкшего.
# Поэтому нода, где нажали «Сбросить ссылку», пишет «user|ts» и публикует, а
# остальные на своём sync видят ts новее применённого и крутят пароль у себя.
# LWW, как и cstate: применённый ts запоминаем — обратной волны не будет.
pwreset_get_ts() { local t; t=$(awk -F'|' -v u="$1" '$1==u{print $2; exit}' "$PWRESET_FILE" 2>/dev/null); [[ "$t" =~ ^[0-9]+$ ]] && echo "$t" || echo 0; }
pwreset_set() {   # user ts
    mkdir -p "$DATA_DIR"; touch "$PWRESET_FILE"
    sed -i "/^${1}|/d" "$PWRESET_FILE" 2>/dev/null
    printf '%s|%s\n' "$1" "$2" >> "$PWRESET_FILE"
}

# Объявить сброс: у нас пароль уже прокручен (reset_subscription), пиры узнают на sync.
pwreset_mark() {   # user
    sub_enabled || return 0
    pwreset_set "$1" "$(date +%s)"
    publish_cluster_pwreset
}

publish_cluster_pwreset() {
    sub_enabled || return 0
    mkdir -p "$WEBROOT/cluster"; touch "$PWRESET_FILE"
    cp -f "$PWRESET_FILE" "$WEBROOT/cluster/pwreset" 2>/dev/null || : > "$WEBROOT/cluster/pwreset"
    chmod 640 "$WEBROOT/cluster/pwreset" 2>/dev/null || true
    secure_web_files
}

cluster_apply_pwreset() {
    sub_enabled || return 0
    local merged u t changed=0
    merged=$(
        { [ -f "$PWRESET_FILE" ] && cat "$PWRESET_FILE"
          [ -d "$PEERS_DIR" ] && cat "$PEERS_DIR"/*.pwreset 2>/dev/null; } \
        | awk -F'|' 'NF>=2 && $1!="" { if (($2+0) > (ts[$1]+0)) ts[$1]=$2 }
                     END { for (u in ts) printf "%s|%s\n", u, ts[u] }'
    )
    [ -n "$merged" ] || return 0
    while IFS='|' read -r u t; do
        [[ "$u" =~ ^[a-zA-Z0-9_-]+$ ]] || continue
        [ "${t:-0}" -gt "$(pwreset_get_ts "$u")" ] 2>/dev/null || continue
        # Юзера у нас нет (ещё не завели/уже удалён) — только запоминаем ts,
        # иначе после появления юзера сброс сработал бы задним числом.
        if db_user_exists "$u" || is_user_disabled "$u"; then
            change_user_password "$u" >/dev/null 2>&1   # каскад по протоколам + кик + sub_refresh
            changed=1
        fi
        pwreset_set "$u" "$t"
    done <<< "$merged"
    [ "$changed" = 1 ] && publish_cluster_pwreset
    return 0
}

# --- Обмен версиями между нодами ---
# Каждая нода публикует свою версию менеджера; пиры тянут её в кэш (см.
# CLUSTER_SYNC_SECTIONS). Так на любой ноде видно, какая версия где стоит, и
# сразу понятно, кого пора обновлять. Формат — «ver|ts» (одна строка).
publish_cluster_version() {
    sub_enabled || return 0
    mkdir -p "$WEBROOT/cluster"
    printf '%s|%s\n' "${MANAGER_VERSION:-unknown}" "$(date +%s)" > "$WEBROOT/cluster/version" 2>/dev/null
    chmod 640 "$WEBROOT/cluster/version" 2>/dev/null || true
    secure_web_files
}

# Версия менеджера конкретного пира из кэша (пусто, если ещё не синкались).
peer_version() {   # peer-name
    [ -n "$1" ] || return 1
    cut -d'|' -f1 "$PEERS_DIR/${1}.version" 2>/dev/null | head -1
}

# Список «имя<TAB>host<TAB>версия» по всем нодам кластера (эта + пиры из кэша).
# Для экрана «версии нод». Версия пира пустая → «?» (ещё не синкнулись/старьё).
cluster_versions() {
    printf '%s\t%s\t%s\n' "$(node_name)" "$(node_host)" "${MANAGER_VERSION:-unknown}"
    local host name ver self; self=$(node_host)
    while IFS='|' read -r name host; do
        [ -n "$host" ] && [ "$host" != "$self" ] || continue
        [ -z "$name" ] && name="$host"
        ver=$(peer_version "$name"); [ -z "$ver" ] && ver="?"
        printf '%s\t%s\t%s\n' "$name" "$host" "$ver"
    done < "$CLUSTER_CONF" 2>/dev/null
}

# Тихое локальное удаление (без печати/сообщений) — для применения tombstone.
cluster_delete_local() {   # user
    local user="$1" _t
    if [ -f "$SUBTOKENS_DB" ]; then
        _t=$(awk -F: -v u="$user" '$1==u{print $2; exit}' "$SUBTOKENS_DB" 2>/dev/null)
        [ -n "$_t" ] && rm -f "$WEBROOT/sub/$_t" 2>/dev/null
        sub_token_remove "$user"
    fi
    db_remove_user "$user"
    sed -i "/^${user}|/d" "$DISABLED_FILE" "$STATS_FILE" "$IPS_FILE" "$EXPIRY_FILE" "$SPEED_FILE" "$USERLIMITS_FILE" "$USERLIMITS_TS_FILE" 2>/dev/null
    roster_remove "$user"
    declare -F remove_user_abuse >/dev/null && remove_user_abuse "$user"
    api_post "/kick" "[\"$user\"]" &>/dev/null
}

# Применяет состояния с других нод: для каждого юзера берём запись с наибольшим
# ts; если она новее локальной — применяем у себя (создать/включить, отключить,
# удалить) и фиксируем тот же ts (чтобы не зациклить). Лёгкие raw-операции (без
# per-user sub_refresh) — финальная пересборка делается один раз в конце.
cluster_apply_state() {
    sub_enabled || return 0
    local merged
    merged=$(
        { [ -f "$CLUSTER_STATE_FILE" ] && cat "$CLUSTER_STATE_FILE"
          [ -d "$PEERS_DIR" ] && cat "$PEERS_DIR"/*.state 2>/dev/null; } \
        | awk -F'|' 'NF>=3 && $1!="" { if (($3+0) > (ts[$1]+0)) { ts[$1]=$3; s[$1]=$2 } }
                     END { for (u in ts) printf "%s|%s|%s\n", u, s[u], ts[u] }'
    )
    [ -n "$merged" ] || return 0
    local u s t localts pw changed=0
    while IFS='|' read -r u s t; do
        [ -n "$u" ] || continue
        [[ "$u" =~ ^[a-zA-Z0-9_-]+$ ]] || continue
        localts=$(cstate_get_ts "$u")
        [ "${t:-0}" -gt "${localts:-0}" ] 2>/dev/null || continue
        case "$s" in
            active)
                if is_user_disabled "$u"; then
                    pw=$(get_disabled_password "$u")
                    [ -n "$pw" ] && db_add_user "$u" "$pw"
                    sed -i "/^${u}|/d" "$DISABLED_FILE" 2>/dev/null
                elif ! db_user_exists "$u"; then
                    db_add_user "$u" "$(pwgen -s 64 1)"
                fi
                roster_add "$u"          # это объявленный кластерный юзер
                ;;
            disabled)
                if db_user_exists "$u"; then
                    pw=$(get_user_password "$u")
                    grep -q "^${u}|" "$DISABLED_FILE" 2>/dev/null || echo "${u}|${pw}" >> "$DISABLED_FILE"
                    db_remove_user "$u"
                    api_post "/kick" "[\"$u\"]" &>/dev/null
                fi
                ;;
            deleted)
                cluster_delete_local "$u"
                ;;
        esac
        cstate_set "$u" "$s" "$t"
        changed=1
    done <<< "$merged"
    if [ "$changed" = 1 ]; then
        secure_auth_files
        sub_refresh
        publish_cluster_state
    fi
}

publish_roster() {
    sub_enabled || return 0
    mkdir -p "$WEBROOT/cluster"; touch "$CLUSTER_USERS_FILE"
    cp -f "$CLUSTER_USERS_FILE" "$WEBROOT/cluster/roster" 2>/dev/null || : > "$WEBROOT/cluster/roster"
    secure_web_files
}

# Заводит локально кластерных юзеров, объявленных пирами, которых тут ещё нет.
cluster_apply_roster() {
    sub_enabled || return 0
    local want u f created=0
    want=$(for f in "$PEERS_DIR"/*.roster; do [ -f "$f" ] && cat "$f"; done 2>/dev/null)
    want=$(printf '%s\n' "$want" | grep -v '^$' | sort -u)
    [ -n "$want" ] || return 0
    while IFS= read -r u; do
        [ -n "$u" ] || continue
        [[ "$u" =~ ^[a-zA-Z0-9_-]+$ ]] || continue
        # Точка правды важнее roster: удалённого/отключённого по кластеру НЕ
        # пересоздаём, даже если он ещё «висит» в roster-кэше пира.
        case "$(cstate_get "$u")" in deleted|disabled) continue ;; esac
        db_user_exists "$u" && continue
        is_user_disabled "$u" && continue
        db_add_user "$u" "$(pwgen -s 64 1)"
        created=1
    done <<< "$want"
    [ "$created" = 1 ] && sub_refresh
}

# Пометить юзера кластерным и разослать (peers заведут у себя на своём sync).
# nosync — только пометить и опубликовать, без обхода пиров: публикация
# локальная и мгновенная, а забирают её пиры всё равно сами (их cron, ~5 мин).
# Нужно там, где вызов делается в ответе клиенту (провижининг из API/бота) и
# лишние секунды похода по нодам он ждать не может.
cluster_share_user() {   # user [nosync]
    sub_enabled || return 0
    roster_add "$1"
    cstate_set "$1" active            # точка правды: юзер активен по кластеру
    publish_roster
    publish_cluster_state
    [ "${2:-}" = nosync ] && return 0
    cluster_sync
}

# ЕДИНАЯ точка синхронизации для всего менеджера. Любая кнопка «Получить
# синхронизацию (локально)» и любой авто-сайенк после правок идут ЧЕРЕЗ неё.
# Публикует наши данные, тянет данные со всех пиров, применяет локально — с
# подробным логом по каждой ноде (см. cluster_sync verbose). Возвращает код
# cluster_sync (0 — все пиры на связи/пиров нет, 1 — есть недоступные).
cluster_sync_now() {
    echo ""
    if ! sub_enabled; then
        echo "  ⚪ Подписка / Кластер не настроены (Настройки → 5 → пункт 1)."
        return 0
    fi
    cluster_sync verbose
}

# Предложить синхронизацию после изменения. Режим (node.conf SYNC_MODE):
#   ask  — спрашивать каждый раз (по умолчанию)
#   auto — синхронизировать сразу, без вопроса
#   cron — ничего не делать (разнесётся по расписанию)
# Во всех режимах, когда синхронизируем, зовём ЕДИНУЮ cluster_sync_now.
offer_sync() {
    sub_enabled || return 0
    [ -n "$(cluster_peers 2>/dev/null)" ] || return 0   # одиночная нода — нечего синхронизировать
    local mode; mode=$(node_get SYNC_MODE); [ -z "$mode" ] && mode=ask
    case "$mode" in
        auto)
            cluster_sync_now ;;
        cron) : ;;   # тихо, разнесётся по расписанию (каждые 5 мин)
        *)
            local a; ask a "  🌐 Синхронизировать со всеми нодами сейчас? (да/нет, по умолч. по расписанию): "
            if is_yes "$a"; then
                cluster_sync_now
            fi ;;
    esac
}

# ---- Синхронизация ОФОРМЛЕНИЯ подписки (общее для кластера) ----
# Название профиля, шаблон подписи, интервал обновления — одинаковые на всех
# нодах. Значения в base64 (могут содержать пробелы/спецсимволы), last-write-wins.

# Стягивает ТОЛЬКО раздел общих настроек с каждого пира в кэш (лёгкий аналог
# полной синхронизации). Нужен ПЕРЕД ручной правкой общей настройки: тогда
# _setting_max_seen_ts видит актуальный максимум ts по всему кластеру, и ts
# правки (max+1) гарантированно его превысит — LWW не откатит её устаревшим,
# но большим по ts значением пира (частая причина «шаблон не сохраняется» при
# расхождении часов между нодами).
cluster_pull_settings() {
    sub_enabled || return 0
    mkdir -p "$PEERS_DIR"
    local host name data
    while IFS= read -r host; do
        [ -n "$host" ] || continue
        name=$(awk -F'|' -v h="$host" '$2==h{print $1; exit}' "$CLUSTER_CONF" 2>/dev/null)
        [ -z "$name" ] && name=$(printf '%s' "$host" | tr -c 'a-zA-Z0-9_.-' '_')
        data=$(cluster_call "$host" "/cluster/settings" 5)
        [ -n "$data" ] && printf '%s\n' "$data" > "$PEERS_DIR/${name}.settings"
    done < <(cluster_peers)
}

publish_cluster_settings() {
    sub_enabled || return 0
    mkdir -p "$WEBROOT/cluster"
    local tmp="$WEBROOT/cluster/settings.tmp.$BASHPID" k v ts
    : > "$tmp"
    for k in $SETTING_KEYS; do
        v=$(node_get "$k"); ts=$(setting_ts "$k")
        printf '%s|%s|%s\n' "$k" "$(printf '%s' "$v" | base64 -w0)" "$ts" >> "$tmp"
    done
    mv "$tmp" "$WEBROOT/cluster/settings"
    secure_web_files
}

cluster_apply_settings() {
    sub_enabled || return 0
    local merged
    merged=$(
        { [ -f "$WEBROOT/cluster/settings" ] && cat "$WEBROOT/cluster/settings"
          [ -d "$PEERS_DIR" ] && cat "$PEERS_DIR"/*.settings 2>/dev/null; } \
        | awk -F'|' 'NF>=3 && $1!="" { if (($3+0) > (ts[$1]+0)) { ts[$1]=$3; v[$1]=$2 } }
                     END { for (k in ts) printf "%s|%s|%s\n", k, v[k], ts[k] }'
    )
    [ -n "$merged" ] || return 0
    local k b t localts changed=0
    while IFS='|' read -r k b t; do
        [ -n "$k" ] || continue
        localts=$(setting_ts "$k")
        [ "${t:-0}" -gt "${localts:-0}" ] 2>/dev/null || continue
        setting_set "$k" "$(printf '%s' "$b" | base64 -d 2>/dev/null)" "$t"
        changed=1
    done <<< "$merged"
    if [ "$changed" = 1 ]; then
        setup_caddy >/dev/null 2>&1   # обновить заголовки (title/interval)
        sub_refresh                   # обновить подписи ключей (template)
        publish_cluster_settings
    fi
}

# ---- Синхронизация СРОКА ДЕЙСТВИЯ кластерных юзеров ----
# Все «кластерные» юзеры (объявлены в roster локально или у пиров).
cluster_users_all() {
    { [ -f "$CLUSTER_USERS_FILE" ] && cat "$CLUSTER_USERS_FILE"
      [ -d "$PEERS_DIR" ] && cat "$PEERS_DIR"/*.roster 2>/dev/null; } \
      | grep -v '^$' | sort -u
}
is_cluster_user() { cluster_users_all | grep -qxF "$1" 2>/dev/null; }

# Публикует сроки кластерных юзеров: «user|date|ts». Разделитель «|» (не пробел),
# иначе пустая дата (срок снят) схлопывалась бы при разборе через IFS-таб.
publish_cluster_expiry() {
    sub_enabled || return 0
    mkdir -p "$WEBROOT/cluster"
    local tmp="$WEBROOT/cluster/expiry.tmp.$BASHPID" u d t
    : > "$tmp"
    while IFS= read -r u; do
        [ -n "$u" ] || continue
        d=$(get_user_expiry "$u"); t=$(expiry_get_ts "$u")
        printf '%s|%s|%s\n' "$u" "$d" "$t" >> "$tmp"
    done < <(cluster_users_all)
    mv "$tmp" "$WEBROOT/cluster/expiry"
    secure_web_files
}

# Применяет сроки с других нод: для каждого юзера берём запись с наибольшим ts;
# если она новее локальной — применяем (с тем же ts, чтобы не зациклить).
# Так изменение срока на любой ноде влияет на всю подписку (последнее изменение
# выигрывает).
cluster_apply_expiry() {
    sub_enabled || return 0
    local merged
    merged=$(
        { [ -f "$WEBROOT/cluster/expiry" ] && cat "$WEBROOT/cluster/expiry"
          [ -d "$PEERS_DIR" ] && cat "$PEERS_DIR"/*.expiry 2>/dev/null; } \
        | awk -F'|' 'NF>=3 && $1!="" { if (($3+0) >= (ts[$1]+0)) { ts[$1]=$3; d[$1]=$2 } }
                      END { for (u in ts) printf "%s|%s|%s\n", u, d[u], ts[u] }'
    )
    [ -n "$merged" ] || return 0
    local u d t localts changed=0
    while IFS='|' read -r u d t; do
        [ -n "$u" ] || continue
        localts=$(expiry_get_ts "$u")
        [ "${t:-0}" -gt "${localts:-0}" ] 2>/dev/null || continue
        if [ -n "$d" ]; then set_user_expiry "$u" "$d" "$t"; else remove_user_expiry "$u" "$t"; fi
        changed=1
    done <<< "$merged"
    if [ "$changed" = 1 ]; then
        check_expired_users >/dev/null 2>&1
        publish_cluster_expiry
    fi
}

# ---- Синхронизация ПЕРСОНАЛЬНЫХ ЛИМИТОВ (устройства, жёсткая проверка, тариф) ----
# Публикует «user|devices|hardcheck|ts|rate» ТОЛЬКО для КЛАСТЕРНЫХ юзеров (roster
# наш или пира). Лимиты локального профиля — дело только этой ноды: раньше
# публиковались все локальные (get_all_users), и правка скорости локального юзера
# уезжала на весь кластер, хотя кластерным его никто не делал.
# Публикуем ТОЛЬКО юзеров с явно заданной записью лимита (есть в USERLIMITS_FILE),
# чтобы дефолтная «1» с нулевым ts не затирала осмысленные значения на пирах.
publish_cluster_userlimits() {
    sub_enabled || return 0
    mkdir -p "$WEBROOT/cluster"
    local tmp="$WEBROOT/cluster/userlimits.tmp.$BASHPID" u d h t r
    : > "$tmp"
    while IFS= read -r u; do
        [ -n "$u" ] || continue
        t=$(userlimits_get_ts "$u")
        [ "${t:-0}" -gt 0 ] 2>/dev/null || continue   # нет явной записи — не публикуем
        d=$(get_user_devices "$u"); h=$(get_user_hardcheck "$u"); r=$(get_user_rate "$u")
        # rate — поле 5 (ts остаётся полем 4 ради обратной совместимости старых нод).
        printf '%s|%s|%s|%s|%s\n' "$u" "$d" "$h" "$t" "$r" >> "$tmp"
    done < <(cluster_users_all)
    mv "$tmp" "$WEBROOT/cluster/userlimits"
    chmod 640 "$WEBROOT/cluster/userlimits" 2>/dev/null || true
    secure_web_files
}

# Применяет лимиты с других нод: для каждого юзера берём запись с наибольшим ts;
# если новее локальной — применяем у себя (с тем же ts, чтобы не зациклить).
# Изменение лимита на любой ноде влияет на всю подписку (последнее выигрывает).
# Записи о юзере, которого у нас НЕТ, пропускаем: иначе в userlimits.dat оседали
# призраки (юзера нет, лимит есть), мы их публиковали дальше — и запись
# становилась бессмертной: remove_user_limits обнуляет локальный ts, а копия с
# пира (ts>0) возвращала её на следующем sync, в т.ч. на новый одноимённый профиль.
cluster_apply_userlimits() {
    sub_enabled || return 0
    local merged
    merged=$(
        { [ -f "$WEBROOT/cluster/userlimits" ] && cat "$WEBROOT/cluster/userlimits"
          [ -d "$PEERS_DIR" ] && cat "$PEERS_DIR"/*.userlimits 2>/dev/null; } \
        | awk -F'|' 'NF>=4 && $1!="" { if (($4+0) > (ts[$1]+0)) { ts[$1]=$4; d[$1]=$2; h[$1]=$3; r[$1]=($5==""?0:$5) } }
                     END { for (u in ts) printf "%s|%s|%s|%s|%s\n", u, d[u], h[u], ts[u], r[u] }'
    )
    [ -n "$merged" ] || return 0
    local u d h t r localts changed=0
    while IFS='|' read -r u d h t r; do
        [ -n "$u" ] || continue
        [[ "$u" =~ ^[a-zA-Z0-9_-]+$ ]] || continue
        db_user_exists "$u" || is_user_disabled "$u" || continue   # юзера тут нет — не наше дело
        localts=$(userlimits_get_ts "$u")
        [ "${t:-0}" -gt "${localts:-0}" ] 2>/dev/null || continue
        set_user_limits "$u" "$d" "$h" "$t" "$r"
        changed=1
    done <<< "$merged"
    if [ "$changed" = 1 ]; then
        write_authlimits
        publish_cluster_userlimits
        # Тариф из подписки мог принести новую скорость — пересобрать kernel-лимит,
        # чтобы под неё существовал HTB-класс, а klimit_reconcile разложил пер-IP
        # правила (без этого пришедший тариф игнорируется на ноде-приёмнике).
        declare -F klimit_apply >/dev/null 2>&1 && klimit_apply "$(klimit_down)" "$(klimit_up)" >/dev/null 2>&1 || true
    fi
}

# ---- Синхронизация ПРИВЯЗОК Telegram ↔ пользователь ----
# Строка «tg_id|username|ts» (tombstone отвязки — «tg_id||ts», см. tg_unbind).
# Ключ слияния — tg_id: один Telegram-аккаунт привязан ровно к одному юзеру,
# и правки на разных нодах разрешаются last-write-wins по ts. Так админ может
# привязать/перепривязать/отвязать аккаунт на ЛЮБОЙ ноде, а веб-апп на любой
# ноде отдаст профиль по by-telegram (файл tgusers.dat ведёт lib/tgbot.sh).
publish_cluster_tgbind() {
    sub_enabled || return 0
    [ -n "$TGUSERS_FILE" ] || return 0
    mkdir -p "$WEBROOT/cluster"
    cp -f "$TGUSERS_FILE" "$WEBROOT/cluster/tgbind" 2>/dev/null || : > "$WEBROOT/cluster/tgbind"
    chmod 640 "$WEBROOT/cluster/tgbind" 2>/dev/null || true
    secure_web_files
}

# Сливает привязки со всех нод: по каждому tg_id берём запись с наибольшим ts
# (при равном ts — детерминированно бо́льшую строку username, чтобы ноды не
# «моргали»). Результат = полный авторитетный набор для tgusers.dat, включая
# tombstone'ы. Переписываем файл только при реальном изменении (иначе — лишний
# republish в цикле). Записи привязки к несуществующему у нас юзеру безвредны:
# они лишь дают by-telegram → username, а сам профиль всё равно берётся из БД.
cluster_apply_tgbind() {
    sub_enabled || return 0
    [ -n "$TGUSERS_FILE" ] || return 0
    local merged
    merged=$(
        { [ -f "$TGUSERS_FILE" ] && cat "$TGUSERS_FILE"
          [ -d "$PEERS_DIR" ] && cat "$PEERS_DIR"/*.tgbind 2>/dev/null; } \
        | awk -F'|' 'NF>=3 && $1!="" {
                if (($3+0) > (ts[$1]+0) || (($3+0)==(ts[$1]+0) && $2 > u[$1])) { ts[$1]=$3; u[$1]=$2 }
            }
            END { for (id in ts) printf "%s|%s|%s\n", id, u[id], ts[id] }'
    )
    [ -n "$merged" ] || return 0
    # Сравниваем отсортированные версии — порядок строк не важен, важен состав.
    local cur new
    cur=$( [ -f "$TGUSERS_FILE" ] && sort "$TGUSERS_FILE" 2>/dev/null )
    new=$( printf '%s\n' "$merged" | sort )
    if [ "$cur" != "$new" ]; then
        touch "$TGUSERS_FILE"; chmod 600 "$TGUSERS_FILE" 2>/dev/null
        printf '%s\n' "$merged" > "$TGUSERS_FILE"
        publish_cluster_tgbind
    fi
}

# Обмен ТОЛЬКО скоростью (спидометр мини-аппа): публикуем свою и стягиваем
# чужую. Отдельно от cluster_online_sync, потому что каденс чаще (~15 с: тик 5 с,
# но вызывается каждый RATES_SYNC_EVERY-й — см. --rates-tick), а тянуть ради
# спидометра остальные шесть файлов пира незачем.
# Пиры опрашиваются параллельно: две последовательные HTTPS-ходки съели бы
# заметную часть 15-секундного окна. Недоступный пир -> пустой файл (= 0), а не
# залипшая старая скорость.
cluster_rates_sync() {
    sub_enabled || return 0
    mkdir -p "$PEERS_DIR"
    publish_rates
    local host name
    while IFS= read -r host; do
        [ -n "$host" ] || continue
        name=$(awk -F'|' -v h="$host" '$2==h{print $1; exit}' "$CLUSTER_CONF" 2>/dev/null)
        [ -z "$name" ] && name=$(printf '%s' "$host" | tr -c 'a-zA-Z0-9_.-' '_')
        { cluster_call "$host" "/cluster/rates" 5 > "$PEERS_DIR/${name}.rates.tmp.$BASHPID" 2>/dev/null
          mv "$PEERS_DIR/${name}.rates.tmp.$BASHPID" "$PEERS_DIR/${name}.rates" 2>/dev/null; } &
    done < <(cluster_peers)
    wait
}

# Частая синхронизация СТАТИСТИКИ (онлайн/трафик/скорость по кластеру + лимит
# устройств). Публикует свою статистику, стягивает статистику пиров, применяет
# лимит. Лёгкая — гоняется по cron чаще (раз в минуту), чем полная cluster_sync.
cluster_online_sync() {
    sub_enabled || return 0
    mkdir -p "$PEERS_DIR"
    collect_activity        # свежий active/active_since (трафик за последнюю минуту)
    publish_stats
    # Публикуем лимиты и состояние анти-абуза и здесь (раз в минуту), чтобы жёсткая
    # проверка, кол-во устройств и окно авто-жёсткой проверки разъезжались по
    # кластеру быстро, а не только по 5-минутной cluster_sync.
    publish_cluster_userlimits
    publish_cluster_abuse

    # Если в подписи используется {online} — стягиваем и манифесты пиров (раз в
    # минуту), чтобы онлайн ЧУЖИХ нод в нашей подписке был свежим, а не раз в
    # 5 минут (как в полной cluster_sync). Каждый пир печёт свой онлайн в свой
    # манифест, мы лишь подставляем их ключи в общую подписку.
    local need_online=""; _tag_needs_online && need_online=1

    local host name data
    while IFS= read -r host; do
        [ -n "$host" ] || continue
        name=$(awk -F'|' -v h="$host" '$2==h{print $1; exit}' "$CLUSTER_CONF" 2>/dev/null)
        [ -z "$name" ] && name=$(printf '%s' "$host" | tr -c 'a-zA-Z0-9_.-' '_')
        # Свежая статистика пира; недоступен -> пусто (= 0), не залипаем на старом.
        data=$(cluster_call "$host" "/cluster/stats")
        printf '%s' "$data" > "$PEERS_DIR/${name}.stats"
        # Персональные лимиты пира -> кэш (быстрое распространение жёсткой проверки).
        data=$(cluster_call "$host" "/cluster/userlimits")
        [ -n "$data" ] && printf '%s\n' "$data" > "$PEERS_DIR/${name}.userlimits"
        # Состояние анти-абуза пира -> кэш (быстрое распространение окна авто-жёсткой
        # проверки и балла шаринга).
        data=$(cluster_call "$host" "/cluster/abuse")
        [ -n "$data" ] && printf '%s\n' "$data" > "$PEERS_DIR/${name}.abuse"
        # Свежий манифест пира (в нём испечён онлайн той ноды). Недоступного пира
        # НЕ трогаем — оставляем прошлый манифест, чтобы не терять его ключи.
        if [ -n "$need_online" ]; then
            data=$(cluster_call "$host" "/cluster/manifest")
            [ -n "$data" ] && printf '%s\n' "$data" > "$PEERS_DIR/${name}.manifest"
        fi
    done < <(cluster_peers)

    cluster_apply_userlimits   # применить лимиты, пришедшие с пиров
    abuse_apply                # слить состояние анти-абуза с пирами (окно авто-HC)
    enforce_device_limits      # внутри: refresh_online + traffic-based жёсткая проверка
    abuse_observe              # наблюдение минуты: одновременная активность по нодам
    # Если в подписи используется {online} — держим счётчик свежим (раз в минуту):
    # перегенерируем свой манифест (для пиров) и локальные файлы подписки (в них
    # попадут свежие манифесты пиров, стянутые выше).
    if [ -n "$need_online" ]; then
        publish_manifest
        regen_subscriptions
    fi
}
