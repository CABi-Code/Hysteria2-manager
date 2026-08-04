#!/bin/bash
# Лимит устройств: тариф поднимает, но не опускает (P-42), и жёсткая проверка
# больше не выводит юзера из-под кика по адресам (P-41).
# Запуск: bash tests/test-device-limits.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export HY2M_DATA_DIR=$(mktemp -d)
export HY2M_WEBROOT="$HY2M_DATA_DIR/web"
mkdir -p "$HY2M_WEBROOT/cluster" "$HY2M_DATA_DIR/peers"
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT

source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/limits.sh"
source "$SCRIPT_DIR/lib/antiabuse.sh"   # get_user_hardcheck_effective
source "$SCRIPT_DIR/lib/devlimits.sh"

fail() { echo "❌ $1"; exit 1; }

# ---------- P-42: тариф не опускает докупленное ----------
set_user_limits paid 5 0 "" 0            # 1 тарифное + 4 докупленных
tariff_raise_devices paid 2              # оплатил месячный тариф на 2 устройства
[ "$(get_user_devices paid)" = "5" ] || fail "тариф стёр докупленные устройства"

set_user_limits small 1 0 "" 0
tariff_raise_devices small 3             # тариф щедрее текущего — поднимаем
[ "$(get_user_devices small)" = "3" ] || fail "тариф не поднял лимит"

set_user_limits nolimit 4 0 "" 0
tariff_raise_devices nolimit 0           # у тарифа лимит не задан — не трогаем
[ "$(get_user_devices nolimit)" = "4" ] || fail "тариф без лимита обнулил устройства"

tariff_raise_devices fresh 2             # записи ещё нет: default 1 → поднимаем
[ "$(get_user_devices fresh)" = "2" ] || fail "новому юзеру тариф не выдал устройства"

# ---------- P-41: жёсткая проверка не снимает лимит устройств ----------
# Заглушки: интересует только, кого энфорсер решит кикнуть.
KICKED=""
sub_enabled()                 { return 0; }
refresh_online()              { CACHED_ONLINE='{"hard":3,"soft":3}'; }
get_user_online_count()       { echo 3; }              # 3 адреса на этой ноде
cluster_user_connections()    { echo 3; }
get_active_users()            { printf 'hard\nsoft\n'; }
get_user_active()             { echo 0; }              # traffic-based энфорсер молчит
write_authlimits()            { return 0; }
hy_kick_user()                { KICKED="$KICKED $1"; }        # реальная точка кика (lib/api.sh)
api_post()                    { KICKED="$KICKED $(echo "$2" | tr -d '[]"')"; }
node_get()                    { echo 0; }              # глобальных лимитов нет
node_name()                   { echo testnode; }
get_user_active_since()       { echo 0; }

set_user_limits hard 1 1 "" 0            # лимит 1 устройство, жёсткая проверка ВКЛ
set_user_limits soft 1 0 "" 0            # лимит 1 устройство, обычный

enforce_device_limits

case "$KICKED" in
    *soft*) : ;;
    *) fail "обычный юзер с 3 адресами на лимите 1 не кикнут" ;;
esac
case "$KICKED" in
    *hard*) : ;;
    *) fail "P-41: юзер с жёсткой проверкой снова вне лимита устройств" ;;
esac

# Юзер в пределах лимита не трогается ни в каком режиме.
KICKED=""
set_user_limits hard 5 1 "" 0
set_user_limits soft 5 0 "" 0
enforce_device_limits
[ -z "${KICKED// /}" ] || fail "кикнули тех, кто в пределах лимита: $KICKED"


# ---------- Арбитраж между нодами: кикает одна, а не все сразу ----------
# Юзер с лимитом 1 держит по одной сессии на двух нодах: локально каждая нода в
# своём node_cap, превышение видно только по кластеру. Кикать должна ровно одна.
export CLUSTER_CONF="$HY2M_DATA_DIR/cluster.conf"
printf 'peer-node|zzz.example\n' > "$CLUSTER_CONF"
printf 'two\t1\t0\t0\t0\t0\t0\t0\n' > "$HY2M_DATA_DIR/peers/peer-node.stats"

set_user_limits two 1 0 "" 0
get_user_online_count()    { echo 1; }
cluster_user_connections() { echo 2; }
get_active_users()         { printf 'two\n'; }
refresh_online()           { CACHED_ONLINE='{"two":1}'; }

node_host() { echo aaa.example; }        # мы раньше пира по хосту — место наше
KICKED=""; unset CACHED_ONLINE; enforce_device_limits
[ -z "${KICKED// /}" ] || fail "кикнули на ноде, которая заняла место в лимите: $KICKED"

node_host() { echo zzzz.example; }       # мы позже пира — уступаем и кикаем
KICKED=""; unset CACHED_ONLINE; enforce_device_limits
case "$KICKED" in *two*) : ;; *) fail "уступившая нода не кикнула — лимит не применён" ;; esac

# Своё превышение режется без арбитража, даже если по хосту мы первые.
node_host() { echo aaa.example; }
get_user_online_count() { echo 3; }
KICKED=""; unset CACHED_ONLINE; enforce_device_limits
case "$KICKED" in *two*) : ;; *) fail "нода не срезала собственное превышение" ;; esac

# ---------- Кик доп. протоколов (P-16) ----------
# Резолвинг соединений TUIC в юзера идёт по адресу и ТОЛЬКО по однозначным
# адресам: за общим CGNAT-адресом сидит чужой, рвать его нельзя.
ips=$'1.2.3.4\n5.6.7.8'
conns='{"connections":[{"id":"aaa","metadata":{"sourceIP":"1.2.3.4"}},
        {"id":"bbb","metadata":{"sourceIP":"9.9.9.9"}},
        {"id":"ccc","metadata":{"sourceIP":"5.6.7.8"}},
        {"id":"ddd","metadata":{}}]}'
picked=$(echo "$conns" | jq -r --argjson ips "$(printf '%s\n' "$ips" | jq -R . | jq -sc .)" \
    '(.connections // [])[] | (.metadata.sourceIP // "") as $s | select($ips | index($s)) | .id' | tr '\n' ',')
[ "$picked" = "aaa,ccc," ] || fail "TUIC-кик выбрал не те соединения: $picked"

echo "✅ test-device-limits: ok"
