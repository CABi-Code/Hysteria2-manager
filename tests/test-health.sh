#!/bin/bash
# Самодиагноз ноды и дозор кластера (lib/health.sh): разбор справки в беды,
# недоверенная справка пира, подтверждение вторым тактом, живое сообщение.
# systemctl и сеть не трогаем.
set -o pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export HY2M_DATA_DIR=$(mktemp -d)
export HY2M_WEBROOT="$HY2M_DATA_DIR/web"
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/node.sh"
source "$SCRIPT_DIR/lib/cluster.sh"
source "$SCRIPT_DIR/lib/health.sh"
tg_esc() { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' <<< "$1"; }
fail() { echo "FAIL: $*"; exit 1; }
now=$(date +%s)

# --- 1. Здоровая справка — бед нет ---
good="ts=$now
ver=1.2.3
down=
cron=online-sync:100,cluster-sync:200,collect:900
cert_days=60
disk=40
healed="
[ -z "$(health_problems peer <<< "$good")" ] || fail "здоровая справка дала беды: $(health_problems peer <<< "$good")"

# --- 2. Каждая беда — своей строкой и со стабильным кодом ---
bad="ts=$now
down=xray,tuic
cron=online-sync:100,cluster-sync:200,collect:9000
cert_days=3
disk=95"
out=$(health_problems peer <<< "$bad")
for code in svc:xray svc:tuic cron:collect cert disk; do
    grep -q "^$code	" <<< "$out" || fail "нет беды $code: $out"
done
grep -q '^cron:online-sync' <<< "$out" && fail "свежий крон объявлен бедой"

# --- 3. Устаревшая справка пира = «крон стоит», остальное из неё не читаем ---
out=$(health_problems peer <<< "ts=$((now - 5000))
down=xray")
[ "$(grep -c . <<< "$out")" = 1 ] && grep -q '^stale	' <<< "$out" || fail "устаревшая справка: $out"
# Своя справка на свежесть не проверяется (она только что посчитана).
[ -z "$(health_problems <<< "ts=$((now - 5000))")" ] || fail "своя справка объявлена устаревшей"

# --- 4. Мусор и разметка в справке пира в беды не попадают ---
out=$(health_problems peer <<< "ts=$now
down=<b>x</b>;rm -rf /
cron=online-sync:abc,../../x:99999
cert_days=<i>
disk=many")
[ -z "$out" ] || fail "мусорная справка дала беды: $out"

# --- 5. Отметка крона ---
[ "$(cron_age collect)" = 0 ] || fail "нет отметки — возраст должен быть 0 (не тревожим о неизвестном)"
cron_done collect; touch -d '-2 hours' "$DATA_DIR/.collect.done"
[ "$(cron_age collect)" -ge 7000 ] || fail "возраст отметки посчитан неверно"

# --- 6. Дозор: беда объявляется со второго такта, закрывается тем же ключом ---
LINES=""
_cluster_health_lines() { printf '%s' "$LINES"; }
LINES=$'b.example:svc:xray\tБ (b.example) — не работает <xray>\n'
[ -z "$(watch_run)" ] || fail "беда объявлена с первого такта"
out=$(watch_run)
key=$(head -1 <<< "$out")
grep -qE '^watch:[0-9]+$' <<< "$key" || fail "первая строка не ключ: $out"
grep -q 'Б (b.example) — не работает &lt;xray&gt;' <<< "$out" || fail "нет строки беды или она не экранирована: $out"
[ "$(head -1 <<< "$(watch_run)")" = "$key" ] || fail "тот же инцидент сменил ключ"
LINES=""
out=$(watch_run)
[ "$(head -1 <<< "$out")" = "$key" ] && grep -q 'снова в порядке' <<< "$out" || fail "нет закрытия тем же ключом: $out"
# Новая беда — новый ключ, даже в ту же секунду.
LINES=$'c.example:down\tВ (c.example) — недоступен\n'
watch_run >/dev/null; out=$(watch_run)
[ "$(head -1 <<< "$out")" != "$key" ] || fail "новый инцидент получил старый ключ"
# После хвоста закрытый инцидент молчит.
LINES=""; watch_run >/dev/null
sed -i "s/|[0-9]*$/|$((now - HEALTH_TAIL_SEC - 5))/" "$DATA_DIR/watch_episode"
[ -z "$(watch_run)" ] || fail "закрытый инцидент печатается после хвоста"

echo "OK: test-health"
