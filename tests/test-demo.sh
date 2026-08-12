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
declare -A BYTES_OF; DELETED=""
demo_user_bytes()     { printf '%s' "${BYTES_OF[$1]:-0}"; }
cluster_delete_local() { DELETED+="$1 "; }
node_host()           { printf 'self.example'; }
node_get()            { printf '%s' "${NODE_CONF_DEMO_NODES:-}"; }   # только DEMO_NODES

fail() { echo "❌ $1"; exit 1; }
MB=$((1024*1024)); now=$(date +%s)

# --- активное демо в пределах лимитов не трогаем ---
demo_set live active "$now" "$((now + 600))" "$((500*MB))" 0 0
BYTES_OF[live]=$((100*MB))
demo_tick
[ -z "$DELETED" ] || fail "отобрали доступ у живого демо: '$DELETED'"
[ "$(demo_field live 2)" = "active" ] || fail "состояние живого демо изменилось"
[ "$(demo_active_count)" = 1 ] || fail "счётчик активных: $(demo_active_count)"

# --- вышло время ---
demo_set old active "$((now - 7200))" "$((now - 60))" "$((500*MB))" 0 0
demo_tick
[ "$DELETED" = "old " ] || fail "по TTL должны были отобрать только old: '$DELETED'"
[ "$(demo_field old 2)" = "expired" ] || fail "строка не помечена expired"

# --- выбран трафик (время ещё есть) ---
DELETED=""
demo_set fat active "$now" "$((now + 3600))" "$((500*MB))" "$((10*MB))" 0
BYTES_OF[fat]=$((10*MB + 500*MB))   # расход = ровно лимит, база учтена
demo_tick
[ "$DELETED" = "fat " ] || fail "по трафику должны были отобрать fat: '$DELETED'"
[ "$(demo_field fat 7)" = "$((500*MB))" ] || fail "израсходованное не записано: $(demo_field fat 7)"

# --- расход считается ОТ базы, а не от нуля ---
DELETED=""
demo_set based active "$now" "$((now + 3600))" "$((500*MB))" "$((400*MB))" 0
BYTES_OF[based]=$((400*MB + 100*MB))  # свои 100 МБ — лимит не выбран
demo_tick
[ -z "$DELETED" ] || fail "база трафика не учтена: '$DELETED'"

# --- через сутки после отбора строка исчезает ---
demo_set stale expired "$((now - 200000))" "$((now - DEMO_KEEP_SEC - 60))" "$((500*MB))" 0 123
demo_tick
[ -z "$(demo_row stale)" ] || fail "старая строка не вычищена"
[ -n "$(demo_row fat)" ] || fail "свежая expired-строка исчезла раньше суток"

# --- профиль на чужой ноде: отбирает его она, мы только держим указатель ---
DELETED=""
demo_set far active "$now" "$((now + 600))" "$((500*MB))" 0 0 "peer.example"
BYTES_OF[far]=$((900*MB))            # «перерасход» по нашим цифрам — не наше дело
demo_tick
[ -z "$DELETED" ] || fail "тронули профиль чужой ноды: '$DELETED'"
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

echo "✅ demo: TTL, трафик-кап, уборка, чужая нода и выбор ноды ок"
