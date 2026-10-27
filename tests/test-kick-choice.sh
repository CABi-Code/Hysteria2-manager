#!/bin/bash
# Лимит устройств на одном телефоне не выбивает его рабочую ноду (P-163):
#  1) две QUIC-сессии с одного адреса — одно устройство, вчерашний адрес из
#     истории авторизаций вторым устройством не становится;
#  2) при превышении остаётся нода, где юзер реально гонит трафик, а не та,
#     где у него больше пустых сессий.
# Запуск: bash tests/test-kick-choice.sh
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
source "$SCRIPT_DIR/lib/devlimits.sh"

fail() { echo "❌ $1"; exit 1; }
node_host() { echo b.example; }
node_name() { echo b; }
_peer_host() { echo "$1"; }
pool_cap() { echo 1; }
node_cap() { echo 0; }

# ---------- 1) вчерашний адрес не превращается во второе устройство ----------
now=$(date +%s)
{
    printf 'me|9.9.9.9|%s\n' $(( now - 86000 ))     # вчера, с мобильного
    printf 'me|1.1.1.1|%s\n' $(( now - 600 ))
    printf 'me|1.1.1.1|%s\n' $(( now - 60 ))        # вторая QUIC-сессия того же телефона
} > "$AUTHMAP_FILE"
lines=$(_online_hysteria_ip_lines '{"me":2}')
[ "$lines" = "me|1.1.1.1" ] || fail "две сессии с одного адреса: ждали одно устройство, получили: $(echo $lines)"

# Две сессии с РАЗНЫХ свежих адресов — по-прежнему два устройства.
printf 'me|2.2.2.2|%s\n' $(( now - 30 )) >> "$AUTHMAP_FILE"
n=$(_online_hysteria_ip_lines '{"me":2}' | wc -l)
[ "$n" = "2" ] || fail "два свежих адреса должны дать два устройства, а не $n"

# ---------- 2) остаётся нода, где юзер качает ----------
# Мы — b, у нас 2 пустые сессии, трафика нет. Сосед a — 1 сессия, активен.
printf 'me|0|0|0\n' > "$ACTIVITY_FILE"
printf 'me\t1\t0\t0\t0\t0\t1\t100\t1.1.1.1\n' > "$PEERS_DIR/a.stats"
node_yields me 2 || fail "у нас пустые сессии, а у соседа трафик — кикать должны мы"

# Наоборот: качаем у нас — мы остаёмся, хотя сессий у соседа больше.
printf 'me|1|100|9000\n' > "$ACTIVITY_FILE"
printf 'me\t3\t0\t0\t0\t0\t0\t0\t1.1.1.1\n' > "$PEERS_DIR/a.stats"
node_yields me 1 && fail "у нас трафик — нас выбивать нельзя"

# Без трафика нигде — прежний порядок: больше сессий остаётся.
printf 'me|0|0|0\n' > "$ACTIVITY_FILE"
printf 'me\t1\t0\t0\t0\t0\t0\t0\t1.1.1.1\n' > "$PEERS_DIR/a.stats"
node_yields me 2 && fail "без трафика остаётся нода с большим числом сессий (мы)"

echo "✅ test-kick-choice: вчерашний адрес не устройство, рабочую ноду не выбивают"
