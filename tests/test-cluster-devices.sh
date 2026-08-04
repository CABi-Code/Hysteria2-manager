#!/bin/bash
# Устройства по кластеру считаются по РАЗНЫМ адресам, а не сложением счётчиков
# нод: одно устройство видно сразу нескольким нодам (клиент пингует все серверы
# подписки), и раньше оно считалось за несколько (P-45).
# Запуск: bash tests/test-cluster-devices.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export HY2M_DATA_DIR=$(mktemp -d)
export HY2M_WEBROOT="$HY2M_DATA_DIR/web"
mkdir -p "$HY2M_WEBROOT/cluster" "$HY2M_DATA_DIR/peers"
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT

source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/online.sh"
source "$SCRIPT_DIR/lib/publish.sh"

fail() { echo "❌ $1"; exit 1; }
node_host() { echo self.example; }

# Локальный онлайн подставляем напрямую — опрашивать протоколы тут нечего.
set_local() { CACHED_ONLINE_IPS="$1"; CACHED_ONLINE="$2"; }

# Пишем строку stats вручную: user \t conn \t tx \t rx \t sptx \t sprx \t ac \t asince \t ips
peer_row() {   # файл user conn ips_csv
    printf '%s\t%s\t0\t0\t0\t0\t0\t0\t%s\n' "$2" "$3" "$4" > "$PEERS_DIR/$1.stats"
}
peer_row_legacy() {   # файл user conn  (старая нода: 8 колонок, адресов нет)
    printf '%s\t%s\t0\t0\t0\t0\t0\t0\n' "$2" "$3" > "$PEERS_DIR/$1.stats"
}

# ---------- одно устройство на двух нодах = одно устройство ----------
set_local $'ann|1.2.3.4' '{"ann":1}'
peer_row peer1 ann 1 '1.2.3.4'
n=$(cluster_user_connections ann)
[ "$n" = "1" ] || fail "один адрес на двух нодах посчитан как $n устройств"

# ---------- разные адреса складываются ----------
peer_row peer1 ann 1 '9.9.9.9'
n=$(cluster_user_connections ann)
[ "$n" = "2" ] || fail "два разных адреса посчитаны как $n"

# ---------- три ноды, один и тот же телефон ----------
peer_row peer1 ann 1 '1.2.3.4'
peer_row peer2 ann 1 '1.2.3.4'
n=$(cluster_user_connections ann)
[ "$n" = "1" ] || fail "телефон на трёх нодах посчитан как $n устройств"

# ---------- нода без адресов (старая версия) считается по-старому ----------
rm -f "$PEERS_DIR"/*.stats
peer_row_legacy old ann 2
n=$(cluster_user_connections ann)
[ "$n" = "3" ] || fail "старая нода без адресов: ожидали 1+2=3, получили $n"

# ---------- «?» с разных нод не схлопывается ----------
rm -f "$PEERS_DIR"/*.stats
set_local $'ann|?' '{"ann":1}'
peer_row peer1 ann 1 '?'
n=$(cluster_user_connections ann)
[ "$n" = "2" ] || fail "неизвестные адреса разных нод схлопнулись в $n"

# ---------- юзера нет в сети нигде ----------
rm -f "$PEERS_DIR"/*.stats
set_local '' '{}'
n=$(cluster_user_connections ann)
[ "$n" = "0" ] || fail "офлайн-юзер посчитан как $n"

echo "✅ test-cluster-devices: ok"
