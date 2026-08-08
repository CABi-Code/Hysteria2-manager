#!/bin/bash
# ================================================
# Настройки ноды: домен, имя, IP, метка, шаблоны заголовков, релей.
# Хранилище — node.conf; изменения расходятся по кластеру через setting_set (LWW).
# ================================================


# Подписка включена, только если настроен домен ноды (node.conf с NODE_HOST).
sub_enabled() {
    [ -f "$NODE_CONF" ] && grep -q '^NODE_HOST=.' "$NODE_CONF" 2>/dev/null
}

# Значение поля из node.conf (NODE_NAME / NODE_HOST / WEBROOT).
node_get() { conf_get "$NODE_CONF" "$1"; }
node_host() { node_get NODE_HOST; }
node_name() { local n; n=$(node_get NODE_NAME); echo "${n:-node}"; }

# Все локальные «белые» IPv4 сервера (у VPS их может быть несколько).
list_local_ips() {
    if command -v ip >/dev/null 2>&1; then
        ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1
    else
        hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9.]+$'
    fi
}

# IP, который использует ИМЕННО эта нода: Caddy на него садится, он же идёт в
# ссылку. Берём NODE_IP из node.conf (если задан и всё ещё локальный), иначе
# авто (внешний get_ip). Важно при нескольких IP: на занятом nginx-ом IP Caddy
# не поднять, поэтому используем свободный, на который указывает домен.
node_ip() {
    local saved
    saved=$(node_get NODE_IP)
    if [ -n "$saved" ] && list_local_ips | grep -qxF "$saved" 2>/dev/null; then
        printf '%s' "$saved"; return
    fi
    get_ip
}

# Если домен ноды резолвится в один из ЛОКАЛЬНЫХ IP — фиксируем именно его как
# NODE_IP (Caddy сядет туда, не конфликтуя с другим сервисом на другом IP).
autoset_node_ip() {
    local host dip locals
    host=$(node_host); [ -n "$host" ] || return 1
    locals=$(list_local_ips)
    for dip in $(resolve_domain "$host" 2>/dev/null); do
        if printf '%s\n' "$locals" | grep -qxF "$dip"; then
            node_set NODE_IP "$dip"
            return 0
        fi
    done
    return 1
}

# Записывает node.conf (домен + имя ноды).
# Устанавливает/обновляет одно поле node.conf, не трогая остальные.
# ВАЖНО: значение пишем БЕЗ sed. Раньше строка обновлялась через
# `sed "s|^key=.*|key=$val|"`, и если значение содержало символы, особые для
# правой части sed (`&`, `\`, а также разделитель `|`), подстановка ломалась —
# настройка «не сохранялась». Частый случай — шаблон подписи с `|` или `&`.
# Теперь просто выкидываем старую строку ключа и дописываем новую через printf.
node_set() {   # key value
    local key="$1" val="$2" tmp
    mkdir -p "$DATA_DIR"; touch "$NODE_CONF"
    tmp=$(mktemp) || return 1
    # grep -v по якорю «^key=»: ключи у нас из [A-Z_], спецсимволов regex нет.
    # «^SUB_TAG_TMPL=» не заденет «SUB_TAG_TMPL_TS=» — после ключа требуется «=».
    grep -v "^${key}=" "$NODE_CONF" > "$tmp" 2>/dev/null
    printf '%s=%s\n' "$key" "$val" >> "$tmp"
    cat "$tmp" > "$NODE_CONF"
    rm -f "$tmp"
}

node_configure() {   # domain name
    node_set NODE_NAME "$2"
    node_set NODE_HOST "$1"
    node_set WEBROOT  "$WEBROOT"
}

# Адрес ноды для ССЫЛКИ подключения: домен подключения (CONN_HOST), если задан,
# иначе публичный IP. Позволяет показывать в подписке домен вместо «голого» IP.
# ВАЖНО: домен подключения должен быть DNS-only (A-запись прямо на IP ноды) —
# Hysteria работает по UDP/QUIC, а проксирование Cloudflare (UDP) не пропускает.
link_host() {
    local h; h=$(node_get CONN_HOST)
    [ -n "$h" ] && { printf '%s' "$h"; return; }
    node_ip
}

