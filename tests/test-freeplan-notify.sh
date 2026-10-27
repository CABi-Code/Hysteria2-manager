#!/bin/bash
# Сообщения бесплатного тарифа выводятся из СОСТОЯНИЯ, один раз на окно и
# только нодой с демоном бота (freeplan_notify_sync): качели состояния между
# нодами больше не становятся потоком сообщений (P-160, P-162).
# Запуск: bash tests/test-freeplan-notify.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export HY2M_DATA_DIR=$(mktemp -d)
export HY2M_WEBROOT="$HY2M_DATA_DIR/web"
mkdir -p "$HY2M_WEBROOT/cluster" "$HY2M_DATA_DIR/peers"
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT

source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/expiry.sh"
source "$SCRIPT_DIR/lib/freeplan.sh"
printf 'free|Бесплатный|0|1|0/0|XTR/RUB|free=1;wk=5G;mo=15G;start=online\n' > "$HY2M_DATA_DIR/tariffs.conf"
TARIFFS_CONF="$HY2M_DATA_DIR/tariffs.conf"

fail() { echo "❌ $1"; exit 1; }
GB=$((1024*1024*1024))
NOTIFY=""; RUNNING=0; BYTES=$((6*GB))
bot_running()             { return "$RUNNING"; }
freeplan_user_bytes()     { printf '%s' "$BYTES"; }
publish_cluster_freeplan(){ :; }
sub_enabled()             { return 0; }
bot_notify_free_entered() { NOTIFY+="entered "; }
bot_notify_free_low()     { NOTIFY+="low "; }
bot_notify_free_blocked() { NOTIFY+="blocked "; }
bot_notify_free_reset()   { NOTIFY+="reset "; }
W1=1000; W2=$((1000 + FREE_WEEK_SEC)); M=1000

# --- первый запуск: журнала нет — уже идущее никому не рассылается ---
freeplan_set u blocked 1 $W1 0 $M 0 4
freeplan_notify_sync
[ -z "$NOTIFY" ] || fail "первый запуск разослал историю: '$NOTIFY'"

# --- качель в одном окне: blocked → active → blocked даёт ноль новых ---
freeplan_set u active 1 $W1 0 $M 0 0;  freeplan_notify_sync
freeplan_set u blocked 1 $W1 0 $M 0 4; freeplan_notify_sync
freeplan_set u active 1 $W1 0 $M 0 0;  freeplan_notify_sync
[ -z "$NOTIFY" ] || fail "качель в одном окне дала сообщения: '$NOTIFY'"

# --- новое окно: «доступ вернулся» ровно один раз ---
freeplan_set u active 1 $W2 0 $M 0 0
freeplan_notify_sync; freeplan_notify_sync
[ "$NOTIFY" = "reset " ] || fail "новое окно: ждали одно reset, получили '$NOTIFY'"

# --- снова выбрал квоту в новом окне — одно blocked ---
NOTIFY=""
freeplan_set u blocked 1 $W2 0 $M 0 4
freeplan_notify_sync; freeplan_notify_sync
[ "$NOTIFY" = "blocked " ] || fail "blocked в новом окне: '$NOTIFY'"

# --- нода без запущенного бота молчит, но и не «съедает» событие ---
NOTIFY=""; RUNNING=1
freeplan_set v pending 0 0 0 0 0 0
freeplan_notify_sync
[ -z "$NOTIFY" ] || fail "нода без бота отправила: '$NOTIFY'"
RUNNING=0
freeplan_notify_sync
[ "$NOTIFY" = "entered " ] || fail "переход, сделанный без бота, должен прийти с ноды бота: '$NOTIFY'"

# --- переход сделал сосед: строка приехала через кластер — сообщение одно ---
NOTIFY=""
printf 'v|blocked|1|%s|0|%s|0|4|%s\n' "$W1" "$M" "$(( $(date +%s) + 60 ))" > "$PEERS_DIR/peer.freeplan"
cluster_apply_freeplan
cluster_apply_freeplan
[ "$NOTIFY" = "blocked " ] || fail "переход соседа: ждали одно blocked, получили '$NOTIFY'"

# --- порог: из нескольких неотправленных уходит один ---
NOTIFY=""
freeplan_set w active 1 $W1 0 $M 0 3
freeplan_notify_sync
[ "$NOTIFY" = "entered low " ] || fail "пачка порогов: '$NOTIFY'"

# --- ушёл с тарифа — отметки убраны, следующий заход снова «entered» ---
freeplan_remove w
freeplan_notify_sync
grep -q '^w|' "$FREEPLAN_NOTIFIED_FILE" && fail "отметки ушедшего не убраны"

echo "✅ test-freeplan-notify: из состояния, один раз на окно, только нода бота"
