#!/bin/bash
# ================================================
# Мультипротокол: VLESS+REALITY+XHTTP, Shadowsocks-2022 и Trojan/WS (Xray-core),
# TUIC v5 (sing-box). Рядом с базовой Hysteria 2.
#
# Идея: один и тот же пользователь из users.db раздаётся несколькими
# протоколами; все они попадают в его подписку, и клиент (Throne/Hiddify)
# выбирает тот, что не задушен в его сети. Креды всех протоколов
# ДЕТЕРМИНИРОВАННО выводятся из (user, pass, узловой секрет) — отдельного
# состояния по юзерам нет, поэтому подписка/манифест/конфиги серверов всегда
# согласованы. Подробности — docs/guide/MULTIPROTOCOL.md.
# ================================================

# Файл параметров узла (отдельно от node.conf — там кластерные настройки).
PROTO_CONF="${PROTO_CONF:-$DATA_DIR/protocols.conf}"
# Узловой секрет для деривации кредов (не покидает ноду).
PROTO_SECRET_FILE="${PROTO_SECRET_FILE:-$DATA_DIR/proto.secret}"
# Рабочий каталог доп. протоколов: конфиги, сертификаты, слепки, бинарники.
PROTO_DIR="${PROTO_DIR:-$DATA_DIR/proto}"
XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
SINGBOX_BIN="${SINGBOX_BIN:-/usr/local/bin/sing-box}"
XRAY_CONFIG="$PROTO_DIR/xray.json"
SINGBOX_CONFIG="$PROTO_DIR/singbox.json"
XRAY_SERVICE="hy2-xray.service"
SINGBOX_SERVICE="hy2-singbox.service"
TUIC_CRT="$PROTO_DIR/tuic.crt"
TUIC_KEY="$PROTO_DIR/tuic.key"
# Локальный gRPC API Xray (StatsService/HandlerService) — только 127.0.0.1.
XRAY_API_PORT="${XRAY_API_PORT:-10085}"
# Окно свежести онлайн-IP Xray, сек: IP из statsonlineiplist старше него не
# считается устройством в сети (карту онлайна Xray сам не чистит, см. P-33).
# Крон онлайна ходит раз в минуту — 120 с даёт запас на один пропущенный тик.
XRAY_ONLINE_WINDOW_SEC="${XRAY_ONLINE_WINDOW_SEC:-120}"
# Clash API sing-box (онлайн/трафик TUIC) — только 127.0.0.1.
SINGBOX_API_PORT="${SINGBOX_API_PORT:-9090}"
SINGBOX_API_SECRET_FILE="$PROTO_DIR/singbox_api.secret"
# Слепки применённых конфигов: рестартуем сервис ТОЛЬКО когда состав/параметры
# реально изменились (иначе sub_refresh дёргал бы Xray/sing-box на каждый чих).
XRAY_APPLIED_HASH="$PROTO_DIR/.xray.hash"
SINGBOX_APPLIED_HASH="$PROTO_DIR/.singbox.hash"
# Состав юзеров и параметры узла, применённые к живому Xray. Нужны, чтобы
# отличить «добавился юзер» (можно на лету) от «сменились порты/ключи»
# (только рестарт). См. _proto_xray_hot_apply.
XRAY_APPLIED_USERS="$PROTO_DIR/.xray.users"
XRAY_STRUCT_HASH="$PROTO_DIR/.xray.struct"

# ---------------- Параметры узла (protocols.conf) ----------------
proto_get() { conf_get "$PROTO_CONF" "$1"; }
# Пишем одно поле без sed (значения могут содержать спецсимволы sed).
proto_set() {   # key value
    local key="$1" val="$2" tmp
    mkdir -p "$(dirname "$PROTO_CONF")"; touch "$PROTO_CONF"
    tmp=$(mktemp) || return 1
    grep -v "^${key}=" "$PROTO_CONF" > "$tmp" 2>/dev/null
    printf '%s=%s\n' "$key" "$val" >> "$tmp"
    cat "$tmp" > "$PROTO_CONF"; rm -f "$tmp"
    chmod 600 "$PROTO_CONF" 2>/dev/null
}
_proto_flag() { [ "$(proto_get "$1")" = "1" ]; }
proto_vless_enabled() { _proto_flag PROTO_VLESS_ENABLED; }
proto_ss_enabled()    { _proto_flag PROTO_SS_ENABLED; }
proto_tuic_enabled()  { _proto_flag PROTO_TUIC_ENABLED; }
proto_trojan_enabled(){ _proto_flag PROTO_TROJAN_ENABLED; }
# Включён ли хоть один доп. протокол (нужен ли Xray / sing-box вообще).
proto_any_enabled()   { proto_vless_enabled || proto_ss_enabled || proto_tuic_enabled || proto_trojan_enabled; }
proto_xray_needed()   { proto_vless_enabled || proto_ss_enabled || proto_trojan_enabled; }

proto_vless_port() { local p; p=$(proto_get PROTO_VLESS_PORT); echo "${p:-8443}"; }
proto_ss_port()    { local p; p=$(proto_get PROTO_SS_PORT);    echo "${p:-8388}"; }
proto_tuic_port()  { local p; p=$(proto_get PROTO_TUIC_PORT);  echo "${p:-2053}"; }
proto_trojan_port()    { local p; p=$(proto_get PROTO_TROJAN_PORT);    echo "${p:-8444}"; }
proto_trojan_ws_path() { local p; p=$(proto_get PROTO_TROJAN_WS_PATH); echo "${p:-/}"; }
proto_ss_method()  { local m; m=$(proto_get PROTO_SS_METHOD);  echo "${m:-2022-blake3-aes-128-gcm}"; }
proto_ss_keylen()  { case "$(proto_ss_method)" in *aes-256*) echo 32 ;; *) echo 16 ;; esac; }
# REALITY-цель («домен-прикрытие»): apple/icloud Xray прямо помечает как рисковые
# (могут привести к блокировке IP). Дефолт — нейтральный иностранный сайт с
# TLS1.3+H2+X25519, не блокируемый в РФ. dest и sni ДОЛЖНЫ указывать на один хост.
proto_reality_dest()    { local d; d=$(proto_get PROTO_REALITY_DEST);   echo "${d:-www.samsung.com:443}"; }
proto_reality_sni()     { local s; s=$(proto_get PROTO_REALITY_SNI);    echo "${s:-www.samsung.com}"; }
proto_reality_privkey() { proto_get PROTO_REALITY_PRIVKEY; }
proto_reality_pubkey()  { proto_get PROTO_REALITY_PUBKEY; }
proto_reality_shortid() { proto_get PROTO_REALITY_SHORTID; }
proto_xhttp_path()      { local p; p=$(proto_get PROTO_XHTTP_PATH);     echo "${p:-/}"; }

# ---------------- Секрет и деривация кредов ----------------
proto_secret() {
    if [ ! -s "$PROTO_SECRET_FILE" ]; then
        mkdir -p "$(dirname "$PROTO_SECRET_FILE")"
        pwgen -s 48 1 > "$PROTO_SECRET_FILE" 2>/dev/null || \
            head -c 36 /dev/urandom | base64 | tr -d '/+=' | head -c 48 > "$PROTO_SECRET_FILE"
        chmod 600 "$PROTO_SECRET_FILE"
    fi
    # read, а не cat: секрет читается на каждый ключ каждого юзера.
    local _s; IFS= read -r _s < "$PROTO_SECRET_FILE"; printf '%s\n' "$_s"
}

# Детерминированный UUIDv5-подобный из (secret|user|pass) — для VLESS и TUIC.
# Одинаков на любой ноде с тем же секретом → подписка и конфиг всегда сходятся.
proto_uuid() {   # user pass
    local h
    h=$(printf '%s' "$(proto_secret)|$1|$2" | sha1sum)
    h=${h:0:32}
    printf '%s-%s-5%s-8%s-%s' \
        "${h:0:8}" "${h:8:4}" "${h:13:3}" "${h:17:3}" "${h:20:12}"
}

# uPSK пользователя для Shadowsocks-2022 (base64 сырых байт sha256, обрезка до keylen).
proto_upsk() {   # user pass
    local kl; kl=$(proto_ss_keylen)
    printf '%s' "$(proto_secret)|ss|$1|$2" | openssl dgst -sha256 -binary | head -c "$kl" | base64
}
# iPSK инбаунда SS-2022 (общий ключ сервера) — один на ноду.
proto_ipsk() {
    local kl; kl=$(proto_ss_keylen)
    printf '%s' "$(proto_secret)|ss-ipsk" | openssl dgst -sha256 -binary | head -c "$kl" | base64
}

# ---------------- Установка движков ----------------
# Определяем архитектуру для имён релизов.
_proto_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo amd64 ;;
        aarch64|arm64) echo arm64 ;;
        armv7l) echo armv7 ;;
        *) echo amd64 ;;
    esac
}

# Сверка скачанного архива с суммой, которую издатель кладёт рядом с релизом.
# Не спасёт от подменённого целиком релиза (сумма оттуда же), но ловит битую
# закачку и подменённый на лету файл. Сумму не удалось получить — говорим и
# ставим дальше: иначе сетевая икота на GitHub оставит ноду без протоколов.
proto_verify_sha256() {   # файл  ожидаемая_sha256  что_ставим
    local file="$1" want="$2" what="$3" got
    if [ -z "$want" ]; then
        echo "  ⚠️  Контрольная сумма $what недоступна — ставлю без проверки"
        return 0
    fi
    got=$(sha256sum "$file" 2>/dev/null | cut -d' ' -f1)
    [ "$got" = "$want" ] && return 0
    echo "  ❌ Контрольная сумма $what не совпала (ждали $want, получили ${got:-—})"
    return 1
}

