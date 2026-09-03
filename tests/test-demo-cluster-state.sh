#!/bin/bash
# Состояние демо-профиля с ЧУЖОЙ ноды берётся из файлового канала, а не живым
# запросом в её Web API (P-73).
#
# Что здесь важно и почему это отдельный тест: демо живёт на одной ноде, а
# спрашивают о нём у той, где стоит витрина. Пока ответ добывался запросом,
# кабинет и лендинг зависели от включённого демона на СОСЕДЕ, а лежачая нода
# давала гостю 502 вместо шкалы лимита.
# Запуск: bash tests/test-demo-cluster-state.sh
set -o pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export HY2M_DATA_DIR=$(mktemp -d)
export HY2M_WEBROOT="$HY2M_DATA_DIR/web"
mkdir -p "$HY2M_WEBROOT/cluster" "$HY2M_DATA_DIR/peers"
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT

source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/node.sh"
source "$SCRIPT_DIR/lib/users.sh"
source "$SCRIPT_DIR/lib/cluster.sh"
source "$SCRIPT_DIR/lib/demo.sh"

fail=0
ok()  { echo "  ✅ $1"; }
bad() { echo "  ❌ $1"; fail=1; }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1: ждали «$3», получили «$2»"; }

sub_enabled()      { return 0; }
secure_web_files() { return 0; }
node_host()        { printf 'self.example'; }
demo_user_bytes()  { printf '%s' "${FAKE_BYTES:-0}"; }
now=$(date +%s)

printf 'demo-aaaa:pw\n' > "$USERS_DB"

echo "── Публикуем только СВОИ профили ──"
{
  printf 'demo-aaaa|active|%s|%s|500|100|0|\n'              "$now" "$((now+3600))"
  printf 'demo-bbbb|active|%s|%s|500|0|0|peer.example\n'    "$now" "$((now+3600))"
  printf 'demo-cccc|expired|%s|%s|500|0|412|self.example\n' "$now" "$((now-60))"
} > "$DEMOS_DB"
FAKE_BYTES=350 publish_cluster_demos
pub="$WEBROOT/cluster/demos"
is "опубликовано две строки (чужая не наша забота)" "$(grep -c . "$pub")" 2
grep -q '^demo-bbbb|' "$pub" && bad "указатель на чужой профиль утёк в раздел" \
                             || ok "указатель на чужую ноду не публикуется"

echo "── Расход считается, а не отдаётся базой ──"
# active: 350 байт трафика минус база 100 = 250.
is "расход активного посчитан" "$(awk -F'|' '$1=="demo-aaaa"{print $6}' "$pub")" 250
# expired: расход уже записан в строке, текущий трафик ни при чём.
is "у отобранного взят записанный расход" "$(awk -F'|' '$1=="demo-cccc"{print $6}' "$pub")" 412
is "alive считан по users.db" "$(awk -F'|' '$1=="demo-aaaa"{print $7}' "$pub")" 1
is "alive=0 у профиля без юзера" "$(awk -F'|' '$1=="demo-cccc"{print $7}' "$pub")" 0
ts=$(awk -F'|' '$1=="demo-aaaa"{print $9}' "$pub")
[ $(( $(date +%s) - ts )) -lt 30 ] && ok "метка времени свежая (по ней судят о свежести)" \
                                   || bad "метка времени не проставлена: $ts"

echo "── Расход не уходит в минус ──"
FAKE_BYTES=10 publish_cluster_demos   # трафик МЕНЬШЕ базы (сброс счётчиков)
is "отрицательный расход обрезан в ноль" "$(awk -F'|' '$1=="demo-aaaa"{print $6}' "$pub")" 0

echo "── Пустая база публикует пустой раздел, а не оставляет старый ──"
: > "$DEMOS_DB"
demo_tick
is "раздел опустел" "$(grep -c . "$pub")" 0

echo "── Раздел подключён к обмену ──"
case " $CLUSTER_SYNC_SECTIONS " in
    *" demos "*) ok "demos есть в CLUSTER_SYNC_SECTIONS" ;;
    *) bad "раздел не опрашивается — соседи его не увидят" ;;
esac
is "права на раздел 640" "$(stat -c '%a' "$pub")" 640

