#!/bin/bash
# Проверка отчёта о здоровье пиров: битый/протухший/удалённый/живой.
# Сеть не трогаем — только разбор .health против cluster.conf.
set -u

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export HY2M_DATA_DIR="$TMP/data"
mkdir -p "$HY2M_DATA_DIR/peers"

cd "$(dirname "$0")/.." || exit 1
source lib/config.sh >/dev/null 2>&1
source lib/cluster.sh >/dev/null 2>&1

# Своя нода + три пира в реестре; «ушедший» пир в реестр НЕ входит.
node_host() { echo "me.example"; }
cat > "$CLUSTER_CONF" <<'EOF'
Me|me.example
Живой|ok.example
Мёртвый|dead.example
Молчун|stale.example
EOF

now=$(date +%s)
{
    printf 'me.example|Me|1|%s|\n'        "$now"
    printf 'ok.example|Живой|1|%s|\n'     "$now"
    printf 'dead.example|Мёртвый|0|%s|домен не резолвится\n' "$now"
    printf 'stale.example|Молчун|1|%s|\n' "$((now - 4000))"
    printf 'gone.example|Ушедший|0|%s|давно удалён\n' "$now"
} > "$PEERS_HEALTH_FILE"

report=$(cluster_health_report)

echo "$report" | grep -q 'Мёртвый'  || { echo "FAIL: недоступный пир не попал в отчёт"; exit 1; }
echo "$report" | grep -q 'Молчун'   || { echo "FAIL: протухший пир не попал в отчёт"; exit 1; }
echo "$report" | grep -q 'Живой'    && { echo "FAIL: живой пир помечен проблемным"; exit 1; }
echo "$report" | grep -q 'Me'       && { echo "FAIL: своя нода попала в отчёт"; exit 1; }
echo "$report" | grep -q 'Ушедший'  && { echo "FAIL: пир вне реестра попал в отчёт"; exit 1; }
[ "$(echo "$report" | grep -c .)" = 2 ] || { echo "FAIL: ожидались 2 строки, есть: $report"; exit 1; }

cluster_health_banner | grep -q 'Пиров с проблемой: 2' || { echo "FAIL: баннер неверен"; exit 1; }

# Всё здорово -> отчёт и баннер пусты.
{ printf 'ok.example|Живой|1|%s|\n' "$now"; } > "$PEERS_HEALTH_FILE"
[ -z "$(cluster_health_report)" ]  || { echo "FAIL: здоровый кластер дал отчёт"; exit 1; }
[ -z "$(cluster_health_banner)" ]  || { echo "FAIL: здоровый кластер дал баннер"; exit 1; }

echo "OK: test-cluster-health"

# Имя пира по хосту: из реестра, иначе безопасное из самого хоста.
printf 'deu1|deu1.example\nfin1|fin1.example\n' > "$CLUSTER_CONF"
[ "$(cluster_peer_name deu1.example)" = "deu1" ] || fail "имя пира не взято из реестра"
[ "$(cluster_peer_name unknown.example)" = "unknown.example" ] || fail "неизвестный хост"
[ "$(cluster_peer_name 'ho st/../x')" = "ho_st_.._x" ] || fail "имя не обеззаражено"
echo "  ✅ cluster_peer_name: реестр, неизвестный хост, обеззараживание"
