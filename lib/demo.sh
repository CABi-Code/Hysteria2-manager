#!/bin/bash
# ================================================
# Демо-профили: рабочий доступ в один тап, до регистрации и оплаты (idea 13 веб-аппа).
#
# Демо — это обычный пользователь Hysteria/Xray, но жёстко закапанный сразу по
# трём осям: скорость, трафик и время жизни. Экономика фарма ломается сама:
# нафармить месяц доступа дороже, чем его купить, — это и есть основная защита,
# фингерпринт в браузере лишь отсекает ленивых (см. веб-апп).
#
# ОДИН ПРОФИЛЬ ЖИВЁТ НА ОДНОЙ НОДЕ. В roster кластера демо не попадает и по нодам
# не публикуется: размазывать мусорную нагрузку на все локации сразу незачем.
# Но сама нода-приёмник больше не одна: demo_pick_node выбирает её на каждое
# нажатие «получить демо» (см. ниже). Выбрана чужая — профиль заводит ЕЁ менеджер
# у себя, а у нас остаётся строка-указатель с полем node: весь учёт (трафик, TTL,
# отбор доступа) остаётся там, где лежит профиль, — кросс-нодового учёта нет.
#
# DEMOS_DB: «user|state|created|expires|cap|base|used|node»
#   state   active — доступ работает; expired — доступ уже отобран, строка ещё
#           сутки лежит для статистики, потом её убирает та же прогонка;
#   cap     лимит трафика в байтах (0 — без лимита);
#   base    общий трафик юзера на момент выдачи (расход = текущий минус base);
#   used    израсходовано на момент отбора доступа (для статистики);
#   node    host ноды-приёмника; ПУСТО = эта нода (так выглядят все строки,
#           выданные до появления выбора ноды).
# ================================================

# Параметры демо. Подобраны так, чтобы проба ощущалась рабочей (сайты, мессенджеры,
# видео в SD), но фарм был бессмысленным: месяц доступа = сотни ротаций браузера.
DEMO_RATE_MBPS="${DEMO_RATE_MBPS:-5}"
DEMO_CAP_BYTES="${DEMO_CAP_BYTES:-$((500 * 1024 * 1024))}"
DEMO_TTL_MIN="${DEMO_TTL_MIN:-60}"
DEMO_KEEP_SEC="${DEMO_KEEP_SEC:-86400}"     # сколько держать строку после отбора
DEMO_REMOTE_TIMEOUT="${DEMO_REMOTE_TIMEOUT:-15}"   # ждём ноду-приёмник, сек

# Сколько демо разрешено держать живыми одновременно. Это ЕДИНСТВЕННЫЙ барьер,
# который фармер не обходит ничем со своей стороны: все остальные (секрет
# устройства, отпечаток, счётчик по IP+UA) стоят на данных, которые присылает он
# сам, а капча по IP снимается прокси-пулом. Потолок считается по этой ноде и
# держит фарм в известных рамках: TTL час, значит это же число — потолок выдач
# в час. Упёрлись — гость получает отказ, а не бесконечную очередь профилей.
DEMO_MAX_ACTIVE="${DEMO_MAX_ACTIVE:-50}"

demo_enabled() { sub_enabled; }   # без подписки отдавать гостю нечего

demo_row()   { awk -F'|' -v u="$1" '$1==u{print; exit}' "$DEMOS_DB" 2>/dev/null; }
demo_field() { demo_row "$1" | cut -d'|' -f"$2"; }
demo_is()    { [ -n "$(demo_row "$1")" ]; }
# Нода профиля: пустое поле в строке = эта нода (строки до появления выбора).
demo_node()  { local n; n=$(demo_field "$1" 8); printf '%s' "${n:-$(node_host)}"; }

demo_set() {   # user state created expires cap base used [node]
    mkdir -p "$DATA_DIR"; touch "$DEMOS_DB"
    sed -i "/^${1}|/d" "$DEMOS_DB" 2>/dev/null
    printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "${8:-}" >> "$DEMOS_DB"
    chmod 600 "$DEMOS_DB" 2>/dev/null
}