proto_install_xray() {
    command -v "$XRAY_BIN" >/dev/null 2>&1 && [ -x "$XRAY_BIN" ] && return 0
    echo "  📦 Устанавливаю Xray-core (VLESS/REALITY/XHTTP, Shadowsocks-2022)..."
    local arch zip tmp url ver sum
    case "$(_proto_arch)" in
        amd64) arch="64" ;; arm64) arch="arm64-v8a" ;; armv7) arch="arm32-v7a" ;; *) arch="64" ;;
    esac
    # XRAY_VERSION в protocols.conf (например «v25.1.1») фиксирует версию; пусто
    # или latest — как раньше, свежий релиз (и свежие исправления в нём).
    ver=$(proto_get XRAY_VERSION)
    if [ -n "$ver" ] && [ "$ver" != "latest" ]; then
        url="https://github.com/XTLS/Xray-core/releases/download/${ver}/Xray-linux-${arch}.zip"
    else
        url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${arch}.zip"
    fi
    tmp=$(mktemp -d); zip="$tmp/xray.zip"
    if ! curl -fsSL --max-time 120 -o "$zip" "$url"; then
        echo "  ❌ Не удалось скачать Xray ($url)"; rm -rf "$tmp"; return 1
    fi
    # Xray публикует рядом «<файл>.dgst» со строкой «SHA2-256= <хеш>».
    sum=$(curl -fsSL --max-time 30 "${url}.dgst" 2>/dev/null \
          | awk -F'= *' '/^SHA2-256/{print $2; exit}' | tr -d '[:space:]')
    proto_verify_sha256 "$zip" "$sum" "Xray" || { rm -rf "$tmp"; return 1; }
    command -v unzip >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq unzip; }
    unzip -o -q "$zip" -d "$tmp" || { echo "  ❌ Распаковка Xray не удалась"; rm -rf "$tmp"; return 1; }
    install -m 0755 "$tmp/xray" "$XRAY_BIN"
    mkdir -p /usr/local/share/xray
    [ -f "$tmp/geoip.dat" ]   && install -m 0644 "$tmp/geoip.dat"   /usr/local/share/xray/ 2>/dev/null
    [ -f "$tmp/geosite.dat" ] && install -m 0644 "$tmp/geosite.dat" /usr/local/share/xray/ 2>/dev/null
    rm -rf "$tmp"
    "$XRAY_BIN" version >/dev/null 2>&1
}

proto_install_singbox() {
    command -v "$SINGBOX_BIN" >/dev/null 2>&1 && [ -x "$SINGBOX_BIN" ] && return 0
    echo "  📦 Устанавливаю sing-box (TUIC v5)..."
    local arch tag ver tmp tgz url
    arch=$(_proto_arch)
    # SINGBOX_VERSION в protocols.conf («v1.13.14») фиксирует версию; пусто или
    # latest — спрашиваем у GitHub, как раньше. Контрольных сумм sing-box рядом
    # с релизом не публикует, сверять не с чем — проверяем только, что бинарник
    # распаковался и запускается (ниже).
    tag=$(proto_get SINGBOX_VERSION)
    [ "$tag" = "latest" ] && tag=""
    [ -n "$tag" ] || tag=$(curl -fsSL --max-time 30 https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null \
          | grep -oP '"tag_name":\s*"\K[^"]+' | head -1)
    [ -z "$tag" ] && { echo "  ❌ Не удалось узнать версию sing-box"; return 1; }
    ver="${tag#v}"
    url="https://github.com/SagerNet/sing-box/releases/download/${tag}/sing-box-${ver}-linux-${arch}.tar.gz"
    tmp=$(mktemp -d); tgz="$tmp/sb.tgz"
    if ! curl -fsSL --max-time 120 -o "$tgz" "$url"; then
        echo "  ❌ Не удалось скачать sing-box ($url)"; rm -rf "$tmp"; return 1
    fi
    tar -xzf "$tgz" -C "$tmp" || { echo "  ❌ Распаковка sing-box не удалась"; rm -rf "$tmp"; return 1; }
    local binpath; binpath=$(find "$tmp" -type f -name sing-box | head -1)
    [ -n "$binpath" ] || { echo "  ❌ Бинарник sing-box не найден в архиве"; rm -rf "$tmp"; return 1; }
    install -m 0755 "$binpath" "$SINGBOX_BIN"
    rm -rf "$tmp"
    "$SINGBOX_BIN" version >/dev/null 2>&1
}

# Ключи REALITY (x25519) — генерятся один раз, приватный в конфиг, публичный (pbk)
# и shortId уходят в подписку. Требует уже установленного xray.
proto_gen_reality_keys() {
    [ -n "$(proto_reality_pubkey)" ] && [ -n "$(proto_reality_privkey)" ] && return 0
    local out priv pub
    out=$("$XRAY_BIN" x25519 2>/dev/null) || { echo "  ❌ xray x25519 не сработал"; return 1; }
    # Метки менялись между версиями Xray. Приватный ключ — строго по слову
    # "private"; публичный — по "public", а если такой строки нет (новые версии
    # печатают его как "Password") — берём "password". Порядок важен, чтобы НЕ
    # перепутать ключи: сначала пробуем однозначные метки.
    priv=$(printf '%s\n' "$out" | grep -iE 'private' | head -1 | grep -oE '[A-Za-z0-9_-]{40,}')
    pub=$(printf '%s\n'  "$out" | grep -iE 'public'  | head -1 | grep -oE '[A-Za-z0-9_-]{40,}')
    [ -n "$pub" ] || pub=$(printf '%s\n' "$out" | grep -iE 'password' | head -1 | grep -oE '[A-Za-z0-9_-]{40,}')
    [ -n "$priv" ] && [ -n "$pub" ] || { echo "  ❌ Не разобрал ключи REALITY (вывод: $out)"; return 1; }
    proto_set PROTO_REALITY_PRIVKEY "$priv"
    proto_set PROTO_REALITY_PUBKEY  "$pub"
    [ -n "$(proto_reality_shortid)" ] || proto_set PROTO_REALITY_SHORTID "$(openssl rand -hex 8)"
}

# Запасной самоподписанный серт для TUIC и Trojan — на случай, когда публично
# доверенного взять негде (нода без домена, см. proto_sync_certs).
#
# subjectAltName ОБЯЗАТЕЛЕН. Серт только с CN современные TLS-стеки (все три
# движка и все клиенты на Go) отвергают ещё до проверки цепочки:
# «x509: certificate relies on legacy Common Name field, use SANs instead».
# Такой серт нельзя принять даже с insecure-флагом в тех клиентах, где флаг
# вообще есть. Поэтому серт без SAN перевыпускаем, а не оставляем как есть.
proto_gen_tuic_cert() {
    [ -s "$TUIC_CRT" ] && [ -s "$TUIC_KEY" ] && _proto_cert_has_san "$TUIC_CRT" && return 0
    mkdir -p "$PROTO_DIR"
    local cn san; cn=$(node_host 2>/dev/null); [ -n "$cn" ] || cn="$(get_ip)"
    # Домен идёт как DNS:, голый адрес — как IP: (в DNS: он не матчится).
    if [[ "$cn" =~ ^[0-9.]+$ ]] || [[ "$cn" == *:* ]]; then san="IP:${cn}"; else san="DNS:${cn}"; fi
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$TUIC_KEY" -out "$TUIC_CRT" -days 3650 -nodes \
        -subj "/CN=${cn}" -addext "subjectAltName=${san}" >/dev/null 2>&1 || {
            echo "  ❌ Не удалось выпустить серт для TUIC"; return 1; }
    chmod 600 "$TUIC_KEY"
    return 0
}

# ---------------- Публично доверенный TLS для Trojan/TUIC/Hysteria2 ----------
# Зачем. Trojan, TUIC и Hysteria2 стояли на самоподписанном серте, а ссылки шли
# с allowInsecure=1 / allow_insecure=1 / insecure=1. Это работает ровно до тех
# пор, пока клиент такой флаг уважает, а половина клиентов его уже НЕ уважает:
#   • Xray-core (на нём Happ) выпилил allowInsecure совсем — «The feature
#     "allowInsecure" has been removed and migrated to "pinnedPeerCertSha256"»;
#   • у Happ в hy2:// поддерживаются только obfs/obfs-password/sni, insecure нет.
# Итог у пользователя: в Happ пингуется и работает один VLESS (REALITY серт не
# проверяет), а Trojan/TUIC/HY2 молча отваливаются на TLS. В Hiddify (sing-box)
# те же ключи работают. Лечение одно — отдавать настоящий серт.
#
# Брать его неоткуда, кроме Caddy: он уже держит Let's Encrypt на домен ноды
# ради HTTPS-подписки. Копируем файлы (перевыпуск раз в 60 дней), а не
# подсовываем движкам путь в хранилище Caddy: каталог 0700 caddy:caddy, и
# движкам всё равно нужен рестарт — серты они перечитывают только при старте.
CADDY_CERT_ROOT="${CADDY_CERT_ROOT:-/var/lib/caddy/.local/share/caddy/certificates}"
# Метка «на протоколах стоит публично доверенный серт»: по ней ссылки строятся
# БЕЗ insecure-флагов и с SNI домена ноды. Файл, а не переменная, потому что
# ссылки собирает не только TUI, но и крон, и Web API.
TLS_TRUSTED_MARK="$PROTO_DIR/.tls.trusted"
proto_tls_trusted() { [ -f "$TLS_TRUSTED_MARK" ]; }

_proto_cert_has_san() {   # crt
    openssl x509 -in "$1" -noout -ext subjectAltName 2>/dev/null | grep -qE 'DNS:|IP Address:'
}