# ---- Оформление подписки (что видит пользователь в клиенте) ----
# Метка ноды (название сервера в клиенте; можно с эмодзи/флагом). По умолчанию — имя ноды.
node_label()       { local l; l=$(node_get NODE_LABEL); echo "${l:-$(node_name)}"; }
# Шаблон подписи каждого ключа (#фрагмент). Плейсхолдеры: {label} {user} {name} {online} {protocol}.
# {protocol} (HY2/VLESS/SS22/TUIC) подставляется ПОЗЖЕ, при сборке каждого URI —
# в render_tag протокол ещё не известен (см. build_user_link и proto_build_*).
sub_tag_tmpl()     { local t; t=$(node_get SUB_TAG_TMPL); [ -z "$t" ] && t='{label}'; printf '%s' "$t"; }
# Использует ли шаблон плейсхолдер {online} (общий онлайн ЭТОЙ ноды)? Если да —
# перед генерацией подписи/манифеста нужен свежий онлайн (refresh_online). Каждая
# нода печёт СВОЙ онлайн в свой манифест; ключи чужих нод в подписке несут онлайн
# тех нод (их манифесты стягиваются периодически, см. cluster_online_sync).
_tag_needs_online() { case "$(sub_tag_tmpl)" in *'{online}'*) return 0 ;; *) return 1 ;; esac; }
# Название всего профиля подписки в клиенте. Поддерживает те же плейсхолдеры,
# что и подпись ключа: {label} {user} {name} {online} (см. render_title).
sub_title()        { local t; t=$(node_get SUB_TITLE); echo "${t:-Доступ}"; }
# Есть ли в названии профиля плейсхолдеры? Если да — название у каждого юзера своё,
# и заголовок profile-title приходится раздавать по токенам (см. write_sub_titles).
# Плейсхолдеры плана ({plan}, {left}, …) — тоже персональные, они здесь же.
_title_has_ph()    { case "$(sub_title)" in *'{user}'*|*'{label}'*|*'{name}'*|*'{online}'*) return 0 ;; *) _plan_has_ph "$(sub_title)" ;; esac; }
_title_needs_online() { case "$(sub_title)" in *'{online}'*) return 0 ;; *) return 1 ;; esac; }
# Как часто клиент обновляет подписку (часы).
sub_update_hours() { local h; h=$(node_get SUB_UPDATE_HOURS); [[ "$h" =~ ^[0-9]+$ ]] || h=12; echo "$h"; }

# ---- Прочее оформление подписки: ссылки и анонс (см. docs/guide/SUB-HEADERS.md) ----
# Кнопка «поддержка» в клиенте (обычно ссылка на бота/чат). Пусто — кнопки нет.
sub_support_url()  { node_get SUB_SUPPORT_URL; }
# Кнопка «страница подписки». По умолчанию — корень домена ноды.
sub_page_url()     { local u; u=$(node_get SUB_PAGE_URL); [ -n "$u" ] && printf '%s' "$u" || printf 'https://%s/' "$(node_host)"; }
# Куда ведёт клик по тексту анонса (v2RayTun; Happ показывает анонс без ссылки).
sub_announce_url() { node_get SUB_ANN_URL; }
# Тексты анонса по типу плана. Плейсхолдеры: те же, что у названия профиля, плюс
# плановые (см. plan_apply_ph). Клиенты показывают не больше ~200 символов.
# Значение «-» — не показывать анонс этому плану (пустая настройка = дефолт ниже).
_ann_or_default() { case "$1" in '-') printf '' ;; '') printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }
sub_ann_demo() { _ann_or_default "$(node_get SUB_ANN_DEMO)" \
    'Демо-доступ: {total} на {left}. Пока он действует — оформите бесплатный тариф без таймера или платный без лимитов.'; }
sub_ann_free() { _ann_or_default "$(node_get SUB_ANN_FREE)" \
    'Бесплатный тариф: израсходовано {used} из {total} за неделю. Нужно больше и без ограничений — платный тариф.'; }
# Аргумент «noexp» — у юзера нет срока (бессрочный доступ): дефолтный текст про
# дату в этом случае читался бы как «активен до без срока».
sub_ann_paid() {   # [noexp]
    local d='Тариф активен до {expire} (осталось {left}). Устройств: {devices}. Израсходовано {used}.'
    [ -n "${1:-}" ] && d='Доступ без ограничения по сроку. Устройств: {devices}. Израсходовано {used}.'
    _ann_or_default "$(node_get SUB_ANN_PAID)" "$d"
}
# Произвольные заголовки подписки одной строкой: «имя: значение|имя: значение».
# Через них включается ЛЮБОЙ параметр клиента, которого нет отдельной настройкой
# (у Happ их шестой десяток) — список параметров в docs/guide/SUB-HEADERS.md.
sub_headers_extra() { node_get SUB_HEADERS; }

