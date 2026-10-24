#!/bin/bash
# Жёсткая проверка и анти-абуз считают УСТРОЙСТВА по адресам, как и лимит
# устройств: одно устройство, у которого трафик идёт через несколько нод с
# одного адреса, — одно, и его не кикают (P-159).
# Запуск: bash tests/test-active-devices.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export HY2M_DATA_DIR=$(mktemp -d)
export HY2M_WEBROOT="$HY2M_DATA_DIR/web"
mkdir -p "$HY2M_WEBROOT/cluster" "$HY2M_DATA_DIR/peers"
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT

source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/online.sh"
source "$SCRIPT_DIR/lib/publish.sh"
source "$SCRIPT_DIR/lib/traffic.sh"
source "$SCRIPT_DIR/lib/antiabuse.sh"
source "$SCRIPT_DIR/lib/devlimits.sh"

fail() { echo "❌ $1"; exit 1; }
node_host() { echo self.example; }
node_name() { echo self; }
sub_enabled() { return 0; }
get_active_users() { echo ann; }
get_user_hardcheck_effective() { echo 1; }
pool_cap() { echo 1; }
KICKS=0
hy_kick_user() { KICKS=$((KICKS+1)); }
proto_kick_user() { :; }

# Эта нода активна с 200 (позже соседей) — при превышении обрезать будут её.
printf 'ann|1|200|9000\n' > "$ACTIVITY_FILE"
set_local() { CACHED_ONLINE_IPS="$1"; CACHED_ONLINE="$2"; }
# user \t conn \t tx \t rx \t sptx \t sprx \t active \t since \t ips
peer() { printf 'ann\t1\t0\t0\t0\t0\t1\t%s\t%s\n' "$2" "$3" > "$PEERS_DIR/$1.stats"; }

# ---------- один телефон, трафик через три ноды с одного адреса ----------
set_local $'ann|1.2.3.4' '{"ann":1}'
peer p1 100 '1.2.3.4'
peer p2 150 '1.2.3.4'
[ "$(cluster_active_node_count ann)" = "3" ] || fail "активных нод должно быть 3"
[ "$(cluster_active_device_count ann)" = "1" ] || fail "один адрес на трёх нодах — одно устройство, а не $(cluster_active_device_count ann)"
KICKS=0; enforce_active_node_limit
[ "$KICKS" -eq 0 ] || fail "одно устройство на лимите 1 кикнули ($KICKS)"

# ---------- два разных адреса на лимите 1 — шаринг, кик остаётся ----------
peer p2 150 '9.9.9.9'
[ "$(cluster_active_device_count ann)" = "2" ] || fail "два адреса — два устройства"
KICKS=0; enforce_active_node_limit
[ "$KICKS" -eq 1 ] || fail "два устройства на лимите 1 должны кикаться ($KICKS)"

# ---------- старая нода без адресов считается отдельным устройством ----------
rm -f "$PEERS_DIR"/*.stats
printf 'ann\t1\t0\t0\t0\t0\t1\t100\n' > "$PEERS_DIR/old.stats"
[ "$(cluster_active_device_count ann)" = "2" ] || fail "нода без адресов — как раньше, отдельно"

# ---------- анти-абуз: одно устройство на трёх нодах — не нарушение ----------
rm -f "$PEERS_DIR"/*.stats
peer p1 100 '1.2.3.4'; peer p2 150 '1.2.3.4'
cluster_user_connections() { echo 1; }
: > "$ABUSE_OBS_FILE"
abuse_observe
viol=$(cut -d'|' -f2 "$ABUSE_OBS_FILE")
[ "$viol" = "0" ] || fail "одно устройство на трёх нодах засчитано нарушением ($viol)"
peer p2 150 '9.9.9.9'
: > "$ABUSE_OBS_FILE"
abuse_observe
viol=$(cut -d'|' -f2 "$ABUSE_OBS_FILE")
[ "$viol" = "1" ] || fail "два устройства на лимите 1 — нарушение ($viol)"

echo "✅ test-active-devices: устройство = адрес и в жёсткой проверке, и в анти-абузе"
