#!/bin/bash
# Проверка LWW-логики кластерного сброса ключей (cluster_apply_pwreset):
# применяем чужой сброс ровно один раз, свой — не применяем повторно.
# Запуск: bash tests/test-pwreset.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export HY2M_DATA_DIR=$(mktemp -d)
export HY2M_WEBROOT="$HY2M_DATA_DIR/web"
mkdir -p "$HY2M_WEBROOT/cluster" "$HY2M_DATA_DIR/peers"
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT

source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/cluster.sh"

# Заглушки: нас интересует только «кого и сколько раз крутим», не сама ротация.
sub_enabled()      { return 0; }
secure_web_files() { return 0; }
db_user_exists()   { [ "$1" != "ghost" ]; }
is_user_disabled() { return 1; }
ROTATED=""
change_user_password() { ROTATED+="$1 "; }

fail() { echo "❌ $1"; exit 1; }

# Пир объявил сброс для alice и для отсутствующего у нас ghost.
printf 'alice|1000\nghost|1000\n' > "$PEERS_DIR/peer1.pwreset"
cluster_apply_pwreset
[ "$ROTATED" = "alice " ] || fail "ожидали ротацию только alice, получили: '$ROTATED'"
[ "$(pwreset_get_ts alice)" = 1000 ] || fail "ts alice не запомнен"
[ "$(pwreset_get_ts ghost)" = 1000 ] || fail "ts ghost не запомнен (сброс сработает задним числом)"

# Повторный sync с теми же данными — ничего не крутим (нет обратной волны).
ROTATED=""
cluster_apply_pwreset
[ -z "$ROTATED" ] || fail "повторное применение: '$ROTATED'"

# Новый сброс с более свежим ts — крутим снова.
printf 'alice|2000\n' > "$PEERS_DIR/peer1.pwreset"
cluster_apply_pwreset
[ "$ROTATED" = "alice " ] || fail "свежий ts не применён: '$ROTATED'"

# Наш собственный сброс (pwreset_mark) пиры увидят, а мы его не переприменяем.
ROTATED=""
pwreset_mark bob
cluster_apply_pwreset
[ -z "$ROTATED" ] || fail "свой же сброс применён повторно: '$ROTATED'"
grep -q '^bob|' "$WEBROOT/cluster/pwreset" || fail "свой сброс не опубликован пирам"

echo "✅ pwreset: LWW ок"
