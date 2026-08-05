#!/bin/bash
# Обмен состоянием протоколов: строка снимка (_proto_state_line) и сводка по
# кластеру (cluster_protocols / cluster_proto_state). Сеть и systemd не трогаем —
# systemctl подменён функцией, слушающие порты берутся из переменных.
set -u

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export HY2M_DATA_DIR="$TMP/data"
mkdir -p "$HY2M_DATA_DIR/peers"

cd "$(dirname "$0")/.." || exit 1
source lib/config.sh >/dev/null 2>&1
source lib/protocols.sh >/dev/null 2>&1
source lib/cluster.sh >/dev/null 2>&1

# --- 1. Строка снимка: enabled/up считаются независимо ---
systemctl() { [ "$3" = "live.service" ]; }      # активен только live.service
_PROTO_LISTEN_TCP='LISTEN 0 4096 0.0.0.0:8443 0.0.0.0:*'
_PROTO_LISTEN_UDP='UNCONN 0 0 0.0.0.0:2053 0.0.0.0:*'

[ "$(_proto_state_line vless 1 live.service 8443 tcp)" = "vless|1|1|8443|tcp" ] \
    || { echo "FAIL: живой TCP-протокол не помечен up"; exit 1; }
[ "$(_proto_state_line tuic 1 live.service 2053 udp)" = "tuic|1|1|2053|udp" ] \
    || { echo "FAIL: живой UDP-протокол не помечен up"; exit 1; }
# сервис лежит — включён, но не слушает
[ "$(_proto_state_line hy2 1 dead.service 8443 tcp)" = "hy2|1|0|8443|tcp" ] \
    || { echo "FAIL: мёртвый сервис помечен up"; exit 1; }
# порт не слушается, хотя сервис активен (конфиг не подхватился)
[ "$(_proto_state_line ss 1 live.service 8388 tcp)" = "ss|1|0|8388|tcp" ] \
    || { echo "FAIL: неслушающий порт помечен up"; exit 1; }
# выключенный протокол не проверяется вовсе
[ "$(_proto_state_line trojan 0 live.service 8443 tcp)" = "trojan|0|0|8443|tcp" ] \
    || { echo "FAIL: выключенный протокол помечен up"; exit 1; }

# --- 2. Сводка по кластеру ---
node_host() { echo "me.example"; }
node_name() { echo "Моя"; }
proto_state_lines() { printf 'hy2|1|1|11478|udp\ntuic|0|0|2053|udp\n'; }

cat > "$CLUSTER_CONF" <<'EOF'
Моя|me.example
Германия|deu.example
Молчун|quiet.example
EOF
printf 'hy2|1|0|11478|udp\nvless|1|1|8443|tcp\n' > "$PEERS_DIR/Германия.protocols"
touch -d '@'"$(( $(date +%s) - 600 ))" "$PEERS_DIR/Германия.protocols"

out=$(cluster_protocols)

echo "$out" | grep -qx 'Моя|hy2|1|1|11478|udp|0' \
    || { echo "FAIL: своя нода в сводке неверна: $out"; exit 1; }
echo "$out" | grep -q '^Германия|hy2|1|0|11478|udp|' \
    || { echo "FAIL: состояние пира не попало в сводку"; exit 1; }
echo "$out" | grep -q '^Молчун|' \
    && { echo "FAIL: пир без кэша не должен попадать в сводку"; exit 1; }

age=$(echo "$out" | awk -F'|' '$1=="Германия" && $2=="hy2"{print $7}')
[ "$age" -ge 500 ] 2>/dev/null \
    || { echo "FAIL: возраст данных пира не посчитан (got '$age')"; exit 1; }

[ "$(cluster_proto_state Германия vless)" = "1|1|8443|tcp|$age" ] \
    || { echo "FAIL: cluster_proto_state отдал не то: $(cluster_proto_state Германия vless)"; exit 1; }
[ -z "$(cluster_proto_state Молчун hy2)" ] \
    || { echo "FAIL: по пиру без данных должно быть пусто"; exit 1; }

echo "OK: обмен состоянием протоколов"
