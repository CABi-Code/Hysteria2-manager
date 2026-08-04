#!/bin/bash
# ================================================
# Ссылки и токены подписки: генерация, лимит ссылок, манифест, регенерация.
# Клиент добавляет https://<домен>/sub/<token>, Caddy раздаёт статику. См. node.sh.
# ================================================

# ---- Релей (фронт-сервер, реально прячет IP ноды) ----
# Релей — отдельный дешёвый VPS. Клиенты/DNS видят IP релея, релей форвардит
# трафик (UDP Hysteria + TCP 80/443) на скрытую ноду. dig покажет IP релея.
relay_host() { node_get RELAY_HOST; }

# Генерирует скрипт, который надо запустить НА РЕЛЕЙ-СЕРВЕРЕ (от root). Печатает
# путь к скрипту. Форвардит UDP-порт Hysteria и TCP 80/443 на реальную ноду.
generate_relay_script() {
    local node_ip hyport out
    node_ip=$(node_ip); hyport=$(get_port)
    out="$DATA_DIR/relay-setup.sh"
    cat > "$out" <<EOF
#!/bin/bash
# ╔═══════════════════════════════════════════════════════════════╗
# ║  ЗАПУСКАТЬ НА РЕЛЕЙ-СЕРВЕРЕ (отдельный VPS), от root.           ║
# ║  Форвардит трафик на скрытую ноду ${node_ip}.                  ║
# ╚═══════════════════════════════════════════════════════════════╝
set -e
NODE_IP="${node_ip}"
HYPORT="${hyport}"

# Включаем форвардинг пакетов
sysctl -w net.ipv4.ip_forward=1 >/dev/null
grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf

# UDP — сам VPN (Hysteria/QUIC)
iptables -t nat -C PREROUTING -p udp --dport "\$HYPORT" -j DNAT --to-destination "\$NODE_IP:\$HYPORT" 2>/dev/null || \\
  iptables -t nat -A PREROUTING -p udp --dport "\$HYPORT" -j DNAT --to-destination "\$NODE_IP:\$HYPORT"

# TCP 80/443 — подписка (Caddy на ноде). Нужно, только если домен подписки тоже
# указывает на релей. Без этого можно убрать, но тогда IP ноды виден в подписке.
for tp in 80 443; do
  iptables -t nat -C PREROUTING -p tcp --dport "\$tp" -j DNAT --to-destination "\$NODE_IP:\$tp" 2>/dev/null || \\
    iptables -t nat -A PREROUTING -p tcp --dport "\$tp" -j DNAT --to-destination "\$NODE_IP:\$tp"
done

# Обратный путь
iptables -t nat -C POSTROUTING -d "\$NODE_IP" -j MASQUERADE 2>/dev/null || \\
  iptables -t nat -A POSTROUTING -d "\$NODE_IP" -j MASQUERADE

# Сохраняем правила (если установлен iptables-persistent)
mkdir -p /etc/iptables && iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

echo "✅ Релей настроен: UDP \$HYPORT + TCP 80,443 -> \$NODE_IP"
echo "   Не забудьте открыть эти порты в firewall релея."
EOF
    chmod +x "$out"
    printf '%s' "$out"
}

# Права на секреты подписки (читает только менеджер от root).
secure_sub_files() {
    [ -f "$SUBTOKENS_DB" ] && chmod 600 "$SUBTOKENS_DB" 2>/dev/null || true
    [ -f "$CLUSTER_SECRET_FILE" ] && chmod 600 "$CLUSTER_SECRET_FILE" 2>/dev/null || true
}

# Файлы в WEBROOT читает процесс Caddy (обычно пользователь caddy). Каталоги
# делаем проходимыми для группы caddy, но не для остальных (имена файлов в sub/
# = токены, их нельзя давать листать чужим). Манифест с паролями — 640.
secure_web_files() {
    local cg=root
    id caddy >/dev/null 2>&1 && cg=caddy
    mkdir -p "$WEBROOT/sub" "$WEBROOT/cluster"
    chown -R "root:${cg}" "$WEBROOT" 2>/dev/null || true
    chmod 750 "$WEBROOT" "$WEBROOT/sub" "$WEBROOT/cluster" 2>/dev/null || true
    find "$WEBROOT/sub" -type f -exec chmod 640 {} + 2>/dev/null || true
    [ -f "$WEBROOT/cluster/manifest" ]   && chmod 640 "$WEBROOT/cluster/manifest" 2>/dev/null || true
    [ -f "$WEBROOT/cluster/peers.list" ] && chmod 640 "$WEBROOT/cluster/peers.list" 2>/dev/null || true
}

