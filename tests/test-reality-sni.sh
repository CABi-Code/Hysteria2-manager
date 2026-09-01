#!/bin/bash
# Сторож маскарада REALITY (P-129): SNI обязан вести на адрес ЭТОЙ ноды.
# DNS и список локальных адресов подменены функциями — сеть не трогаем.
set -u

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export HY2M_DATA_DIR="$TMP/data"
mkdir -p "$HY2M_DATA_DIR"

cd "$(dirname "$0")/.." || exit 1
source lib/config.sh    >/dev/null 2>&1
source lib/node.sh      >/dev/null 2>&1
source lib/protocols.sh >/dev/null 2>&1

list_local_ips() { echo "203.0.113.7"; }
getent() {   # getent ahostsv4 <домен>
    case "$2" in
        свой.example)  echo "203.0.113.7   STREAM свой.example" ;;
        www.samsung.com) echo "95.100.176.88 STREAM www.samsung.com" ;;
        *) return 2 ;;
    esac
}

# --- 1. Домен ведёт на нашу ноду — годен ---
proto_reality_sni_check свой.example >/dev/null 2>&1 \
    || { echo "FAIL: свой домен забракован"; exit 1; }

# --- 2. Чужой популярный домен (та самая причина бана) — брак ---
proto_reality_sni_check www.samsung.com >/dev/null 2>&1 \
    && { echo "FAIL: чужой домен в чужой AS принят как SNI"; exit 1; }

# --- 3. Домен без A-записи — брак, а не молчаливое «ок» ---
proto_reality_sni_check нет.example >/dev/null 2>&1 \
    && { echo "FAIL: нерезолвящийся домен принят"; exit 1; }

# --- 4. Пустой SNI (у ноды нет домена) — брак ---
proto_reality_sni_check "" >/dev/null 2>&1 \
    && { echo "FAIL: пустой SNI принят"; exit 1; }

# --- 5. Дефолты больше не тянут чужой популярный домен ---
[ "$(proto_reality_dest)" = "127.0.0.1:443" ] \
    || { echo "FAIL: dest по умолчанию не свой Caddy: $(proto_reality_dest)"; exit 1; }
node_set NODE_HOST свой.example >/dev/null 2>&1
[ "$(proto_reality_sni)" = "свой.example" ] \
    || { echo "FAIL: SNI по умолчанию не домен ноды: $(proto_reality_sni)"; exit 1; }

echo "OK: сторож REALITY SNI и дефолты маскарада"
