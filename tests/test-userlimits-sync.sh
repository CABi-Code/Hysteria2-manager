#!/bin/bash
# Область действия персональных лимитов в кластере:
#   • публикуем только КЛАСТЕРНЫХ юзеров (локальный тариф остаётся на своей ноде);
#   • применяем запись пира только если юзер у нас есть (никаких призраков).
# Запуск: bash tests/test-userlimits-sync.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export HY2M_DATA_DIR=$(mktemp -d)
export HY2M_WEBROOT="$HY2M_DATA_DIR/web"
mkdir -p "$HY2M_WEBROOT/cluster" "$HY2M_DATA_DIR/peers"
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT

source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/limits.sh"
source "$SCRIPT_DIR/lib/cluster.sh"

# Заглушки: интересует только раскладка «кого публикуем / кого применяем».
sub_enabled()      { return 0; }
secure_web_files() { return 0; }
write_authlimits() { return 0; }
db_user_exists()   { case "$1" in ghost) return 1 ;; *) return 0 ;; esac; }
is_user_disabled() { return 1; }

fail() { echo "❌ $1"; exit 1; }

# alice — кластерная (в roster), local_only — локальный профиль этой ноды.
# Оба заведены локально: иначе тест не поймал бы старое поведение (публикация
# по get_all_users, из-за которой локальный тариф уезжал на пиров).
get_all_users() { printf 'alice\nlocal_only\n'; }
roster_add alice
set_user_limits alice 2 0 "" 100
set_user_limits local_only 1 0 "" 1000

publish_cluster_userlimits
pub="$WEBROOT/cluster/userlimits"
grep -q '^alice|' "$pub"      || fail "кластерный alice не опубликован"
grep -q '^local_only|' "$pub" && fail "локальный профиль уехал в кластер"

# Пир прислал лимит на нашего alice (новее) и на отсутствующего ghost.
newer=$(( $(date +%s) + 100 ))
printf 'alice|3|1|%s|200\nghost|1|0|%s|500\n' "$newer" "$newer" > "$PEERS_DIR/peer1.userlimits"
cluster_apply_userlimits
[ "$(get_user_rate alice)" = 200 ] || fail "тариф кластерного alice не применён"
[ "$(get_user_devices alice)" = 3 ] || fail "устройства alice не применены"
grep -q '^ghost|' "$USERLIMITS_FILE" && fail "призрак: лимит юзера, которого тут нет"
grep -q '^ghost|' "$pub" && fail "призрак пошёл дальше по кластеру"

# Локальный тариф чужая синхронизация не трогает.
[ "$(get_user_rate local_only)" = 1000 ] || fail "локальный тариф затёрт синхронизацией"

# P-19: обёртки одного поля не должны обнулять соседние (покупка тарифа звала
# set_user_limits без rate и стирала персональную скорость).
set_user_devices alice 5
[ "$(get_user_rate alice)" = 200 ] || fail "set_user_devices обнулил тариф скорости"
set_user_hardcheck alice 0
[ "$(get_user_rate alice)" = 200 ] || fail "set_user_hardcheck обнулил тариф скорости"
[ "$(get_user_devices alice)" = 5 ] || fail "set_user_hardcheck обнулил устройства"

echo "✅ userlimits: область действия ок"