# Собирает клиентскую ссылку hysteria2:// для юзера. ip/port/obfs/sni можно
# передать (меню кеширует их), иначе берём из конфига. tag — суффикс #...,
# по умолчанию имя юзера; для подписки добавляем имя ноды (user@node), чтобы
# клиент видел, с какого сервера ключ.
build_user_link() {
    local user="$1" pass="$2"
    local ip="${3:-$(link_host)}" port="${4:-$(get_port)}"
    local obfs="${5:-$(get_obfs_pass)}" sni="${6:-$(get_sni)}"
    local tag="${7:-$user}"
    # {protocol} — своя метка у каждого ключа (у юзера ключи разных протоколов).
    # Подставляется здесь, а не в render_tag: там протокол ещё не известен. HY2.
    tag=${tag//\{protocol\}/HY2}
    printf 'hysteria2://%s:%s@%s:%s/?obfs=salamander&obfs-password=%s&sni=%s&insecure=1#%s' \
        "$user" "$pass" "$ip" "$port" "$obfs" "$sni" "$tag"
}

# Плоский список ВСЕХ прямых ссылок юзера: локальный hysteria2:// + локальные
# доп. протоколы (VLESS/SS2022/TUIC/Trojan) + ключи всех остальных нод кластера
# из кэшированных манифестов пиров. По одной ссылке на строку, дедуп по host:port
# — ровно тот же контент, что кодируется в base64-подписку (см. regen_subscriptions),
# только в открытом виде. Нужен Web API, чтобы отдать кабинету прямые ключи по
# всем протоколам и всему доступному кластеру, а не только hysteria2 этой ноды.
build_user_all_links() {
    local user="$1"
    local ip port obfs sni lp cst
    # Отключённый/удалённый по кластеру не получает ссылок (как и в подписке).
    cst=""
    declare -F cstate_get >/dev/null 2>&1 && cst=$(cstate_get "$user")
    [ "$cst" = "deleted" ] || [ "$cst" = "disabled" ] && return 0
    lp=$(get_user_password "$user")
    ip=$(link_host); port=$(get_port); obfs=$(get_obfs_pass); sni=$(get_sni)
    {
        [ -n "$lp" ] && { build_user_link "$user" "$lp" "$ip" "$port" "$obfs" "$sni" "$(render_tag "$user")"; echo; }
        # Локальные ссылки доп. протоколов этого юзера.
        [ -n "$lp" ] && declare -F proto_user_uris >/dev/null 2>&1 && \
            proto_user_uris "$user" "$lp" "$ip" "$(render_tag "$user")"
        # Ключи остальных нод кластера из манифестов пиров (все их протоколы).
        [ -d "$PEERS_DIR" ] && cat "$PEERS_DIR"/*.manifest 2>/dev/null \
            | awk -F'\t' -v u="$user" '$1==u{print $2}'
    } | grep -v '^$' | awk '
        {
          # Санитайз {protocol} от старых нод (см. regen_subscriptions).
          if (index($0,"{protocol}")>0) {
            lbl="KEY"
            if      ($0 ~ /^hysteria2:\/\//) lbl="HY2"
            else if ($0 ~ /^vless:\/\//)     lbl="VLESS"
            else if ($0 ~ /^ss:\/\//)        lbl="SS22"
            else if ($0 ~ /^tuic:\/\//)      lbl="TUIC"
            else if ($0 ~ /^trojan:\/\//)    lbl="TROJAN"
            gsub(/\{protocol\}/, lbl)
          }
          s=$0
          sub(/^[^/]*\/\//,"",s)   # убрать схему
          sub(/\/.*/,"",s)          # оставить user:pass@host:port
          n=split(s,p,"@"); hp=p[n] # host:port = после ПОСЛЕДНЕГО @
          if (!seen[hp]++) print $0
        }'
}