# Подстановка плейсхолдеров в шаблон для конкретного юзера.
_render_ph() {   # tmpl user
    local t="$1" u="$2"
    t=${t//\{user\}/$u}
    t=${t//\{label\}/$(node_label)}
    t=${t//\{name\}/$(node_name)}
    # {online} — общий онлайн ЭТОЙ ноды (сколько юзеров сейчас онлайн), одинаков
    # для всех её ключей: это индикатор загрузки сервера, чтобы клиент выбрал, к
    # какому серверу подключиться. Ключи чужих нод в подписке несут онлайн тех нод
    # (испечён в их манифестах). Требует свежего CACHED_ONLINE — его обновляет
    # refresh_online в publish_manifest/regen_subscriptions.
    case "$t" in *'{online}'*) t=${t//\{online\}/$(node_online_count)} ;; esac
    printf '%s' "$t"
}

# Подпись ключа по шаблону для конкретного юзера.
render_tag()   { _render_ph "$(sub_tag_tmpl)" "$1"; }
# Название профиля по шаблону для конкретного юзера. {protocol} тут смысла не
# имеет (профиль один на все протоколы) — вырезаем, чтобы не утёк буквально.
render_title() { local t; t=$(plan_apply_ph "$(_render_ph "$(sub_title)" "$1")" "$1"); printf '%s' "${t//\{protocol\}/}"; }

# ---- Плейсхолдеры плана: что за доступ у юзера и сколько от него осталось ----
# Живут здесь же, рядом с остальным оформлением подписки, и работают и в названии
# профиля, и в тексте анонса. Считаются ЛЕНИВО: шаблон без них не платит ни одним
# вызовом awk (в regen эти функции зовутся на каждого юзера).
_plan_has_ph() {   # tmpl
    case "$1" in
        *'{plan}'*|*'{expire}'*|*'{left}'*|*'{used}'*|*'{total}'*|*'{devices}'*|*'{rate}'*) return 0 ;;
        *) return 1 ;;
    esac
}

# «43 мин» / «7 ч» / «12 дн» до метки времени; «истёк» — если она в прошлом.
_fmt_until() {   # ts -> строка
    local ts="${1:-0}" left
    [ "$ts" -gt 0 ] 2>/dev/null || { printf 'бессрочно'; return; }
    left=$(( ts - $(date +%s) ))
    if   [ "$left" -le 0 ];     then printf 'истёк'
    elif [ "$left" -lt 3600 ];  then printf '%d мин' $(( left / 60 ))
    elif [ "$left" -lt 86400 ]; then printf '%d ч' $(( left / 3600 ))
    else printf '%d дн' $(( left / 86400 ))
    fi
}

# Факты о плане юзера: «вид|срок(ts)|израсходовано|лимит» (0 = нет срока/лимита).
# Вид: demo — демо-ключ, free — бесплатный тариф, paid — обычный (оплаченный).
# Источники те же, что у прогонок демо и бесплатного тарифа, чтобы клиент видел
# ровно те цифры, по которым доступ реально отбирают.
# Кэш на процесс: за один прогон regen факты нужны трижды (название профиля,
# subscription-userinfo, анонс), а каждый расчёт — несколько проходов по файлам.
declare -gA _PLAN_FACTS=()
user_plan_facts() {   # user -> kind|expire|used|total
    local user="$1" kind=paid exp=0 used=0 total=0 row base date_
    # Название профиля рендерится и «без юзера» (default в map) — тогда фактов нет
    # и кэшировать нечего.
    [ -n "$user" ] || { printf 'paid|0|0|0'; return; }
    [ -n "${_PLAN_FACTS[$user]:-}" ] && { printf '%s' "${_PLAN_FACTS[$user]}"; return; }
    if declare -F demo_row >/dev/null 2>&1 && row=$(demo_row "$user") && [ -n "$row" ]; then
        kind=demo
        exp=$(printf '%s'   "$row" | cut -d'|' -f4)
        total=$(printf '%s' "$row" | cut -d'|' -f5)
        base=$(printf '%s'  "$row" | cut -d'|' -f6)
        used=$(( $(demo_user_bytes "$user") - ${base:-0} ))
    elif declare -F freeplan_has >/dev/null 2>&1 && freeplan_has "$user"; then
        kind=free
        total=$(free_wk_limit 2>/dev/null)
        base=$(freeplan_field "$user" 5)      # wk_base — база недельного окна
        used=$(( $(freeplan_user_bytes "$user") - ${base:-0} ))
    else
        date_=$(get_user_expiry "$user" 2>/dev/null)
        [ -n "$date_" ] && exp=$(date -d "$date_ 23:59:59" +%s 2>/dev/null || echo 0)
        declare -F freeplan_user_bytes >/dev/null 2>&1 && used=$(freeplan_user_bytes "$user")
    fi
    [ "${used:-0}" -ge 0 ] 2>/dev/null || used=0
    _PLAN_FACTS[$user]="${kind}|${exp:-0}|${used:-0}|${total:-0}"
    printf '%s' "${_PLAN_FACTS[$user]}"
}

# Подставляет плановые плейсхолдеры в уже отрендеренный шаблон.
plan_apply_ph() {   # text user -> text
    local t="$1" user="$2" kind exp used total
    _plan_has_ph "$t" || { printf '%s' "$t"; return; }
    IFS='|' read -r kind exp used total <<< "$(user_plan_facts "$user")"
    case "$kind" in
        demo) t=${t//\{plan\}/демо} ;;
        free) t=${t//\{plan\}/бесплатный} ;;
        *)    t=${t//\{plan\}/платный} ;;
    esac
    t=${t//\{left\}/$(_fmt_until "$exp")}
    if [ "${exp:-0}" -gt 0 ] 2>/dev/null; then
        t=${t//\{expire\}/$(date -d "@$exp" '+%d.%m.%Y' 2>/dev/null)}
    else
        t=${t//\{expire\}/без срока}
    fi
    t=${t//\{used\}/$(format_bytes "$used")}
    [ "${total:-0}" -gt 0 ] 2>/dev/null \
        && t=${t//\{total\}/$(format_bytes "$total")} \
        || t=${t//\{total\}/без лимита}
    t=${t//\{devices\}/$(get_user_devices "$user" 2>/dev/null)}
    t=${t//\{rate\}/$(get_user_rate "$user" 2>/dev/null)}
    printf '%s' "$t"
}

# Глобальные (общие для всего кластера) настройки. Метка ноды (NODE_LABEL) сюда
# НЕ входит — она у каждой ноды своя. POOL_LIMIT/NODE_LIMIT — глобальные лимиты
# подключений (см. ниже), синхронизируются тем же LWW-механизмом.
SETTING_KEYS="SUB_TITLE SUB_TAG_TMPL SUB_UPDATE_HOURS POOL_LIMIT NODE_LIMIT
SUB_SUPPORT_URL SUB_PAGE_URL SUB_ANN_URL SUB_ANN_DEMO SUB_ANN_FREE SUB_ANN_PAID SUB_HEADERS"

setting_ts() { local t; t=$(node_get "${1}_TS"); [[ "$t" =~ ^[0-9]+$ ]] && echo "$t" || echo 0; }

# Наибольший известный ts настройки: локальный + опубликованный + кэши пиров.
# Нужен, чтобы локальная правка гарантированно выигрывала LWW даже при
# расхождении часов между нодами (ts работает как логический счётчик Лампорта).
_setting_max_seen_ts() {   # key -> ts
    local k="$1"
    {
        setting_ts "$k"
        [ -f "$WEBROOT/cluster/settings" ] && awk -F'|' -v k="$k" '$1==k{print $3}' "$WEBROOT/cluster/settings" 2>/dev/null
        [ -d "$PEERS_DIR" ] && awk -F'|' -v k="$k" '$1==k{print $3}' "$PEERS_DIR"/*.settings 2>/dev/null
    } | awk 'BEGIN{m=0} /^[0-9]+$/ && $1+0>m {m=$1+0} END{print m+0}'
}

# Установить общую настройку + метку времени (для синхронизации last-write-wins).
# Локальная правка (без явного ts): ts = max(сейчас, известный_максимум+1), чтобы
# изменение НЕ откатывалось устаревшим, но большим по ts значением пира (частая
# причина «настройка не сохраняется» — расхождение часов между нодами). При явном
# ts (применение записи с ноды-пира в cluster_apply_settings) берём его как есть.
setting_set() {   # key value [ts]
    local k="$1" v="$2" ts="${3:-}"
    if [ -z "$ts" ]; then
        local now maxseen; now=$(date +%s); maxseen=$(_setting_max_seen_ts "$k")
        if [ "${maxseen:-0}" -ge "$now" ] 2>/dev/null; then ts=$((maxseen + 1)); else ts="$now"; fi
    fi
    node_set "$k" "$v"
    node_set "${k}_TS" "$ts"
}

