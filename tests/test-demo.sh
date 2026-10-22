#!/bin/bash
# Демо-профили (lib/demo.sh): доступ отбирается по времени ИЛИ по трафику,
# строка живёт сутки для статистики, потом исчезает.
# Запуск: bash tests/test-demo.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export HY2M_DATA_DIR=$(mktemp -d)
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT

source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/demo.sh"

# Заглушки: интересует только решение «отобрать / оставить / вычистить».
# Истёкший демо ОТКЛЮЧАЕТСЯ (DISABLED) — его ещё можно повысить при оплате;
# стирается (DELETED) только вместе со строкой, через DEMO_KEEP_SEC.
declare -A BYTES_OF; DELETED=""; DISABLED=""; XRAY_SYNCS=0
demo_user_bytes()     { printf '%s' "${BYTES_OF[$1]:-0}"; }
cluster_delete_local() { DELETED+="$1 "; }
demo_disable()        { DISABLED+="$1 "; }
proto_sync_xray()     { XRAY_SYNCS=$((XRAY_SYNCS + 1)); }
node_host()           { printf 'self.example'; }
node_get()            { printf '%s' "${NODE_CONF_DEMO_NODES:-}"; }   # только DEMO_NODES

fail() { echo "❌ $1"; exit 1; }
MB=$((1024*1024)); now=$(date +%s)

# --- активное демо в пределах лимитов не трогаем ---
demo_set live active "$now" "$((now + 600))" "$((500*MB))" 0 0
BYTES_OF[live]=$((100*MB))
demo_tick
[ -z "$DELETED$DISABLED" ] || fail "отобрали доступ у живого демо: '$DELETED$DISABLED'"
[ "$XRAY_SYNCS" = 0 ] || fail "Xray дёрнули, хотя никого не отбирали"
[ "$(demo_field live 2)" = "active" ] || fail "состояние живого демо изменилось"
[ "$(demo_active_count)" = 1 ] || fail "счётчик активных: $(demo_active_count)"

# --- вышло время ---
demo_set old active "$((now - 7200))" "$((now - 60))" "$((500*MB))" 0 0
demo_tick
[ "$DISABLED" = "old " ] || fail "по TTL должны были отключить только old: '$DISABLED'"
[ -z "$DELETED" ] || fail "истёкший демо стёрт сразу, а должен ждать оплату сутки: '$DELETED'"
[ "$XRAY_SYNCS" = 1 ] || fail "отобранного не убрали из Xray: синков $XRAY_SYNCS"
[ "$(demo_field old 2)" = "expired" ] || fail "строка не помечена expired"

# --- выбран трафик (время ещё есть) ---
DISABLED=""
demo_set fat active "$now" "$((now + 3600))" "$((500*MB))" "$((10*MB))" 0
BYTES_OF[fat]=$((10*MB + 500*MB))   # расход = ровно лимит, база учтена
demo_tick
[ "$DISABLED" = "fat " ] || fail "по трафику должны были отключить fat: '$DISABLED'"
[ "$(demo_field fat 7)" = "$((500*MB))" ] || fail "израсходованное не записано: $(demo_field fat 7)"

# --- расход считается ОТ базы, а не от нуля ---
DISABLED=""
demo_set based active "$now" "$((now + 3600))" "$((500*MB))" "$((400*MB))" 0
BYTES_OF[based]=$((400*MB + 100*MB))  # свои 100 МБ — лимит не выбран
demo_tick
[ -z "$DISABLED" ] || fail "база трафика не учтена: '$DISABLED'"

# --- через сутки после отбора строка исчезает ---
demo_set stale expired "$((now - 200000))" "$((now - DEMO_KEEP_SEC - 60))" "$((500*MB))" 0 123
demo_tick
[ -z "$(demo_row stale)" ] || fail "старая строка не вычищена"
[ "$DELETED" = "stale " ] || fail "через сутки профиль не стёрт: '$DELETED'"
[ -n "$(demo_row fat)" ] || fail "свежая expired-строка исчезла раньше суток"

# --- профиль на чужой ноде: отбирает его она, мы только держим указатель ---
DELETED=""; DISABLED=""
demo_set far active "$now" "$((now + 600))" "$((500*MB))" 0 0 "peer.example"
BYTES_OF[far]=$((900*MB))            # «перерасход» по нашим цифрам — не наше дело
demo_tick
[ -z "$DELETED$DISABLED" ] || fail "тронули профиль чужой ноды: '$DELETED$DISABLED'"
[ "$(demo_field far 2)" = "active" ] || fail "состояние чужого профиля изменилось"
[ "$(demo_node far)" = "peer.example" ] || fail "нода профиля потерялась: $(demo_node far)"

