#!/bin/bash
# VLESS+REALITY+XHTTP как ВТОРОЙ инбаунд рядом с основным TCP+Vision
# (lib/protocols.sh). Ломается тихо и дорого: Xray отвергает VLESS-клиента с
# flow=xtls-rprx-vision на XHTTP-транспорте, поэтому проверяем, что
#   * оба инбаунда живут рядом, на разных портах, и настоящий xray их принимает;
#   * flow расставлен по транспорту, а не константой — и в конфиге, и в заготовке
#     для `xray api adu` (иначе каждое добавление юзера скатится в рестарт);
#   * share-ссылка совпадает с инбаундом (type=xhttp, порт, без flow).
# Запуск: bash tests/test-vlessx-inbound.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export HY2M_DATA_DIR=$(mktemp -d)
export HY2M_WEBROOT="$HY2M_DATA_DIR/web"
mkdir -p "$HY2M_WEBROOT"
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT

source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/node.sh"
source "$SCRIPT_DIR/lib/protocols.sh"

fail=0
ok()   { echo "  ✅ $1"; }
bad()  { echo "  ❌ $1"; fail=1; }
is()   { [ "$2" = "$3" ] && ok "$1" || bad "$1: ждали «$3», получили «$2»"; }
has()  { grep -qF -- "$2" <<< "$1" && ok "$3" || bad "$3 (нет «$2»)"; }
hasnt(){ grep -qF -- "$2" <<< "$1" && bad "$3 (есть «$2»)" || ok "$3"; }

mkdir -p "$PROTO_DIR"
printf 'user1:pass1\n' > "$USERS_DB"
cat > "$PROTO_CONF" <<EOF
PROTO_VLESS_ENABLED=1
PROTO_VLESSX_ENABLED=1
PROTO_VLESS_PORT=8443
PROTO_VLESSX_PORT=8445
PROTO_XHTTP_PATH=/dl
PROTO_REALITY_DEST=127.0.0.1:443
PROTO_REALITY_SNI=node.example.net
PROTO_REALITY_PRIVKEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEA
PROTO_REALITY_PUBKEY=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBEA
PROTO_REALITY_SHORTID=0123456789abcdef
EOF

echo "── Конфиг Xray: два VLESS-инбаунда ──"
proto_write_xray_config || bad "proto_write_xray_config вернул ошибку"

if ! command -v jq >/dev/null 2>&1; then
    echo "  ⚠️  нет jq — проверки конфига пропущены"
else
    is "инбаундов VLESS ровно два" \
       "$(jq '[.inbounds[]|select(.protocol=="vless")]|length' "$XRAY_CONFIG")" 2
    is "основной — raw TCP" \
       "$(jq -r '.inbounds[]|select(.tag=="vless-in").streamSettings.network' "$XRAY_CONFIG")" tcp
    is "резервный — xhttp" \
       "$(jq -r '.inbounds[]|select(.tag=="vless-xhttp-in").streamSettings.network' "$XRAY_CONFIG")" xhttp
    is "порты разные" \
       "$(jq -r '[.inbounds[]|select(.protocol=="vless").port]|join(",")' "$XRAY_CONFIG")" "8443,8445"
    # Главный инвариант: flow идёт по транспорту.
    is "flow у TCP-инбаунда — Vision" \
       "$(jq -r '.inbounds[]|select(.tag=="vless-in").settings.clients[0].flow' "$XRAY_CONFIG")" \
       xtls-rprx-vision
    is "flow у XHTTP-инбаунда пустой" \
       "$(jq -r '.inbounds[]|select(.tag=="vless-xhttp-in").settings.clients[0].flow' "$XRAY_CONFIG")" ""
    is "путь XHTTP из настроек" \
       "$(jq -r '.inbounds[]|select(.tag=="vless-xhttp-in").streamSettings.xhttpSettings.path' "$XRAY_CONFIG")" /dl
    # REALITY один на оба инбаунда: отдельных ключей/серта резерв не требует.
    is "REALITY-ключ общий" \
       "$(jq -r '[.inbounds[]|select(.protocol=="vless").streamSettings.realitySettings.privateKey]|unique|length' "$XRAY_CONFIG")" 1

    echo "── Заготовка для adu: flow тоже по транспорту ──"
    adu=$(_proto_xray_adu_json user1 11111111-1111-1111-1111-111111111111 psk)
    is "TCP-инбаунд получает Vision" \
       "$(jq -r '.inbounds[]|select(.streamSettings.network=="tcp").settings.clients[0].flow' <<< "$adu")" \
       xtls-rprx-vision
    is "XHTTP-инбаунд получает пустой flow" \
       "$(jq -r '.inbounds[]|select(.streamSettings.network=="xhttp").settings.clients[0].flow' <<< "$adu")" ""

    echo "── Теги для rmu/adu ──"
    has "$(_proto_xray_tags)" vless-xhttp-in "тег резерва в списке"
fi

echo "── Настоящий xray принимает конфиг ──"
if [ -x "$XRAY_BIN" ]; then
    # Ключ REALITY в фикстуре синтетический; xray -test проверяет СХЕМУ, а
    # невалидную base64 отвергает — поэтому ключ берём у самого бинарника.
    keys=$("$XRAY_BIN" x25519 2>/dev/null)
    priv=$(awk -F': *' '/[Pp]rivate/{print $2; exit}' <<< "$keys")
    [ -n "$priv" ] && { proto_set PROTO_REALITY_PRIVKEY "$priv"; proto_write_xray_config; }
    if out=$("$XRAY_BIN" -test -config "$XRAY_CONFIG" 2>&1); then
        ok "xray -test пройден для обоих инбаундов"
    else
        bad "xray -test не принял конфиг: $(tail -3 <<< "$out")"
    fi
else
    echo "  ⚠️  xray не установлен ($XRAY_BIN) — проверка схемы пропущена"
fi

echo "── Share-ссылка совпадает с инбаундом ──"
link=$(proto_build_vlessx user1 pass1 node.example.net "Нода | {protocol}")
has   "$link" ":8445?"                 "порт резерва, а не основной"
has   "$link" "type=xhttp"             "транспорт xhttp"
has   "$link" "path=%2Fdl"             "путь из настроек, urlencoded"
has   "$link" "mode=stream-one"        "режим stream-one (нет отдельного POST-стрима — причина upload=0)"
has   "$link" "security=reality"       "REALITY на месте"
hasnt "$link" "flow="                  "flow отсутствует (Vision с XHTTP невалиден)"

echo "── Оба ключа попадают в подписку ──"
uris=$(proto_user_uris user1 pass1 node.example.net "Нода | {protocol}")
is "две строки VLESS" "$(grep -c '^vless://' <<< "$uris")" 2
is "порты обоих ключей" "$(grep -o ':84[0-9][0-9]?' <<< "$uris" | tr -d ':?' | sort | tr '\n' ' ')" "8443 8445 "
has "$uris" "VLESS-X" "у резерва своя подпись (не схлопнется с основным в UI)"

echo "── Выключенный резерв не оставляет следов ──"
proto_set PROTO_VLESSX_ENABLED 0
proto_write_xray_config
if command -v jq >/dev/null 2>&1; then
    is "инбаунд ушёл" \
       "$(jq '[.inbounds[]|select(.tag=="vless-xhttp-in")]|length' "$XRAY_CONFIG")" 0
fi
is "ключа в подписке нет" \
   "$(proto_user_uris user1 pass1 node.example.net t | grep -c 'type=xhttp')" 0

echo ""
[ "$fail" = 0 ] && { echo "✅ Все проверки прошли"; exit 0; } || { echo "❌ Есть падения"; exit 1; }