# Токен подписки юзера (создаёт при отсутствии). Высокоэнтропийный — он и есть
# «секрет» в ссылке https://домен/sub/<token>.
sub_token_for() {
    local user="$1" token
    touch "$SUBTOKENS_DB" 2>/dev/null
    token=$(awk -F: -v u="$user" '$1==u{print $2; exit}' "$SUBTOKENS_DB" 2>/dev/null)
    if [ -z "$token" ]; then
        token=$(pwgen -s 40 1)
        printf '%s:%s\n' "$user" "$token" >> "$SUBTOKENS_DB"
        secure_sub_files
    fi
    printf '%s' "$token"
}
sub_token_remove() { sed -i "/^${1}:/d" "$SUBTOKENS_DB" 2>/dev/null; }

# ---- Несколько ссылок подписки на юзера (по одной на устройство/человека) ----
# У юзера может быть несколько токенов (строк «user:token» в SUBTOKENS_DB) — все
# отдают один и тот же набор ключей. Разные токены нужны, чтобы раздать подписку
# нескольким людям и по логам Caddy видеть IP отдельно по каждой ссылке.

# Все ЛОКАЛЬНЫЕ токены юзера (первый — основной, созданный sub_token_for).
sub_tokens_all() { awk -F: -v u="$1" '$1==u{print $2}' "$SUBTOKENS_DB" 2>/dev/null; }