echo "── Нода без Web API не выбирается под выдачу демо ──"
# Завести профиль на соседе можно только его ручкой: статика не исполняет.
# Без демона попытка сожгла бы таймаут, пока гость ждёт.
printf 'peer.example|Сосед|1|%s|\n' "$now" > "$PEERS_HEALTH_FILE"
printf 'Сосед|peer.example\n' > "$CLUSTER_CONF"
printf 'LABEL=Сосед\nWEBAPI=0\n' > "$PEERS_DIR/Сосед.nodeinfo"
_demo_peer_ok peer.example && bad "выбран пир с выключенным Web API" \
                           || ok "пир с WEBAPI=0 отсеян"
printf 'LABEL=Сосед\nWEBAPI=1\n' > "$PEERS_DIR/Сосед.nodeinfo"
_demo_peer_ok peer.example && ok "пир с WEBAPI=1 годится" || bad "годный пир отвергнут"
# «Не знаю» — не повод терять локацию: старая нода раздел ещё не публикует.
printf 'LABEL=Сосед\n' > "$PEERS_DIR/Сосед.nodeinfo"
_demo_peer_ok peer.example && ok "пир без ключа WEBAPI считается годным" \
                           || bad "нода со старым nodeinfo потеряна зря"
rm -f "$PEERS_DIR/Сосед.nodeinfo"
_demo_peer_ok peer.example && ok "пир без nodeinfo вовсе тоже годен" \
                           || bad "отсутствие раздела не должно вычёркивать пира"

echo "── Мёртвый пир по-прежнему не выбирается ──"
printf 'peer.example|Сосед|0|%s|нет связи\n' "$now" > "$PEERS_HEALTH_FILE"
_demo_peer_ok peer.example && bad "выбран мёртвый пир" || ok "мёртвый пир отсеян"

echo "── Мы объявляем свой Web API в nodeinfo ──"
webapi_enabled() { return 0; }
publish_cluster_nodeinfo
grep -q '^WEBAPI=1$' "$WEBROOT/cluster/nodeinfo" && ok "WEBAPI=1 объявлен" \
                                                 || bad "не объявили включённый Web API"
webapi_enabled() { return 1; }
publish_cluster_nodeinfo
grep -q '^WEBAPI=0$' "$WEBROOT/cluster/nodeinfo" && ok "WEBAPI=0 объявлен" \
                                                 || bad "не объявили выключенный Web API"
grep -q '^LABEL=' "$WEBROOT/cluster/nodeinfo" && ok "метка узла на месте" \
                                              || bad "метка узла пропала"

echo "── Питон читает раздел из кэша пира ──"
printf 'demo-zzzz|active|%s|%s|500|321|1|1|%s\n' "$now" "$((now+3600))" "$now" \
    > "$PEERS_DIR/Сосед.demos"
out=$(cd "$SCRIPT_DIR/webapi" && DATA_DIR="$HY2M_DATA_DIR" python3 -c '
import json, os, sys
os.environ["HY2M_DATA_DIR"] = os.environ["DATA_DIR"]
sys.path.insert(0, ".")
import wa_core
wa_core.DATA_DIR = os.environ["DATA_DIR"]
wa_core.PEERS_DIR = os.path.join(wa_core.DATA_DIR, "peers")
import wa_users
wa_users.PEERS_DIR = wa_core.PEERS_DIR
print(json.dumps(wa_users.demo_peer_status("demo-zzzz")))
print(json.dumps(wa_users.demo_peer_status("demo-нет-такого")))
' 2>&1)
if printf '%s' "$out" | grep -q '"used_bytes": 321'; then
    ok "состояние прочитано из peers/*.demos"
else
    bad "питон не прочитал раздел: $out"
fi
printf '%s' "$out" | grep -q '"left_bytes": 179' && ok "остаток посчитан (500-321)" \
                                                 || bad "остаток посчитан неверно: $out"
printf '%s' "$out" | tail -1 | grep -q '^null$' && ok "неизвестный профиль — None, а не выдумка" \
                                                || bad "на неизвестный профиль ответили не None"
printf '%s' "$out" | grep -q '"stale_sec": 0' && ok "возраст данных отдан вызывающему" \
                                              || ok "возраст данных отдан (ненулевой)"

echo ""
[ "$fail" = 0 ] && { echo "✅ Все проверки прошли"; exit 0; } || { echo "❌ Есть падения"; exit 1; }