demo_remove() { sed -i "/^${1}|/d" "$DEMOS_DB" 2>/dev/null; }

# Сколько демо сейчас раздано (для лимита/статистики).
demo_active_count() { awk -F'|' '$2=="active"' "$DEMOS_DB" 2>/dev/null | grep -c .; }

# Потолок выбран. Считаем по строкам active: выдохшиеся demo_tick переводит в
# expired раз в минуту, так что место освобождается само.
demo_at_capacity() {
    [ "${DEMO_MAX_ACTIVE:-0}" -gt 0 ] || return 1
    [ "$(demo_active_count)" -ge "$DEMO_MAX_ACTIVE" ]
}

# ---- Выбор ноды-приёмника -------------------------------------------------
# Кандидаты — DEMO_NODES из node.conf: «host,host». Пусто = только эта нода, то
# есть до заполнения списка всё работает ровно как раньше. Настройка НАМЕРЕННО
# локальная и не входит в SETTING_KEYS: её выставляет та нода, что обслуживает
# кнопку «получить демо», остальным нодам она не нужна и LWW-перезапись чужой
# рукой здесь только навредила бы.
demo_node_list() { node_get DEMO_NODES 2>/dev/null | tr ',; ' '\n' | grep -v '^$'; }

# Пир годится, если последняя синхронизация признала его живым и вердикт свежий
# (см. peer_health_set). Отдельного опроса не делаем: гость ждёт ответа, а
# probe по мёртвой ноде — это секунды таймаутов на ровном месте.
_demo_peer_ok() {   # host
    local ok ts row
    row=$(awk -F'|' -v h="$1" '$1==h{print $3"|"$4; exit}' "$PEERS_HEALTH_FILE" 2>/dev/null)
    [ -n "$row" ] || return 1
    ok=${row%%|*}; ts=${row##*|}
    [ "$ok" = "1" ] || return 1
    [[ "$ts" =~ ^[0-9]+$ ]] || return 1
    [ $(( $(date +%s) - ts )) -lt "${PEER_STALE_SEC:-900}" ]
}

# Куда отдать следующее демо. Печатает host ноды-приёмника (всегда непустой).
# ponytail: равновероятный случайный выбор — по загрузке и географии выбирать
# нечем, пока нет паспорта ноды (docs/design/PLACEMENT, фаза 0). Появится —
# меняется ровно эта функция, всё остальное про ноду уже знает.
demo_pick_node() {
    local self host cand=()
    self=$(node_host)
    while IFS= read -r host; do
        [ -n "$host" ] || continue
        if [ "$host" = "$self" ]; then cand+=("$host")
        else _demo_peer_ok "$host" && cand+=("$host"); fi
    done < <(demo_node_list)
    # Список пуст или все кандидаты недоступны — выдаём у себя. Fail-open: гость
    # не должен остаться без пробы из-за чужой ноды (то же правило, что в PLACEMENT).
    [ ${#cand[@]} -gt 0 ] || { printf '%s' "$self"; return 0; }
    printf '%s' "${cand[RANDOM % ${#cand[@]}]}"
}

# Выдать демо-профиль: выбрать ноду и завести профиль там.
# Печатает key=value: user, sub_url, expires, cap, rate, node.
demo_create() {
    demo_enabled || return 1
    demo_at_capacity && return 2
    local node; node=$(demo_pick_node)
    if [ -n "$node" ] && [ "$node" != "$(node_host)" ]; then
        demo_create_remote "$node" && return 0
        # Нода-приёмник не ответила или ответила мусором — гость ждать второй
        # раз не станет: выдаём у себя, отказ дороже неидеальной локации.
    fi
    demo_create_local
}

# Демо на ЭТОЙ ноде.
demo_create_local() {
    demo_enabled || return 1
    local user pass now expires

    # Имя вида demo-xxxxxxxx: по префиксу демо видно в любом списке юзеров.
    for _ in 1 2 3; do
        user="demo-$(pwgen -s 8 1 2>/dev/null | tr 'A-Z' 'a-z')"
        [[ "$user" =~ ^demo-[a-z0-9]{8}$ ]] || user="demo-$(head -c 16 /dev/urandom | base64 | tr -dc 'a-z0-9' | head -c 8)"
        db_user_exists "$user" || break
    done
    db_user_exists "$user" && return 1

    pass=$(bot_gen_pass)
    [ -n "$pass" ] || return 1
    db_add_user "$user" "$pass" || return 1
    db_user_exists "$user" || return 1

    now=$(date +%s); expires=$(( now + DEMO_TTL_MIN * 60 ))

    # Гость ждёт ответа, поэтому всё тяжёлое здесь либо выкинуто, либо сделано
    # ровно один раз. Общекластерный write_authlimits (снимок для жёсткой
    # проверки) не зовём: его и так перестраивает --online-sync раз в минуту, а
    # у демо всё равно дефолтное одно устройство.
    local had_rate
    had_rate=$(_all_rates "$(klimit_tiers)" 2>/dev/null | tr ' ' '\n' | grep -cx "$DEMO_RATE_MBPS")
    set_user_limits "$user" 1 0 "" "$DEMO_RATE_MBPS" >/dev/null 2>&1
    # HTB-класс под демо-скорость создаём только когда его ещё нет: без класса
    # klimit_reconcile проигнорирует тариф, а с ним — разложит сам, за минуту.
    if [ "${had_rate:-0}" -eq 0 ]; then
        klimit_apply "$(klimit_down)" "$(klimit_up)" >/dev/null 2>&1 || true
    fi

    demo_write_sub "$user" "$pass"

    demo_set "$user" active "$now" "$expires" "$DEMO_CAP_BYTES" "$(demo_user_bytes "$user")" 0

    printf 'user=%s\n' "$user"
    printf 'sub_url=%s\n' "$(subscription_url "$user")"
    printf 'expires=%s\n' "$expires"
    printf 'cap=%s\n' "$DEMO_CAP_BYTES"
    printf 'rate=%s\n' "$DEMO_RATE_MBPS"
    printf 'node=%s\n' "$(node_host)"
}

# Демо на ДРУГОЙ ноде: просим её менеджер выдать профиль у себя (POST /v1/demo
# её же Web API; авторизация — общий секрет кластера, отдельных ключей раздавать
# по нодам не нужно). Гость получает ссылку той ноды, лимиты считает она сама.
# Локально пишем строку-указатель: по ней /v1/demo/{name} знает, у кого
# спрашивать состояние, и она же держит окно статистики.
demo_create_remote() {   # host -> key=value как demo_create_local
    local host="$1" json out user sub expires cap rate now
    command -v python3 >/dev/null 2>&1 || return 1
    json=$(curl -fsS --max-time "$DEMO_REMOTE_TIMEOUT" -X POST \
        -H "X-Cluster-Auth: $(cluster_secret)" -H 'Content-Type: application/json' \
        -d '{}' "https://${host}/api/v1/demo" 2>/dev/null) || return 1

    out=$(printf '%s' "$json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    sys.exit(1)
if not d.get("ok"):
    sys.exit(1)
d = d.get("data") or {}
for k, v in (("user", "username"), ("sub_url", "subscription_url"),
             ("expires", "expires_at"), ("cap", "cap_bytes"), ("rate", "rate_mbps")):
    print("%s=%s" % (k, d.get(v) if d.get(v) is not None else ""))
') || return 1

    user=$(printf '%s' "$out" | sed -n 's/^user=//p')
    sub=$(printf '%s'  "$out" | sed -n 's/^sub_url=//p')
    expires=$(printf '%s' "$out" | sed -n 's/^expires=//p')
    cap=$(printf '%s'  "$out" | sed -n 's/^cap=//p')
    rate=$(printf '%s' "$out" | sed -n 's/^rate=//p')

    # Ответ пришёл с другой машины — проверяем как чужой ввод. Ссылка обязана
    # вести на ту самую ноду: иначе гостя уводят в неизвестное место.
    [[ "$user" =~ ^demo-[a-z0-9]{4,32}$ ]] || return 1
    case "$sub" in "https://${host}/"*) ;; *) return 1 ;; esac
    [[ "$expires" =~ ^[0-9]+$ ]] || return 1
    [[ "$cap" =~ ^[0-9]+$ ]] || cap=0
    [[ "$rate" =~ ^[0-9]+$ ]] || rate=0
    demo_is "$user" && return 1        # имя уже занято нашей строкой — не затираем

    now=$(date +%s)
    demo_set "$user" active "$now" "$expires" "$cap" 0 0 "$host"

    printf 'user=%s\n' "$user"
    printf 'sub_url=%s\n' "$sub"
    printf 'expires=%s\n' "$expires"
    printf 'cap=%s\n' "$cap"
    printf 'rate=%s\n' "$rate"
    printf 'node=%s\n' "$host"
}

# Файл подписки ровно для этого демо. Полный regen_subscriptions перебирает всех
# юзеров кластера (секунды), а sub_refresh вдобавок дёргает Xray/sing-box и
# публикацию по кластеру — для локального одноразового профиля это лишнее.
demo_write_sub() {   # user pass
    local user="$1" pass="$2" token
    token=$(sub_token_for "$user") || return 1
    mkdir -p "$WEBROOT/sub"
    build_user_link "$user" "$pass" "" "" "" "" "$(render_tag "$user")" \
        | grep '^hysteria2://' | base64 -w0 > "$WEBROOT/sub/$token"
    secure_web_files 2>/dev/null || true
}

# Трафик демо-юзера. Демо локальное, но считаем той же функцией, что и квоты
# бесплатного тарифа: она уже умеет «собранное + ещё не собранный кумулятив».
demo_user_bytes() {
    if declare -F freeplan_user_bytes >/dev/null 2>&1; then
        freeplan_user_bytes "$1"
    else
        local tl; tl=$(get_user_traffic "$1")
        printf '%s' $(( $(printf '%s' "$tl" | cut -d'|' -f2) + $(printf '%s' "$tl" | cut -d'|' -f3) ))
    fi
}

# Прогон раз в минуту (--online-sync): отобрать доступ у выдохшихся демо и
# подчистить старые строки. TTL меряем в минутах, поэтому суточной прогонки
# expiry-по-датам (check_expired_users) здесь мало.
demo_tick() {
    [ -s "$DEMOS_DB" ] || return 0
    local now self user state created expires cap base used node bytes spent
    now=$(date +%s); self=$(node_host)

    while IFS='|' read -r user state created expires cap base used node; do
        [ -n "$user" ] || continue
        [[ "$user" =~ ^[a-zA-Z0-9_-]+$ ]] || continue

        # Профиль на другой ноде — доступ отбирает она, у неё же и трафик. Наша
        # строка только указатель: помечаем истёкшей по времени (чтобы UI и
        # /v1/demo не показывали живым то, чего уже нет) и вычищаем в свой срок.
        if [ -n "$node" ] && [ "$node" != "$self" ]; then
            if [ "$state" = "active" ] && [ "$now" -ge "${expires:-0}" ] 2>/dev/null; then
                demo_set "$user" expired "$created" "$expires" "$cap" "$base" "$used" "$node"
            elif [ "$state" != "active" ] && [ $(( now - ${expires:-0} )) -ge "$DEMO_KEEP_SEC" ] 2>/dev/null; then
                demo_remove "$user"
            fi
            continue
        fi

        if [ "$state" = "active" ]; then
            bytes=$(demo_user_bytes "$user")
            spent=$(( bytes - ${base:-0} )); [ "$spent" -lt 0 ] && spent=0
            if [ "$now" -ge "${expires:-0}" ] 2>/dev/null || \
               { [ "${cap:-0}" -gt 0 ] && [ "$spent" -ge "$cap" ]; }; then
                # Доступ отбираем целиком: демо не продлевают и не включают обратно.
                cluster_delete_local "$user" >/dev/null 2>&1
                demo_set "$user" expired "$created" "$expires" "$cap" "$base" "$spent"
            fi
        elif [ $(( now - ${expires:-0} )) -ge "$DEMO_KEEP_SEC" ] 2>/dev/null; then
            demo_remove "$user"
        fi
    done < "$DEMOS_DB"
}
