#!/bin/bash
# Право на забвение по кластеру (cluster_apply_erase + cluster_scrub_erased):
# чужое объявление применяем один раз, своё не переприменяем, а строки уже
# стёртого человека не возвращаются из зеркала пира, который ещё не применил
# забвение. Запуск: bash tests/test-erase-cluster.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export HY2M_DATA_DIR=$(mktemp -d)
export HY2M_WEBROOT="$HY2M_DATA_DIR/web"
mkdir -p "$HY2M_WEBROOT/cluster" "$HY2M_DATA_DIR/peers"
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT

source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/cluster.sh"

# erase_from_file берём настоящую (её и чинил scrub), остальное в users.sh тянет
# пол-менеджера — заглушаем сам erase_user, нас интересует «кого стёрли».
eval "$(sed -n '/^erase_from_file() {/,/^}/p' "$SCRIPT_DIR/lib/users.sh")"

sub_enabled()      { return 0; }
secure_web_files() { return 0; }
ERASED=""
erase_user() { ERASED+="$1 "; }

fail() { echo "❌ $1"; exit 1; }

# --- 1. LWW: применяем чужое забвение ровно один раз ---
printf 'alice|1000\n' > "$PEERS_DIR/peer1.erase"
cluster_apply_erase
[ "$ERASED" = "alice " ] || fail "чужое забвение не применено: '$ERASED'"
[ "$(erase_get_ts alice)" = 1000 ] || fail "ts alice не запомнен"

ERASED=""
cluster_apply_erase
[ -z "$ERASED" ] || fail "обратная волна: применили повторно '$ERASED'"

# Своё объявление пиры увидят, а мы его не переприменяем.
ERASED=""
erase_mark bob
cluster_apply_erase
[ -z "$ERASED" ] || fail "своё же забвение применено повторно: '$ERASED'"
grep -q '^bob|' "$WEBROOT/cluster/erase" || fail "своё забвение не опубликовано пирам"

# --- 2. Зеркало пира, который ещё не применил забвение, не воскрешает данные ---
# Ровно этот случай и возвращал freeplan/expiry обратно на каждой синхронизации.
printf 'alice|active|1|2|3|4|5|0|900\ncarol|active|1|2|3|4|5|0|900\n' > "$PEERS_DIR/peer1.freeplan"
printf 'alice|2026-01-01|900\ncarol|2026-01-01|900\n' > "$PEERS_DIR/peer1.expiry"
cluster_scrub_erased
grep -q '^alice|' "$PEERS_DIR/peer1.freeplan" && fail "freeplan стёртого вернулся из зеркала пира"
grep -q '^alice|' "$PEERS_DIR/peer1.expiry"   && fail "expiry стёртого вернулся из зеркала пира"
grep -q '^carol|' "$PEERS_DIR/peer1.freeplan" || fail "scrub задел живого юзера в freeplan"
grep -q '^carol|' "$PEERS_DIR/peer1.expiry"   || fail "scrub задел живого юзера в expiry"

# --- 3. Метки удаления scrub не трогает: без них профиль и привязка воскреснут ---
printf 'alice|deleted|1000\n' > "$PEERS_DIR/peer1.state"
printf '555||1000\n'          > "$PEERS_DIR/peer1.tgbind"
printf 'alice|1000\n'         > "$PEERS_DIR/peer1.erase"
cluster_scrub_erased
grep -q '^alice|deleted|' "$PEERS_DIR/peer1.state" || fail "стёрта метка удаления в .state — профиль воскреснет"
grep -q '^555||'          "$PEERS_DIR/peer1.tgbind" || fail "стёрт tombstone привязки — вернётся с соседа"
grep -q '^alice|'         "$PEERS_DIR/peer1.erase"  || fail "стёрто объявление забвения пира"

# --- 4. Реестр кластерных юзеров: имя на строку, без разделителя ---
printf 'alice\ncarol\n' > "$PEERS_DIR/peer1.roster"
cluster_scrub_erased
grep -qx 'alice' "$PEERS_DIR/peer1.roster" && fail "стёртый остался в roster пира — его заведут заново"
grep -qx 'carol' "$PEERS_DIR/peer1.roster" || fail "scrub выкинул живого юзера из roster"

# --- 5. Имя-префикс не уносит чужие строки ---
printf 'alicia|active|1|2|3|4|5|0|900\n' > "$PEERS_DIR/peer1.freeplan"
printf 'alicia\n'                        > "$PEERS_DIR/peer1.roster"
cluster_scrub_erased
grep -q  '^alicia|' "$PEERS_DIR/peer1.freeplan" || fail "«alice» унесло строку «alicia»"
grep -qx 'alicia'   "$PEERS_DIR/peer1.roster"   || fail "«alice» унесло из roster «alicia»"

echo "✅ erase по кластеру: LWW ок, зеркала пиров не воскрешают стёртых"
