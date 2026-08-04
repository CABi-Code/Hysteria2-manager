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
sub_title()        { local t; t=$(node_get SUB_TITLE); echo "${t:-VPN}"; }
# Есть ли в названии профиля плейсхолдеры? Если да — название у каждого юзера своё,
# и заголовок profile-title приходится раздавать по токенам (см. write_sub_titles).
_title_has_ph()    { case "$(sub_title)" in *'{user}'*|*'{label}'*|*'{name}'*|*'{online}'*) return 0 ;; *) return 1 ;; esac; }
_title_needs_online() { case "$(sub_title)" in *'{online}'*) return 0 ;; *) return 1 ;; esac; }
# Как часто клиент обновляет подписку (часы).
sub_update_hours() { local h; h=$(node_get SUB_UPDATE_HOURS); [[ "$h" =~ ^[0-9]+$ ]] || h=12; echo "$h"; }

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
render_title() { local t; t=$(_render_ph "$(sub_title)" "$1"); printf '%s' "${t//\{protocol\}/}"; }

# Глобальные (общие для всего кластера) настройки. Метка ноды (NODE_LABEL) сюда
# НЕ входит — она у каждой ноды своя. POOL_LIMIT/NODE_LIMIT — глобальные лимиты
# подключений (см. ниже), синхронизируются тем же LWW-механизмом.
SETTING_KEYS="SUB_TITLE SUB_TAG_TMPL SUB_UPDATE_HOURS POOL_LIMIT NODE_LIMIT"

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
    local k="$1" v="$2" ts="$3"
    if [ -z "$ts" ]; then
        local now maxseen; now=$(date +%s); maxseen=$(_setting_max_seen_ts "$k")
        if [ "${maxseen:-0}" -ge "$now" ] 2>/dev/null; then ts=$((maxseen + 1)); else ts="$now"; fi
    fi
    node_set "$k" "$v"
    node_set "${k}_TS" "$ts"
}