# по времени указатель гаснет и у нас (UI не должен показывать живым мёртвое)
demo_set far2 active "$now" "$((now - 60))" "$((500*MB))" 0 0 "peer.example"
demo_tick
[ "$(demo_field far2 2)" = "expired" ] || fail "истёкший указатель остался active"
[ -z "$DELETED" ] || fail "удаляли юзера за чужую ноду: '$DELETED'"

# --- выбор ноды: пустой список = эта нода ---
[ "$(demo_pick_node)" = "self.example" ] || fail "без DEMO_NODES выбрана не своя нода"

# мёртвых пиров не выбираем даже когда они в списке (вердикта в .health нет)
NODE_CONF_DEMO_NODES="self.example,dead.example"
[ "$(demo_pick_node)" = "self.example" ] || fail "выбран пир без вердикта здоровья"

# живой пир — кандидат наравне со своей нодой
mkdir -p "$PEERS_DIR"
printf 'live.example|live|1|%s|\n' "$now" > "$PEERS_HEALTH_FILE"
NODE_CONF_DEMO_NODES="self.example,live.example"
picked=$(for _ in $(seq 30); do demo_pick_node; echo; done | sort -u | tr '\n' ' ')
[ "$picked" = "live.example self.example " ] || fail "случайный выбор дал: '$picked'"

# --- потолок живых демо: единственный барьер, который не обходится со стороны
#     клиента, поэтому проверяем именно его, а не только счётчик ---
: > "$DEMOS_DB"
DEMO_MAX_ACTIVE=3
for i in 1 2; do demo_set "cap$i" active "$now" "$((now + 600))" "$((500*MB))" 0 0; done
demo_at_capacity && fail "потолок сработал раньше времени (активных 2 из 3)"
demo_set cap3 active "$now" "$((now + 600))" "$((500*MB))" 0 0
demo_at_capacity || fail "потолок не сработал на 3 из 3"
# expired место не занимают: demo_tick освобождает его сам
demo_set cap3 expired "$now" "$((now - 60))" "$((500*MB))" 0 0
demo_at_capacity && fail "expired-строка считается за живое демо"
# нулём потолок выключается — так ведут себя ноды, где его не выставляли
DEMO_MAX_ACTIVE=0
demo_set cap4 active "$now" "$((now + 600))" "$((500*MB))" 0 0
demo_at_capacity && fail "нулевой DEMO_MAX_ACTIVE должен выключать потолок"

echo "✅ demo: TTL, трафик-кап, уборка, чужая нода, выбор ноды и потолок ок"

# --- повышение демо в платный (оплата с браузера, получившего демо) ---
declare -A IN_DB=() DIS_PASS=(); SHARED=""; REFRESHED=0; DEFAULT_DEVICES=1   # из lib/limits.sh
db_user_exists()        { [ -n "${IN_DB[$1]:-}" ]; }
get_disabled_password() { printf '%s' "${DIS_PASS[$1]:-}"; }
db_add_user()           { IN_DB[$1]=1; }
set_user_limits()       { LIMITS="$*"; }
cluster_share_user()    { SHARED+="$1 "; }
write_authlimits()      { :; }
sub_refresh()           { REFRESHED=$((REFRESHED + 1)); }

demo_promote nobody; [ $? = 2 ] || fail "повысили несуществующее демо"
demo_set far active "$now" "$((now + 600))" "$((500*MB))" 0 0 "peer.example"
demo_promote far;    [ $? = 3 ] || fail "повысили демо чужой ноды"

# отключённое по истечении — возвращается с тем же паролем
demo_set paid expired "$now" "$((now - 60))" "$((500*MB))" 0 0
DIS_PASS[paid]=secret
demo_promote paid; rc=$?
[ "$rc" = 0 ] || fail "истёкшее демо не повысилось: rc=$rc"
db_user_exists paid || fail "профиль не вернулся в users.db"
[ -z "$(demo_row paid)" ] || fail "строка демо осталась — tick отберёт оплаченный доступ"
[ "$LIMITS" = "paid $DEFAULT_DEVICES 0  0" ] || fail "демо-скорость не снята: '$LIMITS'"
[ "$SHARED" = "paid " ] || fail "профиль не опубликован в кластер"
[ "$REFRESHED" = 1 ] || fail "подписка не пересобрана"

# стёртое (прошли сутки) повышать нечем — вызывающий заведёт новый профиль
demo_set gone expired "$now" "$((now - 60))" "$((500*MB))" 0 0
demo_promote gone; [ $? = 2 ] || fail "повысили стёртое демо"

echo "✅ demo: повышение в платный ок"