# Путь к живому публично доверенному серту Caddy на домен ноды (пусто — нет).
_proto_caddy_cert() {   # host
    local host="$1" crt subj iss
    [ -n "$host" ] || return 1
    for crt in "$CADDY_CERT_ROOT"/*/"$host"/"$host".crt; do
        [ -s "$crt" ] && [ -s "${crt%.crt}.key" ] || continue
        openssl x509 -in "$crt" -noout -checkend 0 >/dev/null 2>&1 || continue
        # Внутренний CA Caddy (когда ACME не удался) публично не доверен — его
        # серт самоподписан по цепочке, отличим по совпадению subject и issuer.
        subj=$(openssl x509 -in "$crt" -noout -subject 2>/dev/null | sed 's/^subject=//')
        iss=$(openssl  x509 -in "$crt" -noout -issuer  2>/dev/null | sed 's/^issuer=//')
        [ -n "$subj" ] && [ "$subj" = "$iss" ] && continue
        printf '%s' "$crt"; return 0
    done
    return 1
}

# Кладёт серт+ключ по назначению. Возврат 0 — файлы ИЗМЕНИЛИСЬ (нужен рестарт),
# 1 — уже те же самые либо не удалось.
_proto_install_cert() {   # src_crt src_key dst_crt dst_key owner
    local sc="$1" sk="$2" dc="$3" dk="$4" own="$5"
    [ -n "$dc" ] && [ -n "$dk" ] || return 1
    cmp -s "$sc" "$dc" && cmp -s "$sk" "$dk" && return 1
    install -m 0644 -o "${own%%:*}" -g "${own##*:}" "$sc" "$dc" 2>/dev/null || return 1
    install -m 0600 -o "${own%%:*}" -g "${own##*:}" "$sk" "$dk" 2>/dev/null || return 1
    return 0
}

# Пути серта Hysteria — из её же конфига, чтобы не завести второй источник правды.
_proto_hy_cert() { grep -oP '^\s*cert:\s*\K\S+' "$CONFIG" 2>/dev/null | head -1; }
_proto_hy_key()  { grep -oP '^\s*key:\s*\K\S+'  "$CONFIG" 2>/dev/null | head -1; }

# Разложить серт Caddy по движкам и перезапустить только те, чей файл изменился.
# Идемпотентно, дёшево (две cmp на протокол) — зовётся из bootstrap и из крона.
proto_sync_certs() {
    local host crt key hyc hyk
    host=$(node_host 2>/dev/null)
    crt=$(_proto_caddy_cert "$host") || { rm -f "$TLS_TRUSTED_MARK"; return 0; }
    key="${crt%.crt}.key"
    if _proto_install_cert "$crt" "$key" "$TUIC_CRT" "$TUIC_KEY" root:root; then
        # Рестарт рвёт живые сессии, но случается это раз в перевыпуск (~60 дней).
        proto_trojan_enabled && systemctl restart "$XRAY_SERVICE" >/dev/null 2>&1
        proto_tuic_enabled   && systemctl restart "$SINGBOX_SERVICE" >/dev/null 2>&1
    fi
    hyc=$(_proto_hy_cert); hyk=$(_proto_hy_key)
    if [ -n "$hyc" ] && [ -n "$hyk" ] \
        && _proto_install_cert "$crt" "$key" "$hyc" "$hyk" hysteria:hysteria; then
        systemctl restart "$SERVICE" >/dev/null 2>&1   # серты Hysteria читает только на старте
    fi
    : > "$TLS_TRUSTED_MARK"
    return 0
}

# ---------------- Генерация клиентских записей для конфигов ----------------
# Демо-профили (lib/demo.sh) в доп. протоколы НЕ попадают: демо живёт на одной
# Hysteria2, чья аутентификация читает users.db на каждом подключении — выдача
# мгновенна и никого не задевает. Любая правка конфигов Xray/sing-box означала бы
# их РЕСТАРТ на каждое нажатие гостевой кнопки (рвутся живые сессии платящих),
# а TUIC демо противопоказан и сам по себе — там нет пер-юзерного учёта трафика,
# то есть квоту не проверить.
_proto_skip_user() { declare -F demo_is >/dev/null 2>&1 && demo_is "$1"; }
# VLESS-клиенты Xray: [{ "id":UUID, "email":user, "flow":"xtls-rprx-vision" }, ...]
# Vision требует raw-TCP инбаунд (network:tcp) — с XHTTP/WS flow невалиден и Xray
# отвергнет клиента. flow ДОЛЖЕН совпадать в инбаунде и в share-ссылке.
_proto_xray_vless_clients() {
    local u p first=1
    while IFS=: read -r u p; do
        [ -n "$u" ] || continue
        _proto_skip_user "$u" && continue
        [ "$first" = 1 ] || printf ','
        printf '{"id":"%s","email":"%s","flow":"xtls-rprx-vision"}' "$(proto_uuid "$u" "$p")" "$u"
        first=0
    done < "$USERS_DB"
}
# SS-2022 клиенты Xray: [{ "password":uPSK, "email":user }, ...]
_proto_xray_ss_clients() {
    local u p first=1
    while IFS=: read -r u p; do
        [ -n "$u" ] || continue
        _proto_skip_user "$u" && continue
        [ "$first" = 1 ] || printf ','
        printf '{"password":"%s","email":"%s"}' "$(proto_upsk "$u" "$p")" "$u"
        first=0
    done < "$USERS_DB"
}
# Trojan-клиенты Xray: [{ "password":UUID, "email":user }, ...] — пароль
# детерминированный (proto_uuid), как у VLESS/TUIC.
_proto_xray_trojan_clients() {
    local u p first=1
    while IFS=: read -r u p; do
        [ -n "$u" ] || continue
        _proto_skip_user "$u" && continue
        [ "$first" = 1 ] || printf ','
        printf '{"password":"%s","email":"%s"}' "$(proto_uuid "$u" "$p")" "$u"
        first=0
    done < "$USERS_DB"
}
# TUIC-юзеры sing-box: [{ "name":user, "uuid":UUID, "password":pass }, ...]
_proto_singbox_tuic_users() {
    local u p first=1
    while IFS=: read -r u p; do
        [ -n "$u" ] || continue
        _proto_skip_user "$u" && continue
        [ "$first" = 1 ] || printf ','
        printf '{"name":"%s","uuid":"%s","password":"%s"}' "$u" "$(proto_uuid "$u" "$p")" "$p"
        first=0
    done < "$USERS_DB"
}

# ---------------- Генерация конфигов ----------------
proto_write_xray_config() {
    proto_xray_needed || return 0
    mkdir -p "$PROTO_DIR"
    local inbounds="" comma=""
    if proto_vless_enabled; then
        # VLESS + REALITY поверх raw TCP с XTLS-Vision (flow задаётся на клиенте).
        # Vision splice'ит uplink напрямую в TCP → без отдельного стрима выгрузки
        # (как было у XHTTP, где upload шёл POST'ом и мог вставать в 0). Это и
        # самый совместимый (Happ/Hiddify/v2rayNG) и самый устойчивый к DPI РФ.
        inbounds+=$(printf '{"listen":"0.0.0.0","port":%s,"protocol":"vless","tag":"vless-in","settings":{"clients":[%s],"decryption":"none"},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"show":false,"dest":"%s","xver":0,"serverNames":["%s"],"privateKey":"%s","shortIds":["%s"]}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"]}}' \
            "$(proto_vless_port)" "$(_proto_xray_vless_clients)" "$(proto_reality_dest)" \
            "$(proto_reality_sni)" "$(proto_reality_privkey)" "$(proto_reality_shortid)")
        comma=","
    fi
    if proto_ss_enabled; then
        inbounds+="${comma}"
        inbounds+=$(printf '{"listen":"0.0.0.0","port":%s,"protocol":"shadowsocks","tag":"ss-in","settings":{"method":"%s","password":"%s","clients":[%s],"network":"tcp,udp"}}' \
            "$(proto_ss_port)" "$(proto_ss_method)" "$(proto_ipsk)" "$(_proto_xray_ss_clients)")
        comma=","
    fi
    if proto_trojan_enabled; then
        # TLS на том же самоподписанном серте, что и TUIC (клиент идёт с allowInsecure=1).
        proto_gen_tuic_cert || return 1
        inbounds+="${comma}"
        inbounds+=$(printf '{"listen":"0.0.0.0","port":%s,"protocol":"trojan","tag":"trojan-in","settings":{"clients":[%s]},"streamSettings":{"network":"ws","security":"tls","tlsSettings":{"certificates":[{"certificateFile":"%s","keyFile":"%s"}]},"wsSettings":{"path":"%s"}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"]}}' \
            "$(proto_trojan_port)" "$(_proto_xray_trojan_clients)" "$TUIC_CRT" "$TUIC_KEY" "$(proto_trojan_ws_path)")
        comma=","
    fi
    # Локальный gRPC API для статистики и hot-add (только 127.0.0.1).
    cat > "$XRAY_CONFIG" <<EOF
{
  "log": { "loglevel": "warning" },
  "api": { "tag": "api", "services": ["HandlerService", "StatsService"] },
  "stats": {},
  "policy": {
    "levels": { "0": { "statsUserUplink": true, "statsUserDownlink": true, "statsUserOnline": true } },
    "system": { "statsInboundUplink": true, "statsInboundDownlink": true }
  },
  "inbounds": [
    ${inbounds},
    { "listen": "127.0.0.1", "port": ${XRAY_API_PORT}, "protocol": "dokodemo-door",
      "settings": { "address": "127.0.0.1" }, "tag": "api" }
  ],
  "outbounds": [ { "protocol": "freedom", "tag": "direct" } ],
  "routing": { "rules": [ { "type": "field", "inboundTag": ["api"], "outboundTag": "api" } ] }
}
EOF
    chmod 600 "$XRAY_CONFIG" 2>/dev/null
}

proto_write_singbox_config() {
    proto_tuic_enabled || return 0
    mkdir -p "$PROTO_DIR"
    proto_gen_tuic_cert || return 1
    local secret; secret=$(cat "$SINGBOX_API_SECRET_FILE" 2>/dev/null)
    [ -n "$secret" ] || { secret=$(pwgen -s 24 1); echo "$secret" > "$SINGBOX_API_SECRET_FILE"; chmod 600 "$SINGBOX_API_SECRET_FILE"; }
    cat > "$SINGBOX_CONFIG" <<EOF
{
  "log": { "level": "error" },
  "inbounds": [
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": $(proto_tuic_port),
      "users": [ $(_proto_singbox_tuic_users) ],
      "congestion_control": "bbr",
      "zero_rtt_handshake": false,
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "${TUIC_CRT}",
        "key_path": "${TUIC_KEY}"
      }
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ],
  "experimental": {
    "clash_api": { "external_controller": "127.0.0.1:${SINGBOX_API_PORT}", "secret": "${secret}" }
  }
}
EOF
    chmod 600 "$SINGBOX_CONFIG" 2>/dev/null
}

# ---------------- systemd-юниты ----------------
proto_write_units() {
    if proto_xray_needed; then
        cat > "/etc/systemd/system/${XRAY_SERVICE}" <<EOF
[Unit]
Description=hy2-manager Xray (VLESS/REALITY/XHTTP, Shadowsocks-2022, Trojan/WS)
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=${XRAY_BIN} run -c ${XRAY_CONFIG}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    fi
    if proto_tuic_enabled; then
        cat > "/etc/systemd/system/${SINGBOX_SERVICE}" <<EOF
[Unit]
Description=hy2-manager sing-box (TUIC v5)
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=${SINGBOX_BIN} run -c ${SINGBOX_CONFIG}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    fi
    systemctl daemon-reload 2>/dev/null
}

# ---------------- Firewall ----------------
ensure_proto_ports_open() {
    proto_any_enabled || return 0
    local tcp_ports=() udp_ports=()
    proto_vless_enabled  && tcp_ports+=("$(proto_vless_port)")
    proto_ss_enabled     && tcp_ports+=("$(proto_ss_port)")
    proto_trojan_enabled && tcp_ports+=("$(proto_trojan_port)")
    proto_tuic_enabled   && udp_ports+=("$(proto_tuic_port)")
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi active; then
        local p
        for p in "${tcp_ports[@]}"; do ufw allow "$p/tcp" >/dev/null 2>&1; done
        for p in "${udp_ports[@]}"; do ufw allow "$p/udp" >/dev/null 2>&1; done
    elif command -v iptables >/dev/null 2>&1; then
        local p
        for p in "${tcp_ports[@]}"; do
            iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || \
                iptables -I INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null
        done
        for p in "${udp_ports[@]}"; do
            iptables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || \
                iptables -I INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null
        done
    fi
    return 0
}

# ---------------- Применение: рестарт ТОЛЬКО при изменении ----------------
# Конфиги перегенерируются из users.db на каждый sub_refresh, но перезапуск
# сервиса делаем лишь когда содержимое реально поменялось (состав юзеров или
# параметры узла). Так рутинные вызовы sub_refresh (смена токена и т.п.) не рвут
# активные сессии VLESS/SS/TUIC. Hysteria остаётся горячей всегда.
_proto_apply_service() {   # service config_file hash_file
    local svc="$1" cfg="$2" hf="$3" newh oldh
    [ -s "$cfg" ] || return 0
    newh=$(sha256sum "$cfg" 2>/dev/null | cut -d' ' -f1)
    oldh=$(cat "$hf" 2>/dev/null)
    systemctl enable "$svc" >/dev/null 2>&1
    if [ "$newh" != "$oldh" ] || ! systemctl is-active --quiet "$svc" 2>/dev/null; then
        systemctl restart "$svc" >/dev/null 2>&1
        echo "$newh" > "$hf"
    fi
}

# ---------------- Применение состава TUIC: рестарт с отсрочкой ----------------
# У sing-box нет управления юзерами на лету: состав задан в конфиге и меняется
# только рестартом, а рестарт рвёт TUIC-сессии ВСЕХ юзеров ноды (P-01). Убрать
# рестарт нечем — но можно перестать делать его немедленно и по каждому поводу:
#   • сервис лежит → применяем сразу, рвать нечего;
#   • нет активных TUIC-соединений → применяем сразу (обычный случай: соединения
#     короткие, список пустеет сам);
#   • иначе ждём, но не дольше TUIC_APPLY_MAX_DELAY_SEC.
# Конфиг всё это время уже лежит на диске, повторную попытку делает минутный крон
# (--online-sync). Десять юзеров подряд дают ОДИН рестарт вместо десяти, а
# провижининг нового юзера не ждёт рестарта sing-box.
# Цена отсрочки: TUIC у нового юзера заработает не сразу (остальные протоколы —
# сразу). Простаивающую QUIC-сессию мы всё же можем оборвать (в списке соединений
# её не видно) — клиент переподключается сам, данных в полёте нет.
TUIC_APPLY_MAX_DELAY_SEC="${TUIC_APPLY_MAX_DELAY_SEC:-600}"
SINGBOX_PENDING_TS="$PROTO_DIR/.singbox.pending"
SINGBOX_STRUCT_HASH="$PROTO_DIR/.singbox.struct"

# Хэш конфига БЕЗ списков юзеров: от нового юзера не меняется, от смены порта,
# сертификата или состава инбаундов — меняется. Отсрочка про состав; параметры
# узла админ меняет руками и ждёт результата сейчас, а не через десять минут.
_proto_singbox_struct_hash() {
    jq -Sc 'del(.inbounds[].users)' "$SINGBOX_CONFIG" 2>/dev/null \
        | sha256sum 2>/dev/null | cut -d' ' -f1
}

_proto_tuic_conn_count() {
    local secret n
    secret=$(cat "$SINGBOX_API_SECRET_FILE" 2>/dev/null)
    n=$(curl -s --max-time 3 -H "Authorization: Bearer ${secret}" \
        "http://127.0.0.1:${SINGBOX_API_PORT}/connections" 2>/dev/null \
        | jq '(.connections // []) | length' 2>/dev/null)
    [[ "$n" =~ ^[0-9]+$ ]] && echo "$n" || echo 0
}

proto_tuic_apply() {
    proto_tuic_enabled || return 0
    [ -s "$SINGBOX_CONFIG" ] || return 0
    local newh oldh now since sh osh
    newh=$(sha256sum "$SINGBOX_CONFIG" 2>/dev/null | cut -d' ' -f1)
    oldh=$(cat "$SINGBOX_APPLIED_HASH" 2>/dev/null)
    systemctl enable "$SINGBOX_SERVICE" >/dev/null 2>&1
    sh=$(_proto_singbox_struct_hash)
    if [ "$newh" = "$oldh" ] && systemctl is-active --quiet "$SINGBOX_SERVICE" 2>/dev/null; then
        rm -f "$SINGBOX_PENDING_TS"
        [ -n "$sh" ] && echo "$sh" > "$SINGBOX_STRUCT_HASH"
        return 0
    fi
    now=$(date +%s)
    since=$(cat "$SINGBOX_PENDING_TS" 2>/dev/null)
    if ! [[ "$since" =~ ^[0-9]+$ ]]; then
        since=$now
        echo "$now" > "$SINGBOX_PENDING_TS"
    fi
    osh=$(cat "$SINGBOX_STRUCT_HASH" 2>/dev/null)
    if systemctl is-active --quiet "$SINGBOX_SERVICE" 2>/dev/null \
       && [ -n "$sh" ] && [ -n "$osh" ] && [ "$sh" = "$osh" ] \
       && [ "$(( now - since ))" -lt "$TUIC_APPLY_MAX_DELAY_SEC" ] \
       && [ "$(_proto_tuic_conn_count)" -gt 0 ]; then
        return 0                      # сменился только состав, кто-то в сети — ждём
    fi
    systemctl restart "$SINGBOX_SERVICE" >/dev/null 2>&1
    echo "$newh" > "$SINGBOX_APPLIED_HASH"
    [ -n "$sh" ] && echo "$sh" > "$SINGBOX_STRUCT_HASH"
    rm -f "$SINGBOX_PENDING_TS"
}

# ---------------- Горячее применение состава юзеров Xray (adu/rmu) ----------------
# Новый юзер меняет конфиг → меняется хэш → рестарт → рвутся сессии ВСЕХ юзеров
# ноды. Xray умеет добавлять и снимать юзеров по gRPC на лету, поэтому рестарт
# нужен только когда изменились ПАРАМЕТРЫ узла (порты, ключи REALITY, состав
# инбаундов), а не состав юзеров.

# Хэш конфига без списков клиентов — от добавления юзера не меняется.
_proto_xray_struct_hash() {
    jq -Sc 'del(.inbounds[].settings.clients)' "$XRAY_CONFIG" 2>/dev/null \
        | sha256sum 2>/dev/null | cut -d' ' -f1
}

# Желаемый состав: «user<TAB>uuid<TAB>upsk», отсортированный. Смена пароля меняет
# строку целиком, поэтому видна как удаление + добавление. LC_ALL=C — чтобы
# порядок не зависел от локали вызывающего (TUI и крон могут отличаться), иначе
# comm сравнит несравнимое.
_proto_xray_desired_users() {
    local u p
    while IFS=: read -r u p; do
        [ -n "$u" ] || continue
        _proto_skip_user "$u" && continue
        printf '%s\t%s\t%s\n' "$u" "$(proto_uuid "$u" "$p")" "$(proto_upsk "$u" "$p")"
    done < "$USERS_DB" | LC_ALL=C sort
}

# Теги инбаундов Xray, включённых на этой ноде.
_proto_xray_tags() {
    proto_vless_enabled  && echo vless-in
    proto_ss_enabled     && echo ss-in
    proto_trojan_enabled && echo trojan-in
    return 0
}

# Заготовка для `xray api adu` с одним юзером во всех инбаундах. adu разбирает
# файл как ПОЛНЫЙ конфиг (без порта — «Listen on AnyIP but no Port(s) set»),
# поэтому берём живой конфиг и подменяем в нём только списки клиентов: порты,
# method/uPSK и streamSettings тогда заведомо валидны. Инбаунд api отсеивается
# сам — у него нет clients.
_proto_xray_adu_json() {   # user uuid upsk
    jq -c --arg u "$1" --arg id "$2" --arg psk "$3" \
        '{inbounds:[.inbounds[]|select(.settings.clients!=null)
          |.settings.clients=(
              if   .protocol=="vless"       then [{id:$id,email:$u,flow:"xtls-rprx-vision"}]
              elif .protocol=="shadowsocks" then [{password:$psk,email:$u}]
              else                               [{password:$id,email:$u}] end)]}' \
        "$XRAY_CONFIG" 2>/dev/null
}

_proto_xray_save_state() {
    ( umask 077
      _proto_xray_struct_hash   > "$XRAY_STRUCT_HASH"
      _proto_xray_desired_users > "$XRAY_APPLIED_USERS" ) 2>/dev/null
}

# Применить изменившийся состав юзеров к живому Xray без рестарта.
# 0 — применено (рестарт не нужен), 1 — нужен обычный рестарт.
# При любом сбое возвращаем 1: конфиг на диске уже правильный, рестарт всё
# приведёт в порядок, поэтому частично применённая дельта не опасна.
_proto_xray_hot_apply() {
    [ -x "$XRAY_BIN" ] && command -v jq >/dev/null 2>&1 || return 1
    systemctl is-active --quiet "$XRAY_SERVICE" 2>/dev/null || return 1
    [ -f "$XRAY_APPLIED_USERS" ] || return 1          # первый запуск — рестарт
    local sh; sh=$(_proto_xray_struct_hash)
    [ -n "$sh" ] && [ "$sh" = "$(cat "$XRAY_STRUCT_HASH" 2>/dev/null)" ] || return 1

    local tmp="$PROTO_DIR/.xray.users.$BASHPID" j="$PROTO_DIR/.xray.adu.$BASHPID"
    ( umask 077; _proto_xray_desired_users > "$tmp" )
    local gone new t u id psk
    gone=$(comm -23 "$XRAY_APPLIED_USERS" "$tmp" | cut -f1 | LC_ALL=C sort -u)
    new=$(comm -13 "$XRAY_APPLIED_USERS" "$tmp")

    # Снятие: юзера могло не быть в инбаунде (rmu вернёт ошибку) — это не сбой.
    while IFS= read -r u; do
        [ -n "$u" ] || continue
        while IFS= read -r t; do
            "$XRAY_BIN" api rmu --server="127.0.0.1:${XRAY_API_PORT}" \
                -tag="$t" "$u" >/dev/null 2>&1
        done < <(_proto_xray_tags)
    done <<< "$gone"

    # Добавление: сбой здесь означает юзера без доступа — откатываемся к рестарту.
    while IFS=$'\t' read -r u id psk; do
        [ -n "$u" ] || continue
        ( umask 077; _proto_xray_adu_json "$u" "$id" "$psk" > "$j" ) \
            && [ -s "$j" ] \
            && "$XRAY_BIN" api adu --server="127.0.0.1:${XRAY_API_PORT}" "$j" >/dev/null 2>&1 \
            || { rm -f "$tmp" "$j"; return 1; }
    done <<< "$new"

    rm -f "$j"
    mv "$tmp" "$XRAY_APPLIED_USERS" 2>/dev/null
    # Хэш конфига теперь считается применённым — иначе следующий
    # _proto_apply_service увидит расхождение и всё-таки рестартанёт.
    sha256sum "$XRAY_CONFIG" 2>/dev/null | cut -d' ' -f1 > "$XRAY_APPLIED_HASH"
    return 0
}

# Пересобрать конфиги из users.db и применить. Вызывается из sub_refresh.
proto_sync_users() {
    proto_any_enabled || return 0
    if proto_xray_needed; then
        proto_write_xray_config
        if ! _proto_xray_hot_apply; then
            _proto_apply_service "$XRAY_SERVICE" "$XRAY_CONFIG" "$XRAY_APPLIED_HASH"
            _proto_xray_save_state
        fi
    fi
    if proto_tuic_enabled; then
        proto_write_singbox_config
        proto_tuic_apply       # рестарт с отсрочкой: не рвём чужие сессии из-за одного юзера
    fi
}

# ---------------- Построение ссылок для подписки ----------------
# proto_user_uris user pass [ip] [tag]
# Печатает по одной share-ссылке на КАЖДЫЙ включённый доп. протокол (без хвостовой
# пустой строки лишней — вызывающий добавляет их в общий список к hysteria2://).
proto_build_vless() {   # user pass ip tag
    local user="$1" pass="$2" ip="$3" tag="$4"
    tag=${tag//\{protocol\}/VLESS}   # {protocol} — метка этого ключа
    # VLESS-Vision-REALITY поверх TCP. flow ОБЯЗАН совпадать с инбаундом
    # (xtls-rprx-vision), иначе uplink рвётся/встаёт в 0. fp=firefox — uTLS-
    # отпечаток ClientHello (маскировка под браузер); spx — spiderX (дефолт «/»).
    printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&pbk=%s&sid=%s&fp=firefox&type=tcp&spx=%%2F#%s' \
        "$(proto_uuid "$user" "$pass")" "$ip" "$(proto_vless_port)" \
        "$(proto_reality_sni)" "$(proto_reality_pubkey)" "$(proto_reality_shortid)" \
        "$(_proto_urlenc "$tag")"
}
proto_build_ss() {   # user pass ip tag
    local user="$1" pass="$2" ip="$3" tag="$4" userinfo
    tag=${tag//\{protocol\}/SS22}   # {protocol} — метка этого ключа
    # SIP002: userinfo = base64url(method:password). В мультипользовательском
    # SS-2022 (EIH) инбаунд имеет общий iPSK + личный uPSK, и клиент ОБЯЗАН
    # слать оба ключа как "iPSK:uPSK" — иначе сервер не сматчит юзера и рвёт
    # соединение (таймаут на клиенте). Поэтому password = iPSK:uPSK.
    userinfo=$(printf '%s:%s:%s' "$(proto_ss_method)" "$(proto_ipsk)" "$(proto_upsk "$user" "$pass")" | base64 -w0 | tr '+/' '-_' | tr -d '=')
    printf 'ss://%s@%s:%s#%s' "$userinfo" "$ip" "$(proto_ss_port)" "$(_proto_urlenc "$tag")"
}
proto_build_tuic() {   # user pass ip tag
    local user="$1" pass="$2" ip="$3" tag="$4"
    tag=${tag//\{protocol\}/TUIC}   # {protocol} — метка этого ключа
    # allow_insecure только на запасном самоподписанном серте: с настоящим он
    # лишний, а часть клиентов на такой ключ вообще не идёт (см. proto_sync_certs).
    printf 'tuic://%s:%s@%s:%s?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=%s%s#%s' \
        "$(proto_uuid "$user" "$pass")" "$(_proto_urlenc "$pass")" "$ip" "$(proto_tuic_port)" \
        "$(proto_reality_sni_or_host)" "$(proto_tls_trusted || echo '&allow_insecure=1')" \
        "$(_proto_urlenc "$tag")"
}

proto_build_trojan() {   # user pass ip tag
    local user="$1" pass="$2" ip="$3" tag="$4"
    tag=${tag//\{protocol\}/TROJAN}   # {protocol} — метка этого ключа
    # allowInsecure в Xray-core УДАЛЁН (мигрировал в pinnedPeerCertSha256), так
    # что на самоподписанном серте Trojan для Xray-клиентов нерабочий в принципе.
    printf 'trojan://%s@%s:%s?security=tls&type=ws&path=%s&sni=%s%s#%s' \
        "$(proto_uuid "$user" "$pass")" "$ip" "$(proto_trojan_port)" \
        "$(_proto_urlenc "$(proto_trojan_ws_path)")" "$(proto_reality_sni_or_host)" \
        "$(proto_tls_trusted || echo '&allowInsecure=1')" \
        "$(_proto_urlenc "$tag")"
}

# SNI для TUIC: серт самоподписанный на CN=домен/ip, поэтому в ссылку кладём хост.
proto_reality_sni_or_host() { node_host 2>/dev/null || get_ip; }

# Минимальный urlencode для значений в query/fragment (пробелы, эмодзи, /, #, &).
# LC_ALL=C — чтобы итерировать по БАЙТАМ: многобайтовые символы (флаги-эмодзи,
# кириллица) кодируются побайтно как %XX, иначе клиент увидит битую подпись.
_proto_urlenc() {
    local s="$1" out="" c i
    local LC_ALL=C LC_CTYPE=C
    for (( i=0; i<${#s}; i++ )); do
        c="${s:$i:1}"
        case "$c" in
            [a-zA-Z0-9._~-]) out+="$c" ;;
            # printf -v, а не $(printf ...): подстановка форкала подоболочку НА
            # КАЖДЫЙ байт подписи. Подпись с кириллицей и эмодзи — это 30-40
            # байт, четыре протокола, полтора десятка юзеров: тысячи форков за
            # один прогон regen_subscriptions.
            *) printf -v c '%%%02X' "'$c"; out+="$c" ;;
        esac
    done
    printf '%s' "$out"
}

# Все доп-URI для юзера (по строке на протокол). ip — адрес ноды в ссылке,
# tag — подпись (#...), как у build_user_link.
proto_user_uris() {   # user pass ip tag
    # ${4:-$1}, не $user: RHS local-присваиваний разворачивается ДО того, как
    # local создаст user, и дефолтный тег получался пустым.
    local user="$1" pass="$2" ip="${3:-$(link_host)}" tag="${4:-$1}"
    proto_any_enabled || return 0
    proto_vless_enabled  && { proto_build_vless  "$user" "$pass" "$ip" "$tag"; echo; }
    proto_ss_enabled     && { proto_build_ss     "$user" "$pass" "$ip" "$tag"; echo; }
    proto_trojan_enabled && { proto_build_trojan "$user" "$pass" "$ip" "$tag"; echo; }
    proto_tuic_enabled   && { proto_build_tuic   "$user" "$pass" "$ip" "$tag"; echo; }
    return 0
}

# ---------------- Оркестрация: включение/выключение/bootstrap ----------------
# Готовит инфраструктуру под то, что СЕЙЧАС включено в protocols.conf: ставит
# нужные бинарники, генерит ключи/серт, пишет конфиги+юниты, открывает порты,
# синхронизирует юзеров. Идемпотентно — безопасно звать при каждом старте.
proto_bootstrap() {
    proto_any_enabled || return 0
    if proto_xray_needed; then
        proto_install_xray || return 1
        proto_gen_reality_keys || return 1
    fi
    if proto_tuic_enabled; then
        proto_install_singbox || return 1
        proto_gen_tuic_cert || return 1
    fi
    proto_write_units
    ensure_proto_ports_open
    proto_sync_users
    proto_sync_certs   # после sync_users: рестарт движка уже с готовым конфигом
}

# Включить протокол: vless|ss|tuic. Ставит движок, пишет дефолты, поднимает.
proto_enable_protocol() {   # name
    case "$1" in
        vless)
            proto_set PROTO_VLESS_ENABLED 1
            [ -n "$(proto_get PROTO_VLESS_PORT)" ] || proto_set PROTO_VLESS_PORT 8443
            [ -n "$(proto_get PROTO_XHTTP_PATH)" ] || proto_set PROTO_XHTTP_PATH /
            [ -n "$(proto_get PROTO_REALITY_DEST)" ] || proto_set PROTO_REALITY_DEST www.microsoft.com:443
            [ -n "$(proto_get PROTO_REALITY_SNI)" ]  || proto_set PROTO_REALITY_SNI www.microsoft.com
            ;;
        ss)
            proto_set PROTO_SS_ENABLED 1
            [ -n "$(proto_get PROTO_SS_PORT)" ]   || proto_set PROTO_SS_PORT 8388
            [ -n "$(proto_get PROTO_SS_METHOD)" ] || proto_set PROTO_SS_METHOD 2022-blake3-aes-128-gcm
            ;;
        tuic)
            proto_set PROTO_TUIC_ENABLED 1
            [ -n "$(proto_get PROTO_TUIC_PORT)" ] || proto_set PROTO_TUIC_PORT 2053
            ;;
        trojan)
            proto_set PROTO_TROJAN_ENABLED 1
            [ -n "$(proto_get PROTO_TROJAN_PORT)" ]    || proto_set PROTO_TROJAN_PORT 8444
            [ -n "$(proto_get PROTO_TROJAN_WS_PATH)" ] || proto_set PROTO_TROJAN_WS_PATH /
            ;;
        *) return 1 ;;
    esac
    proto_bootstrap
}

# Выключить протокол: гасит сервис, если после этого движок больше не нужен.
proto_disable_protocol() {   # name
    case "$1" in
        vless)  proto_set PROTO_VLESS_ENABLED 0 ;;
        ss)     proto_set PROTO_SS_ENABLED 0 ;;
        tuic)   proto_set PROTO_TUIC_ENABLED 0 ;;
        trojan) proto_set PROTO_TROJAN_ENABLED 0 ;;
        *) return 1 ;;
    esac
    if ! proto_xray_needed; then
        systemctl disable --now "$XRAY_SERVICE" >/dev/null 2>&1
        rm -f "$XRAY_APPLIED_HASH"
    fi
    if ! proto_tuic_enabled; then
        systemctl disable --now "$SINGBOX_SERVICE" >/dev/null 2>&1
        rm -f "$SINGBOX_APPLIED_HASH"
    fi
    # Оставшиеся протоколы (если есть) переприменяем — состав портов мог поменяться.
    proto_any_enabled && proto_bootstrap
    return 0
}

# ---------------- Учёт трафика доп. протоколов ----------------
# Отдельного сборщика Xray с `-reset` больше НЕТ: обнулять счётчики нельзя, их
# читают ещё минутная активность и 5-секундный спидометр, и любой сброс крал у
# них интервал (P-37). Кумулятив Xray отдаёт `proto_xray_split_lines` (без
# reset), а дельту к базе считает collect_traffic (lib/traffic.sh).

# Адреса, за которыми стоит РОВНО ОДИН юзер: «ip<TAB>user». Источники — ips.dat,
# authmap.dat и такие же файлы пиров. Адрес, с которого за окно ходил не один
# юзер (общий CGNAT, семья, офис), НЕ попадает в вывод вовсе: на нём атрибуция
# по IP означала бы записать чужие байты в чужую квоту. Недосчитать безопаснее.
TUIC_IP_OWNER_WINDOW_DAYS="${TUIC_IP_OWNER_WINDOW_DAYS:-7}"
_proto_ip_sole_owner_lines() {
    local cut=$(( $(date +%s) - TUIC_IP_OWNER_WINDOW_DAYS * 86400 ))
    {
        cat "$IPS_FILE" 2>/dev/null                              # user|ip|first|last|count
        cat "$PEERS_DIR"/*.ips 2>/dev/null
        awk -F'|' 'NF>=3 && $1!="" && $2!="" { print $1"|"$2"|0|"$3"|1" }' \
            "$AUTHMAP_FILE" 2>/dev/null                          # user|ip|ts -> тот же вид
    } | awk -F'|' -v cut="$cut" '
        NF>=4 && $1!="" && $2!="" && $4+0 >= cut {
            if (!seen[$2 "|" $1]++) { n[$2]++; owner[$2] = $1 }
        }
        END { for (ip in n) if (n[ip] == 1) print ip "\t" owner[ip] }'
}

# TUIC-трафик в общий учёт (STATS_FILE). Per-user счётчиков у sing-box нет:
# StatsService живёт за тегом сборки `with_v2ray_api`, которого в официальных
# релизах нет (проверено на 1.13.14: в бинарнике строка «v2ray api is not
# included in this build»), а clash_api не отдаёт `metadata.user` (P-17).
# Поэтому считаем ПРИБЛИЖЁННО: дельты байт каждого соединения (clash_api
# /connections отдаёт upload/download на соединение) между двумя снимками, юзер —
# по `sourceIP` и ТОЛЬКО для однозначных адресов (_proto_ip_sole_owner_lines).
# Совпадающие по id соединения дают дельту; закрывшиеся между снимками выпадают
# (их хвост теряется). Для доминирующего объёма (стриминг/загрузки = долгие
# соединения) это ловится хорошо; короткие запросы недосчитываются. ВАЖНО:
# вызывать ЧАСТО (раз в минуту, из --online-sync), иначе почти все соединения
# успеют закрыться между снимками и учёт занулится.
# Снимок id->bytes храним в PROTO_DIR/tuic_conn_prev.
proto_collect_tuic_traffic() {
    proto_tuic_enabled || return 0
    local secret conns prev="$PROTO_DIR/tuic_conn_prev" newprev="$PROTO_DIR/tuic_conn_prev.tmp.$BASHPID"
    secret=$(cat "$SINGBOX_API_SECRET_FILE" 2>/dev/null)
    conns=$(curl -s --max-time 3 -H "Authorization: Bearer ${secret}" \
        "http://127.0.0.1:${SINGBOX_API_PORT}/connections" 2>/dev/null)
    [ -n "$conns" ] || return 0
    echo "$conns" | jq empty 2>/dev/null || return 0

    declare -A _prev _du _owner
    if [ -f "$prev" ]; then
        while IFS=$'\t' read -r id bytes; do
            [ -n "$id" ] && [[ "$bytes" =~ ^[0-9]+$ ]] && _prev[$id]=$bytes
        done < "$prev"
    fi
    # ip -> ЕДИНСТВЕННЫЙ юзер этого адреса (см. _proto_ip_sole_owner_lines).
    local ip user
    while IFS=$'\t' read -r ip user; do
        [ -n "$ip" ] && [ -n "$user" ] && _owner[$ip]=$user
    done < <(_proto_ip_sole_owner_lines)

    : > "$newprev"
    local id bytes p d
    while IFS=$'\t' read -r id ip bytes; do
        [ -n "$id" ] || continue
        [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
        # Снимок пишем по ВСЕМ соединениям, даже неатрибутируемым: иначе на
        # следующем тике их байты пришли бы дельтой «с нуля» и, если адрес к тому
        # времени стал однозначным, разом записались бы одному юзеру.
        printf '%s\t%s\n' "$id" "$bytes" >> "$newprev"
        user=${_owner[$ip]:-}; [ -n "$user" ] || continue
        p=${_prev[$id]:-0}
        if [ "$bytes" -ge "$p" ]; then d=$(( bytes - p )); else d=$bytes; fi   # d<0 = переоткрытый id
        [ "$d" -gt 0 ] && _du[$user]=$(( ${_du[$user]:-0} + d ))
    done < <(echo "$conns" | jq -r '(.connections // [])[]
        | select(.metadata.sourceIP != null)
        | "\(.id)\t\(.metadata.sourceIP)\t\((.upload // 0) + (.download // 0))"' 2>/dev/null)
    mv "$newprev" "$prev" 2>/dev/null

    # Докладываем дельты в STATS_FILE (всё в rx: клиент преимущественно качает,
    # для суммарной квоты сторона не важна).
    local u
    for u in "${!_du[@]}"; do
        d=${_du[$u]}
        [ "$d" -gt 0 ] && echo "${u}|0|${d}"
    done | _stats_add
}

# ---------------- Активность доп. протоколов ----------------
# Печатает строки «user|cum» — КУМУЛЯТИВНЫЙ трафик (tx+rx, байт) юзера по доп.
# протоколам, БЕЗ сброса счётчиков — их читают ещё и общий сбор со спидометром.
# Нужен collect_activity (lib/traffic.sh) для расчёта скорости за интервал и флага
# «онлайн/активен» по всем протоколам, а не только Hysteria. best-effort: любой
# сбой источника — просто нет его строк (Hysteria-активность не ломаем).
#   Xray  — statsquery user>>>EMAIL>>>traffic>>>up|downlink, суммируем оба направления.
#   TUIC  — sing-box /connections по sourceIP (user в API пуст), см.
#           proto_tuic_activity_lines. Best-effort, только для онлайна.
# $1="no-tuic" — НЕ подмешивать TUIC-суммы. Нужно спидометру (collect_rates):
# proto_tuic_activity_lines отдаёт СУММУ байт ОТКРЫТЫХ TUIC-соединений, а не
# монотонный кумулятив ноды. В delta-подсчёте скорости (cum-prevcum) стекающиеся
# при переключении keepalive-соединения дают фантомный рост до нереальных
# значений. Xray/Hysteria-счётчики монотонны — их оставляем. Для collect_activity
# TUIC оставляем: там это грубый флаг «онлайн», а не скорость, и per-user
# TUIC-трафик всё равно не атрибутируется (docs/guide/ONLINE.md).
proto_activity_cum_lines() {
    proto_any_enabled || return 0
    if proto_xray_needed && [ -x "$XRAY_BIN" ]; then
        "$XRAY_BIN" api statsquery --server="127.0.0.1:${XRAY_API_PORT}" -pattern "user>>>" 2>/dev/null \
          | jq -r '
                reduce ((.stat // [])[]
                        | select(.name != null and (.name | startswith("user>>>")))) as $s
                    ({}; .[($s.name | split(">>>"))[1]] += (($s.value // 0) | tonumber))
                | to_entries[] | "\(.key)|\(.value)"' 2>/dev/null
    fi
    [ "$1" = "no-tuic" ] || proto_tuic_activity_lines   # TUIC по sourceIP (user в API пуст)
    return 0
}

# Кумулятив Xray РАЗДЕЛЬНО по направлениям: «user|downlink|uplink». Для спидометра
# с разбивкой ↓↑ (per-node): collect_rates складывает это с Hysteria tx/rx. TUIC не
# включаем (его снимок открытых соединений завышал бы скорость, см. выше).
# downlink = сервер→клиент (↓, скачивание), uplink = клиент→сервер (↑).
proto_xray_split_lines() {
    proto_any_enabled || return 0
    proto_xray_needed && [ -x "$XRAY_BIN" ] || return 0
    "$XRAY_BIN" api statsquery --server="127.0.0.1:${XRAY_API_PORT}" -pattern "user>>>" 2>/dev/null \
      | jq -r '
            reduce ((.stat // [])[]
                    | select(.name != null and (.name | startswith("user>>>")))) as $s
                ({};
                 ($s.name | split(">>>")) as $p
                 | .[$p[1]] = ((.[$p[1]] // {down:0, up:0})
                    | if $p[3]=="downlink" then .down += (($s.value//0)|tonumber)
                      elif $p[3]=="uplink" then .up += (($s.value//0)|tonumber) else . end))
            | to_entries[] | "\(.key)|\(.value.down)|\(.value.up)"' 2>/dev/null
}

# TUIC-активность best-effort. sing-box (clash_api) НЕ отдаёт user в метадате
# соединения (проверено эмпирически) — атрибутируем по sourceIP: берём юзера с
# самым свежим last_seen на этом IP из ips.dat (+ peers/*.ips). Печатает user|cum
# (сумма upload+download открытых TUIC-соединений юзера). ТОЛЬКО для онлайна:
# на общем CGNAT-IP изредка попадёт не тот юзер — для индикатора приемлемо, в
# трафик/квоты это НЕ идёт. См. docs/guide/ONLINE.md.
proto_tuic_activity_lines() {   # [bytes|conns|ips]
    proto_tuic_enabled || return 0
    local mode="${1:-bytes}" secret conns
    secret=$(cat "$SINGBOX_API_SECRET_FILE" 2>/dev/null)
    conns=$(curl -s --max-time 3 -H "Authorization: Bearer ${secret}" \
        "http://127.0.0.1:${SINGBOX_API_PORT}/connections" 2>/dev/null)
    [ -n "$conns" ] || return 0
    echo "$conns" | jq empty 2>/dev/null || return 0

    # ip -> самый свежий user (ips.dat + peers/*.ips: user|ip|first|last|count).
    declare -A _ipuser
    local ip user last
    while IFS=$'\t' read -r ip user; do
        [ -n "$ip" ] && [ -n "$user" ] && _ipuser[$ip]=$user
    done < <( { cat "$IPS_FILE" 2>/dev/null; cat "$PEERS_DIR"/*.ips 2>/dev/null; } \
        | awk -F'|' 'NF>=4 && $1!="" && $2!="" {
            ls=($4 ~ /^[0-9]+$/)?$4+0:0; if(ls>=s[$2]){s[$2]=ls; u[$2]=$1} }
          END{ for(x in u) print x"\t"u[x] }' )

    # sourceIP+bytes каждого TUIC-соединения -> резолв в юзера -> сумма.
    # В режиме ips вместо суммы печатаем сами пары «user|ip» (разные IP одного
    # юзера, без повторов) — из них считается число устройств, см. refresh_online.
    declare -A _du _seen
    local bytes u2
    while IFS=$'\t' read -r ip bytes; do
        [ -n "$ip" ] || continue
        u2=${_ipuser[$ip]:-}; [ -n "$u2" ] || continue
        if [ "$mode" = ips ]; then
            [ -n "${_seen[$u2|$ip]:-}" ] || { _seen[$u2|$ip]=1; echo "${u2}|${ip}"; }
            continue
        fi
        [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
        [ "$mode" = conns ] && bytes=1        # считаем соединения, а не байты
        _du[$u2]=$(( ${_du[$u2]:-0} + bytes ))
    done < <(echo "$conns" | jq -r '(.connections // [])[]
        | select(.metadata.sourceIP != null)
        | "\(.metadata.sourceIP)\t\((.upload // 0) + (.download // 0))"' 2>/dev/null)
    for u2 in "${!_du[@]}"; do echo "${u2}|${_du[$u2]}"; done
    return 0
}

# ---------------- Онлайн доп. протоколов ----------------
# Печатает строки «user|ip» — АДРЕСА, с которых юзер сейчас в сети по доп.
# протоколам (best-effort; при любой ошибке — пусто, чтобы никогда не ломать
# основной онлайн Hysteria). Считать устройства по этим строкам — дело
# refresh_online: один клиент пингует все протоколы сразу и виден и в Xray, и в
# TUIC, и в Hysteria с ОДНОГО адреса — суммировать их значило бы считать одно
# устройство трижды.
# Xray: карта онлайн-IP (policy.levels."0".statsUserOnline) — по юзеру за раз.
# sing-box: sourceIP активных TUIC-соединений, резолв в юзера по ips.dat.
proto_online_ip_lines() {
    proto_any_enabled || return 0
    if proto_xray_needed && [ -x "$XRAY_BIN" ]; then
        # Онлайн живёт в ОТДЕЛЬНОМ реестре Xray: `statsquery -pattern online`
        # отдаёт пустой {} даже при непустом traffic (проверено на 26.3.27) —
        # достать его можно только по одному юзеру.
        # Юзеров на ноде десятки, вызов локальный, крон раз в минуту — терпимо.
        #
        # НЕ `statsonline`: его value = размер карты онлайн-IP, а Xray эту карту
        # не чистит (на node-a встречались записи 137-часовой давности) — на
        # мобильном CGNAT один телефон за сутки меняет IP и превращается в 5-11
        # «устройств». Берём `statsonlineiplist` (та же одна команда, отдаёт
        # ip → last_seen) и считаем только свежие IP. См. P-33.
        # Разбираем ответ awk'ом, а не jq: команда идёт по юзеру, а jq стоит
        # ~100 мс на запуск — на два десятка профилей это лишние секунды на
        # КАЖДУЮ перерисовку экрана. Формат ответа простой: строки «"<ip>": <ts>»
        # (ts всегда после последнего двоеточия, так что IPv6 не ломает разбор).
        local u now
        now=$(date +%s)
        while IFS=: read -r u _; do
            [ -n "$u" ] || continue
            "$XRAY_BIN" api statsonlineiplist --server="127.0.0.1:${XRAY_API_PORT}" \
                    -email "$u" 2>/dev/null \
                | awk -v u="$u" -v now="$now" -v w="${XRAY_ONLINE_WINDOW_SEC:-120}" '
                    {
                        s = $0
                        while (match(s, /"[0-9a-fA-F][0-9a-fA-F.:]*"[ \t]*:[ \t]*[0-9]+/)) {
                            tok = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
                            split(tok, q, "\""); n = split(tok, r, ":")
                            if (now - (r[n] + 0) <= w) print u "|" q[2]
                        }
                    }'
        done < "$USERS_DB"
    fi
    if proto_tuic_enabled; then
        # metadata.user у sing-box НЕТ (перепроверено на 1.13.14: 44 соединения
        # подряд — поле отсутствует у всех), поэтому фильтр по нему давал вечно
        # пустой онлайн. Резолвим соединения в юзеров по sourceIP тем же путём,
        # что и активность, — proto_tuic_activity_lines в режиме ips.
        proto_tuic_activity_lines ips
    fi
    return 0
}

# ---------------- Кик сессий доп. протоколов ----------------
# Лимит устройств держится киком, а кикать умела только Hysteria (P-16): юзер,
# чей клиент выбрал VLESS/Trojan/SS или TUIC, лимита не замечал вовсе.
# Ни у Xray, ни у sing-box нет «разорвать сессию юзера» одной командой, поэтому
# каждый протокол кикается своим способом (см. guide/DEVICE-LIMITS.md).

# Xray: разорвать УЖЕ УСТАНОВЛЕННОЕ соединение нечем. Проверено на 26.3.27:
# после `api rmu` открытая загрузка продолжалась как ни в чём не бывало, а вот
# НОВОЕ соединение с теми же кредами получало отказ. Значит кик здесь — это
# «заморозка»: снимаем юзера из инбаундов на несколько секунд и возвращаем.
# Текущие потоки доживают, любой новый запрос (а их у браузера непрерывный
# поток) в это окно не проходит — превышение лимита ощущается сразу.
XRAY_KICK_FREEZE_SEC="${XRAY_KICK_FREEZE_SEC:-10}"

_proto_xray_add_user() {   # user uuid upsk -> 0 если добавлен
    local j="$PROTO_DIR/.xray.add.$BASHPID.$RANDOM" rc=1
    ( umask 077; _proto_xray_adu_json "$1" "$2" "$3" > "$j" )
    [ -s "$j" ] && "$XRAY_BIN" api adu --server="127.0.0.1:${XRAY_API_PORT}" "$j" >/dev/null 2>&1 && rc=0
    rm -f "$j"

    return $rc
}

proto_xray_kick() {   # user -> 0 если сняли
    proto_xray_needed || return 1
    { [ -x "$XRAY_BIN" ] && command -v jq >/dev/null 2>&1; } || return 1
    systemctl is-active --quiet "$XRAY_SERVICE" 2>/dev/null || return 1

    local user="$1" row uid psk t
    row=$(_proto_xray_desired_users | awk -F'\t' -v u="$user" '$1==u{print; exit}')
    [ -n "$row" ] || return 1
    IFS=$'\t' read -r _ uid psk <<< "$row"

    while IFS= read -r t; do
        "$XRAY_BIN" api rmu --server="127.0.0.1:${XRAY_API_PORT}" -tag="$t" "$user" >/dev/null 2>&1
    done < <(_proto_xray_tags)

    # Возврат — отдельным процессом: крон не должен ждать конца заморозки.
    # Если этот процесс не доживёт (перезагрузка, kill), юзера вернёт
    # proto_xray_repair на ближайшем прогоне энфорсера.
    ( sleep "$XRAY_KICK_FREEZE_SEC"; _proto_xray_add_user "$user" "$uid" "$psk" ) >/dev/null 2>&1 &
    disown 2>/dev/null

    return 0
}

# Починка состава инбаундов: вернуть тех, кого в живом Xray нет, а по users.db
# должен быть. Страхует оборванную заморозку (см. выше) и любой сбой hot-apply —
# без неё юзер остался бы без доступа до следующего proto_sync_users.
# Зовётся раз в минуту из enforce_device_limits, ДО киков — иначе починка
# отменяла бы только что начатую заморозку.
proto_xray_repair() {
    proto_xray_needed || return 0
    { [ -x "$XRAY_BIN" ] && command -v jq >/dev/null 2>&1; } || return 0
    systemctl is-active --quiet "$XRAY_SERVICE" 2>/dev/null || return 0

    local t live want u uid psk
    t=$(_proto_xray_tags | head -1); [ -n "$t" ] || return 0
    live=$("$XRAY_BIN" api inbounduser --server="127.0.0.1:${XRAY_API_PORT}" -tag="$t" 2>/dev/null \
        | jq -r '(.users // [])[].email' 2>/dev/null | LC_ALL=C sort -u)
    want=$(_proto_xray_desired_users)
    [ -n "$want" ] || return 0

    while IFS=$'\t' read -r u uid psk; do
        [ -n "$u" ] || continue
        printf '%s\n' "$live" | grep -qxF "$u" && continue
        _proto_xray_add_user "$u" "$uid" "$psk" \
            && echo "$(date '+%F %T') xray: вернул пропавшего $u" >> "$DATA_DIR/limit.log" 2>/dev/null
    done <<< "$want"

    return 0
}

# TUIC: sing-box не отдаёт юзера в API (`metadata.user` всегда null, P-17),
# поэтому соединения резолвим по адресу — и только по тем адресам, что
# принадлежат ЭТОМУ юзеру однозначно (_proto_ip_sole_owner_lines): за общим
# CGNAT-адресом может сидеть чужой, рвать его нельзя. Закрываем поштучно,
# DELETE /connections/{id} — соседние соединения не страдают.
proto_tuic_kick() {   # user -> 0 если что-то закрыли
    proto_tuic_enabled || return 1
    command -v jq >/dev/null 2>&1 || return 1

    local user="$1" secret conns ips id n=0
    secret=$(cat "$SINGBOX_API_SECRET_FILE" 2>/dev/null)
    conns=$(curl -s --max-time 3 -H "Authorization: Bearer ${secret}" \
        "http://127.0.0.1:${SINGBOX_API_PORT}/connections" 2>/dev/null)
    { [ -n "$conns" ] && echo "$conns" | jq empty 2>/dev/null; } || return 1

    ips=$(_proto_ip_sole_owner_lines | awk -F'\t' -v u="$user" '$2==u{print $1}')
    [ -n "$ips" ] || return 1

    while IFS= read -r id; do
        [ -n "$id" ] || continue
        curl -s --max-time 3 -X DELETE -H "Authorization: Bearer ${secret}" \
            "http://127.0.0.1:${SINGBOX_API_PORT}/connections/${id}" >/dev/null 2>&1 \
            && n=$((n + 1))
    done < <(echo "$conns" | jq -r --argjson ips "$(printf '%s\n' "$ips" | jq -R . | jq -sc .)" \
        '(.connections // [])[] | (.metadata.sourceIP // "") as $s | select($ips | index($s)) | .id' 2>/dev/null)

    [ "$n" -gt 0 ]
}

# Единая точка для энфорсеров и TUI: разорвать сессии юзера во ВСЕХ доп.
# протоколах. Hysteria кикается отдельно (api_post "/kick") — у неё свой API.
proto_kick_user() {   # user
    proto_any_enabled || return 0
    # Рубильник оператора: PROTO_KICK=0 в node.conf оставляет кик только на
    # Hysteria (как было до 4.15.52). Нужен потому, что включение сразу меняет
    # жизнь тех, кто годами сидел над лимитом и не замечал этого: на боевой
    # ноде счётчиковый кик срабатывает ~2000 раз в сутки у горстки юзеров, и
    # до сих пор он уходил в пустоту у всех, кто не на Hysteria.
    if declare -F node_get >/dev/null && [ "$(node_get PROTO_KICK 2>/dev/null)" = "0" ]; then
        return 0
    fi
    proto_xray_kick "$1" || true
    proto_tuic_kick "$1" || true

    return 0
}

# ---- Снимок состояния протоколов ноды (для кластера и диагностики) ----
# Одна строка на протокол: «proto|enabled|up|port|l4».
#   enabled — включён в настройках ноды (для Hysteria всегда 1: базовый протокол);
#   up      — сервис активен И порт реально слушается, т.е. протокол принимает
#             соединения ЛОКАЛЬНО. Снаружи порт может быть закрыт файрволом или
#             не проброшен фронтом — это уже не видно (см. docs/guide/CLUSTER-PROTOCOLS.md).
_proto_state_line() {   # name enabled service port l4(tcp|udp)
    local up=0 hay
    [ "$5" = udp ] && hay="$_PROTO_LISTEN_UDP" || hay="$_PROTO_LISTEN_TCP"
    if [ "$2" = 1 ] && systemctl is-active --quiet "$3" 2>/dev/null; then
        case "$hay" in *":$4 "*) up=1 ;; esac
    fi
    printf '%s|%s|%s|%s|%s\n' "$1" "$2" "$up" "$4" "$5"
}

proto_state_lines() {
    local _PROTO_LISTEN_TCP _PROTO_LISTEN_UDP
    _PROTO_LISTEN_TCP=$(ss -ltnH 2>/dev/null)
    _PROTO_LISTEN_UDP=$(ss -lunH 2>/dev/null)
    _proto_state_line hy2    1 "$SERVICE"         "$(get_port)"           udp
    _proto_state_line vless  "$(proto_vless_enabled  && echo 1 || echo 0)" "$XRAY_SERVICE"    "$(proto_vless_port)"  tcp
    _proto_state_line ss     "$(proto_ss_enabled     && echo 1 || echo 0)" "$XRAY_SERVICE"    "$(proto_ss_port)"     tcp
    _proto_state_line trojan "$(proto_trojan_enabled && echo 1 || echo 0)" "$XRAY_SERVICE"    "$(proto_trojan_port)" tcp
    _proto_state_line tuic   "$(proto_tuic_enabled   && echo 1 || echo 0)" "$SINGBOX_SERVICE" "$(proto_tuic_port)"   udp
}

# Статус для меню/диагностики: строка «vless:💚 ss:🔴 tuic:💚».
proto_status_line() {
    local s=""
    proto_vless_enabled  && s+="VLESS 💚 "  || s+="VLESS ⚪ "
    proto_ss_enabled     && s+="SS2022 💚 " || s+="SS2022 ⚪ "
    proto_trojan_enabled && s+="TROJAN 💚 " || s+="TROJAN ⚪ "
    proto_tuic_enabled   && s+="TUIC 💚"    || s+="TUIC ⚪"
    printf '%s' "$s"
}