# Токены юзера ПО ВСЕМУ КЛАСТЕРУ (локальные + кэш пиров), для подсчёта лимита ссылок.
sub_tokens_cluster() {
    { sub_tokens_all "$1"
      [ -d "$PEERS_DIR" ] && awk -F: -v u="$1" '$1==u{print $2}' "$PEERS_DIR"/*.subtokens 2>/dev/null; } \
    | grep -v '^$' | sort -u
}

# Сколько ссылок разрешено юзеру = его кол-во устройств (0/∞ → без ограничения).
sub_links_allowed() { local d; d=$(get_user_devices "$1"); echo "${d:-1}"; }

# ---- Слоты: у каждой доп. ссылки свой пароль (docs/design/SLOTS) ----
# Устройство опознаётся по КРЕДУ, а не по адресу: за домашним NAT адрес один на
# всех, и продавать по нему устройства нельзя. Слот = токен подписки, пароль
# слота выводится из пароля юзера и самого токена.
#
# Почему так, а не «слот N по номеру»: номер пришлось бы хранить и держать
# одинаковым на всех нодах, а при добавлении ссылки — не сдвигать чужие. Токен
# уже уникален, уже синхронизируется по кластеру и не меняется, поэтому любая
# нода получает тот же пароль без единого нового поля в обмене.
#
# Основной (первый) токен остаётся на БАЗОВОМ пароле юзера: ровно его печатает
# меню «получить ссылку», и уже розданные ключи не должны протухнуть.
sub_token_password() {   # user token -> пароль слота ("" если нет базового)
    local user="$1" token="$2" base
    [ -n "$token" ] || return 1
    base=$(get_user_password "$user")
    [ -n "$base" ] || return 1
    printf '%s|%s' "$base" "$token" | sha256sum 2>/dev/null | cut -c1-32
}

# id слота для API Hysteria: «user.<8 hex>». Именно его печатает auth-скрипт, и
# по нему движок ведёт СЕССИИ отдельно для каждой ссылки — это единственный
# способ отличить два устройства за одним адресом (guide/SLOTS.md §6).
# Суффикс — хеш токена, а не сам токен: 8 hex-символов однозначно опознаются
# регуляркой при сворачивании id обратно в юзера, а имена юзеров точек не
# содержат вовсе. Базовый пароль слот-id НЕ получает — он остаётся просто
# именем юзера, поэтому накопленный трафик и история не рвутся.
sub_token_slotid() {   # user token -> «user.xxxxxxxx»
    local user="$1" token="$2" h
    [ -n "$token" ] || return 1
    h=$(printf '%s' "$token" | sha256sum 2>/dev/null | cut -c1-8)
    [ -n "$h" ] || return 1
    printf '%s.%s' "$user" "$h"
}

# Справочник паролей слотов для скрипта аутентификации: «user|пароль|токен|id».
# Берём ВСЕ токены юзера по кластеру, включая свой основной: пароль слота обязан
# приниматься на ЛЮБОЙ ноде. В подписке слота лежат ключи всех нод, и если бы
# нода принимала только «свои» токены, устройство подключилось бы к одной ноде и
# получило отказ на остальных. Все ноды считают пароль из одних и тех же данных
# (пароль юзера + токен, оба синхронны), поэтому таблицы совпадают без обмена.
write_slotpass_db() {
    local tmp="${SLOTPASS_DB}.tmp.$BASHPID" user token owner group
    : > "$tmp" 2>/dev/null || return 0
    while IFS= read -r user; do
        [ -n "$user" ] || continue
        while IFS= read -r token; do
            [ -n "$token" ] || continue
            printf '%s|%s|%s|%s\n' "$user" "$(sub_token_password "$user" "$token")" \
                "$token" "$(sub_token_slotid "$user" "$token")" >> "$tmp"
        done < <(sub_tokens_cluster "$user")
    done < <(cut -d: -f1 "$USERS_DB" 2>/dev/null | grep -v '^$' | sort -u)
    mv "$tmp" "$SLOTPASS_DB" 2>/dev/null || { rm -f "$tmp"; return 0; }
    # Читает файл процесс hysteria (скрипт аутентификации) — права как у users.db.
    if declare -F service_identity >/dev/null 2>&1; then
        read -r owner group < <(service_identity)
        [ -n "$owner" ] && chown "${owner}:${group}" "$SLOTPASS_DB" 2>/dev/null
    fi
    chmod 640 "$SLOTPASS_DB" 2>/dev/null || true
}

# Создать новую доп. ссылку (токен). Печатает новый токен или пусто при отказе.
# Соблюдает лимит: число ссылок по кластеру не должно превышать кол-во устройств.
sub_link_add() {   # user -> token | ""
    local user="$1" allowed have token
    sub_token_for "$user" >/dev/null           # гарантируем основной токен
    allowed=$(sub_links_allowed "$user")
    have=$(sub_tokens_cluster "$user" | grep -c .)
    if [ "${allowed:-0}" -gt 0 ] 2>/dev/null && [ "${have:-0}" -ge "$allowed" ]; then
        return 1                               # лимит ссылок исчерпан
    fi
    token=$(pwgen -s 40 1)
    printf '%s:%s\n' "$user" "$token" >> "$SUBTOKENS_DB"
    secure_sub_files
    write_slotpass_db      # пароль новой ссылки должен работать сразу
    printf '%s' "$token"
}

# Удалить конкретную ссылку (токен) юзера. Основной (первый) токен не удаляем,
# чтобы у юзера всегда оставалась рабочая подписка.
sub_link_remove() {   # user token
    local user="$1" token="$2" primary
    primary=$(sub_token_for "$user")
    [ "$token" = "$primary" ] && return 2      # основной токен не трогаем
    sub_tokens_all "$user" | grep -qxF "$token" || return 1
    sed -i "/^${user}:${token}\$/d" "$SUBTOKENS_DB" 2>/dev/null
    rm -f "$WEBROOT/sub/$token" 2>/dev/null
    secure_sub_files
    return 0
}

# Фильтр протоколов для конкретного юзера (stdin → stdout). Демо-профилю отдаём
# ТОЛЬКО Hysteria2: её аутентификация читает users.db на каждом подключении, то
# есть ключ выдаётся мгновенно и не требует трогать конфиги Xray/sing-box (их
# правка = рестарт сервиса на каждое нажатие гостевой кнопки). TUIC демо не
# положен и по второй причине — там нет пер-юзерного учёта трафика, квоту не
# проверить. Полный набор протоколов — после оплаты.
sub_filter_protocols() {   # user
    if declare -F demo_is >/dev/null 2>&1 && demo_is "$1"; then
        grep '^hysteria2://'
    else
        cat
    fi
}

# Полный перевыпуск доступа: новая ссылка + новые ключи ВСЕХ протоколов на ВСЕХ
# нодах. Жмут при утечке, поэтому убиваем ВСЕ токены юзера (включая доп. ссылки —
# розданное считаем скомпрометированным). Печатает новую ссылку.
reset_subscription() {   # user -> url
    local user="$1" tok
    sub_enabled || return 1
    db_user_exists "$user" || is_user_disabled "$user" || return 1
    while IFS= read -r tok; do
        [ -n "$tok" ] && rm -f "$WEBROOT/sub/$tok" 2>/dev/null
    done < <(sub_tokens_all "$user")
    sub_token_remove "$user"
    sub_token_for "$user" >/dev/null                    # новый основной токен
    # Ключи всех протоколов производны от пароля (proto_uuid/proto_upsk), так что
    # ротация пароля инвалидирует их разом; внутри — кик и sub_refresh.
    change_user_password "$user" >/dev/null || return 1
    declare -F pwreset_mark >/dev/null 2>&1 && pwreset_mark "$user"
    subscription_url "$user"
}

# Готовая ссылка-подписка для юзера.
subscription_url() {
    local user="$1"
    sub_enabled || return 1
    printf 'https://%s/sub/%s\n' "$(node_host)" "$(sub_token_for "$user")"
}

# Публикует манифест ЭТОЙ ноды: «user<TAB>uri» по всем локальным юзерам. Его
# забирают другие ноды (за заголовком X-Cluster-Auth) и подмешивают в подписку.
publish_manifest() {
    sub_enabled || return 0
    mkdir -p "$WEBROOT/cluster"
    # {online} в шаблоне подписи — обновляем онлайн ЭТОЙ ноды (CACHED_ONLINE),
    # его печём в свои ключи. Онлайн чужих нод приходит уже испечённым в их
    # манифестах (их обновляет cluster_online_sync).
    _tag_needs_online && refresh_online
    local tmp="$WEBROOT/cluster/manifest.tmp.$BASHPID" u p node ip port obfs sni
    node=$(node_name)
    # Параметры сервера считаем один раз (get_ip дёргает сеть) и переиспользуем.
    ip=$(link_host); port=$(get_port); obfs=$(get_obfs_pass); sni=$(get_sni)
    : > "$tmp"
    local _proto_on=0
    declare -F proto_any_enabled >/dev/null 2>&1 && proto_any_enabled && _proto_on=1
    while IFS=: read -r u p; do
        [ -n "$u" ] || continue
        printf '%s\t%s\n' "$u" "$(build_user_link "$u" "$p" "$ip" "$port" "$obfs" "$sni" "$(render_tag "$u")")" >> "$tmp"
        # Доп. протоколы (VLESS/SS2022/TUIC) — по строке на протокол, тем же
        # форматом «user<TAB>uri», чтобы пиры подмешали их в подписку так же, как
        # hysteria2://. Адрес/подпись — те же, что у основного ключа.
        if [ "$_proto_on" = 1 ]; then
            local _puri
            while IFS= read -r _puri; do
                [ -n "$_puri" ] || continue
                printf '%s\t%s\n' "$u" "$_puri" >> "$tmp"
            done < <(proto_user_uris "$u" "$p" "$ip" "$(render_tag "$u")")
        fi
    done < "$USERS_DB"
    mv "$tmp" "$WEBROOT/cluster/manifest"
    secure_web_files
}

# Пересобирает файлы подписки для всех известных юзеров: локальные ключи +
# ключи из кэшированных манифестов пиров. Дедуп по host:port.
# Все юзеры, которым положена подписка: наши + пришедшие из манифестов пиров.
sub_all_users() {
    {
        cut -d: -f1 "$USERS_DB" 2>/dev/null
        [ -d "$PEERS_DIR" ] && awk -F'\t' '{print $1}' "$PEERS_DIR"/*.manifest 2>/dev/null
    } | grep -v '^$' | sort -u
}

# Пересобрать подписку ОДНОГО юзера. Вынесено из regen_subscriptions: полный
# проход по всем юзерам стоит десятки секунд (на 15 юзерах замерено 44 с), а
# добавление или снятие ссылки-устройства из мини-аппа должно отвечать сразу.
# ip/port/obfs/sni можно передать (общий проход их уже посчитал), иначе берём из
# конфига сами.
regen_user_subscription() {   # user [ip port obfs sni]
    local user="$1"
    local ip="${2:-$(link_host)}" port="${3:-$(get_port)}"
    local obfs="${4:-$(get_obfs_pass)}" sni="${5:-$(get_sni)}"
    local lp content tok toks cst primary locals tokpass tokcontent
    [ -n "$user" ] || return 0
    # Точка правды: для удалённого/отключённого по кластеру отдаём ПУСТУЮ
    # подписку (клиент остаётся без серверов), даже если он ещё «висит» в кэше
    # манифеста пира. Так отключение/удаление действует сразу, не дожидаясь
    # пиров. Важно перезаписать токены пустым, а не пропустить — иначе остался
    # бы старый файл подписки с рабочими ключами.
    cst=""
    declare -F cstate_get >/dev/null 2>&1 && cst=$(cstate_get "$user")
    if [ "$cst" = "deleted" ] || [ "$cst" = "disabled" ]; then
        content=""
    else
        lp=$(get_user_password "$user")
        content=$(
            {
                [ -n "$lp" ] && { build_user_link "$user" "$lp" "$ip" "$port" "$obfs" "$sni" "$(render_tag "$user")"; echo; }
                # Локальные ссылки доп. протоколов этого юзера (VLESS/SS2022/TUIC).
                [ -n "$lp" ] && declare -F proto_user_uris >/dev/null 2>&1 && \
                    proto_user_uris "$user" "$lp" "$ip" "$(render_tag "$user")"
                [ -d "$PEERS_DIR" ] && cat "$PEERS_DIR"/*.manifest 2>/dev/null \
                    | awk -F'\t' -v u="$user" '$1==u{print $2}'
            } | sub_filter_protocols "$user" | grep -v '^$' | awk '
                {
                  # Санитайз: старые ноды кластера не умеют подставлять
                  # {protocol} и присылают его литералом. Символы {} в
                  # #фрагменте ломают парсер клиента, и такие ключи (а с
                  # ними и вся нода) пропадают из подписки. Заменяем на метку
                  # по схеме URI, пока пиры не обновятся.
                  if (index($0,"{protocol}")>0) {
                    lbl="KEY"
                    if      ($0 ~ /^hysteria2:\/\//) lbl="HY2"
                    else if ($0 ~ /^vless:\/\//)     lbl="VLESS"
                    else if ($0 ~ /^ss:\/\//)        lbl="SS22"
                    else if ($0 ~ /^tuic:\/\//)      lbl="TUIC"
                    else if ($0 ~ /^trojan:\/\//)    lbl="TROJAN"
                    gsub(/\{protocol\}/, lbl)
                  }
                  s=$0
                  sub(/^[^/]*\/\//,"",s)   # убрать схему hysteria2://
                  sub(/\/.*/,"",s)          # убрать путь/квери/фрагмент -> user:pass@host:port
                  n=split(s,p,"@"); hp=p[n]  # host:port = после ПОСЛЕДНЕГО @ (пароль может содержать @)
                  if (!seen[hp]++) print $0
                }'
        )
    fi
    # ВАЖНО: пишем подписку под ВСЕ токены юзера (наш + токены пиров). Так
    # уже розданная ссылка НИКОГДА не ломается, даже если на другой ноде у
    # юзера свой токен. Свой токен обязателен — создаём, если нет. Для
    # УДАЛЁННОГО свой токен НЕ создаём (иначе воскреснет) — только перезапишем
    # пустым уже существующие токены пиров.
    if [ "$cst" = "deleted" ]; then
        toks=$( [ -d "$PEERS_DIR" ] && awk -F: -v u="$user" '$1==u{print $2}' "$PEERS_DIR"/*.subtokens 2>/dev/null )
    else
        toks=$(
            sub_token_for "$user" >/dev/null    # гарантируем основной токен
            sub_tokens_all "$user"              # ВСЕ локальные токены (доп. ссылки)
            [ -d "$PEERS_DIR" ] && awk -F: -v u="$user" '$1==u{print $2}' "$PEERS_DIR"/*.subtokens 2>/dev/null
        )
    fi
    toks=$(printf '%s\n' "$toks" | grep -v '^$' | sort -u)
    # Каждая ссылка — свой слот со своим паролем Hysteria (docs/design/SLOTS).
    # Основной токен отдаёт базовый пароль (см. sub_token_password), остальные —
    # производный: подменяем userinfo в hysteria2:// уже готовых строк, включая
    # ключи ПИРОВ из манифестов. Пиры считают тот же пароль из тех же данных,
    # поэтому менять формат обмена не понадобилось.
    # Доп. протоколы (Xray/TUIC) слотов не получают: их движки всё равно не
    # умеют отказать на занятом слоте (guide/DEVICE-LIMITS.md §5), а
    # пер-слотовые креды размножили бы юзеров в конфигах и сломали бы учёт
    # трафика, который ведётся по имени.
    # Пароль слота подставляем ТОЛЬКО в свои доп. токены (их заводит
    # sub_link_add — это и есть «ссылка на устройство»). Основной токен и
    # токены, выданные другими нодами, отдают базовый пароль как раньше:
    # чужой токен у нас «доп.», а у той ноды — основной, и подсунь мы туда
    # свой пароль слота, устройство пришло бы к ней с кредом, которого она
    # для этого токена не ждёт. Слот живёт на ноде, которая его выдала.
    primary=$(awk -F: -v u="$user" '$1==u{print $2; exit}' "$SUBTOKENS_DB" 2>/dev/null)
    locals=$(sub_tokens_all "$user")
    while IFS= read -r tok; do
        [ -n "$tok" ] || continue
        tokpass=""
        [ -n "$content" ] && [ "$tok" != "$primary" ] \
            && printf '%s\n' "$locals" | grep -qxF "$tok" \
            && tokpass=$(sub_token_password "$user" "$tok")
        if [ -n "$tokpass" ]; then
            tokcontent=$(printf '%s\n' "$content" | awk -v u="$user" -v p="$tokpass" \
                '/^hysteria2:\/\// { sub(/^hysteria2:\/\/[^@]*@/, "hysteria2://" u ":" p "@") } {print}' | base64 -w0)
        else
            tokcontent=$(printf '%s\n' "$content" | grep -v '^$' | base64 -w0)
        fi
        printf '%s' "$tokcontent" > "$WEBROOT/sub/$tok"
    done <<< "$toks"
}

regen_subscriptions() {
    sub_enabled || return 0
    mkdir -p "$WEBROOT/sub"
    # {online} в шаблоне подписи/названия — обновляем онлайн ЭТОЙ ноды
    # (CACHED_ONLINE), его печём в свои ключи. Онлайн чужих нод приходит уже
    # испечённым в их манифестах (их обновляет cluster_online_sync).
    { _tag_needs_online || _title_needs_online; } && refresh_online

    local users
    users=$(sub_all_users)

    local user lp node ip port obfs sni content tok toks cst
    node=$(node_name)
    ip=$(link_host); port=$(get_port); obfs=$(get_obfs_pass); sni=$(get_sni)
    while IFS= read -r user; do
        [ -n "$user" ] || continue
        regen_user_subscription "$user" "$ip" "$port" "$obfs" "$sni"
    done <<< "$users"

    # Справочник паролей слотов — рядом с подписками: скрипт аутентификации
    # обязан принимать ровно то, что мы только что раздали.
    write_slotpass_db

    # Чистим ТОЛЬКО действительно осиротевшие токены: которых нет ни в нашей базе,
    # ни в кэше токенов пиров (т.е. юзер удалён везде). Иначе бы ломали чужие ссылки.
    if [ -d "$WEBROOT/sub" ]; then
        local valid bn
        valid=$(
            cut -d: -f2 "$SUBTOKENS_DB" 2>/dev/null
            [ -d "$PEERS_DIR" ] && awk -F: '{print $2}' "$PEERS_DIR"/*.subtokens 2>/dev/null
        )
        valid=$(printf '%s\n' "$valid" | grep -v '^$' | sort -u)
        for f in "$WEBROOT/sub"/*; do
            [ -f "$f" ] || continue
            bn=$(basename "$f")
            printf '%s\n' "$valid" | grep -qxF "$bn" || rm -f "$f"
        done
    fi
    secure_web_files

    # Название профиля с плейсхолдерами живёт в map «токен → название»: состав
    # токенов только что мог поменяться. Перечитываем Caddy ТОЛЬКО если сниппет
    # реально изменился — regen вызывается по крону, лишний reload ни к чему.
    if write_sub_titles && [ -f "$CADDYFILE" ]; then
        systemctl reload caddy 2>/dev/null || true
    fi
}

# Публикует токены подписки для остальных нод (за X-Cluster-Auth).
publish_subtokens() {
    sub_enabled || return 0
    mkdir -p "$WEBROOT/cluster"
    cp -f "$SUBTOKENS_DB" "$WEBROOT/cluster/subtokens" 2>/dev/null || true
    secure_web_files
}

# Токены НЕ объединяем: у каждой ноды свой стабильный токен для юзера, а подписка
# отдаётся под ВСЕМИ токенами (см. regen_subscriptions). Это гарантирует, что уже
# розданная ссылка не ломается, даже если на другой ноде юзер с тем же именем
# получил свой токен. Оставлено no-op для обратной совместимости вызовов.
merge_subtokens() { return 0; }

# Удобный хук: обновить манифест/токены и подписки после изменения пользователей.
sub_refresh() {
    sub_enabled || return 0
    # Синхронизируем серверы доп. протоколов из users.db (Xray hot/restart-on-change,
    # sing-box restart-on-change). Делаем ПЕРВЫМ, до публикации манифеста/подписки,
    # чтобы новые ключи начинали работать не позже, чем появятся в подписке.
    declare -F proto_sync_users >/dev/null 2>&1 && proto_sync_users
    publish_manifest
    publish_subtokens
    publish_stats
    regen_subscriptions
}

# Пишет сниппет с заголовком profile-title для /sub/* (его импортирует Caddyfile).
# Без плейсхолдеров название одно на всех — хватает статического заголовка.
# С плейсхолдерами название у каждого юзера своё: раскладываем «токен → название»
# в map по {path}; default — название с пустым {user} (на случай чужого токена).
# Печатает ничего; код возврата: 0 — файл изменился (нужен reload caddy), 1 — нет.
write_sub_titles() {
    local tmp; tmp=$(mktemp) || return 1
    mkdir -p "$(dirname "$CADDY_SUBTITLES")"
    if ! _title_has_ph; then
        printf '\theader profile-title "base64:%s"\n' \
            "$(printf '%s' "$(sub_title)" | base64 -w0 2>/dev/null)" > "$tmp"
    else
        # {online} в названии — тот же онлайн ЭТОЙ ноды, что и в подписи ключа.
        local user tok
        {
            printf '\tmap {path} {sub_title} {\n'
            while IFS= read -r user; do
                [ -n "$user" ] || continue
                while IFS= read -r tok; do
                    [ -n "$tok" ] || continue
                    printf '\t\t/sub/%s "base64:%s"\n' \
                        "$tok" "$(printf '%s' "$(render_title "$user")" | base64 -w0 2>/dev/null)"
                done <<< "$(sub_tokens_cluster "$user")"
            done <<< "$(sub_all_users)"
            printf '\t\tdefault "base64:%s"\n' \
                "$(printf '%s' "$(render_title '')" | base64 -w0 2>/dev/null)"
            printf '\t}\n'
            printf '\theader profile-title "{sub_title}"\n'
        } > "$tmp"
    fi
    if [ -f "$CADDY_SUBTITLES" ] && cmp -s "$tmp" "$CADDY_SUBTITLES"; then
        rm -f "$tmp"; return 1
    fi
    cat "$tmp" > "$CADDY_SUBTITLES"; chmod 644 "$CADDY_SUBTITLES" 2>/dev/null
    rm -f "$tmp"; return 0
}

