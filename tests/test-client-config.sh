#!/bin/bash
# Клиентский конфиг sing-box (generate_user_config) и ссылка hysteria2://
# (build_user_link) обязаны описывать ОДНО И ТО ЖЕ подключение. Разошлись они
# в P-52: ссылка получила SNI домена ноды, а JSON остался на хосте маскарада,
# и сервер с настоящим сертом рвал хендшейк («tls: internal error»).
# Заодно сторожим разбор порта из listen (P-53).
# Запуск: bash tests/test-client-config.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export HY2M_DATA_DIR=$(mktemp -d)
export HY2M_CONFIG="$HY2M_DATA_DIR/config.yaml"
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT

fail() { echo "❌ $1"; exit 1; }

cat > "$HY2M_CONFIG" <<'YAML'
listen: 203.0.113.7:20443
masquerade:
  type: proxy
  proxy:
    url: https://www.microsoft.com/
    rewriteHost: true
obfs:
  type: salamander
  salamander:
    password: "obfs-secret"
YAML

source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/node.sh"
source "$SCRIPT_DIR/lib/users.sh"
source "$SCRIPT_DIR/lib/sub_links.sh"

printf 'alice:pass1\n'              > "$USERS_DB"
printf 'NODE_HOST=n1.example\n'     > "$NODE_CONF"
printf 'CONN_HOST=n1.example\n'    >> "$NODE_CONF"

# ---- P-53: порт из listen во всех формах ----
check_port() {   # ожидаемое строка-listen
    local want="$1" line="$2" got fix="$HY2M_DATA_DIR/listen.yaml"
    printf '%s\n' "$line" > "$fix"
    got=$(CONFIG="$fix" get_port)
    [ "$got" = "$want" ] || fail "get_port: «$line» → $got, ждали $want"
}
check_port 20443 'listen: 203.0.113.7:20443'
check_port 20443 'listen: :20443'
check_port 20443 'listen: [::]:20443'
check_port 20443 'listen:   203.0.113.7:20443   # комментарий'
check_port 11478 'foo: bar'

[ "$(get_port)" = "20443" ] || fail "get_port на фикстуре: $(get_port)"

# ---- SNI: настоящий серт против самоподписанного ----
# proto_tls_trusted живёт в protocols.sh; тут подменяем её, чтобы прогнать оба
# состояния ноды, не поднимая движки.
TRUSTED=1
proto_tls_trusted() { [ "$TRUSTED" = "1" ]; }

sni_of()      { jq -r '.outbounds[0].tls.server_name' "$1"; }
insecure_of() { jq -r '.outbounds[0].tls.insecure'    "$1"; }
sni_of_link() { sed -n 's/.*[?&]sni=\([^&#]*\).*/\1/p' <<<"$1"; }

for mode in tun socks; do
    # Нода с настоящим сертом: SNI — домен ноды, проверка строгая.
    TRUSTED=1
    cfg=$(generate_user_config alice "$mode") || fail "$mode: конфиг не собрался"
    [ "$(sni_of "$cfg")" = "n1.example" ] \
        || fail "$mode: SNI при настоящем серте = $(sni_of "$cfg"), ждали n1.example"
    [ "$(insecure_of "$cfg")" = "false" ] \
        || fail "$mode: при настоящем серте insecure обязан быть false"
    [ "$(jq -r '.outbounds[0].server_port' "$cfg")" = "20443" ] \
        || fail "$mode: порт в конфиге разъехался с listen"

    # Главный инвариант: ссылка и JSON описывают одно подключение.
    link=$(build_user_link alice pass1 "$(link_host)" "$(get_port)" "$(get_obfs_pass)" "$(get_sni)")
    [ "$(sni_of_link "$link")" = "$(sni_of "$cfg")" ] \
        || fail "$mode: SNI ссылки ($(sni_of_link "$link")) ≠ SNI конфига ($(sni_of "$cfg"))"
    rm -f "$cfg"

    # Нода без домена: поведение прежнее — хост маскарада и insecure.
    TRUSTED=0
    cfg=$(generate_user_config alice "$mode") || fail "$mode: конфиг не собрался (self-signed)"
    [ "$(sni_of "$cfg")" = "www.microsoft.com" ] \
        || fail "$mode: без серта SNI = $(sni_of "$cfg"), ждали хост маскарада"
    [ "$(insecure_of "$cfg")" = "true" ] \
        || fail "$mode: без настоящего серта insecure обязан быть true"
    rm -f "$cfg"
done

# ---- Конфиг обязан быть валиден для установленного sing-box ----
if command -v sing-box >/dev/null 2>&1; then
    TRUSTED=1
    for mode in tun socks; do
        cfg=$(generate_user_config alice "$mode")
        sing-box check -c "$cfg" >/dev/null 2>&1 || fail "$mode: sing-box check не принял конфиг"
        rm -f "$cfg"
    done
    echo "   (sing-box check пройден для tun и socks)"
else
    echo "   (sing-box не установлен — проверку схемы пропустили)"
fi

echo "✅ клиентский конфиг: SNI/insecure/порт совпадают со ссылкой в обоих режимах"
