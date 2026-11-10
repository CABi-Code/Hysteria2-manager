#!/bin/bash
# Суточный отчёт (docs/guide/DAILY-REPORT.md): трафик — разность со снимком по
# всем нодам (сброс счётчика не даёт минуса), топ, медиана скорости, сеть пира
# из его netday, старые выборки не копятся.
# Запуск: bash tests/test-daily-report.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export HY2M_DATA_DIR=$(mktemp -d)
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/traffic.sh"
source "$SCRIPT_DIR/lib/report.sh"
mkdir -p "$PEERS_DIR"

FAIL=0
ok()  { echo "  ✅ $1"; }
bad() { echo "  ❌ $1"; FAIL=1; }

# Окружение, которое отчёт берёт из других модулей.
node_label() { echo "Нода-А"; }
get_all_users() { printf '%s\n' alice bob carol dave; }
user_plan_facts() { case "$1" in alice|bob) echo "paid|$(( $(date +%s)+86400 ))|0|0" ;; carol) echo "free|0|0|0" ;; *) echo "paid|0|0|0" ;; esac; }
cluster_health_report() { [ -n "${DOWN:-}" ] && echo "peer1 (peer1) — недоступен"; return 0; }
cluster_coverage_report() { :; }
peer_version() { cut -d"|" -f1 "$PEERS_DIR/$1.version"; }
tg_esc() { printf '%s' "$1"; }
report_netday() { echo "ts=$(date +%s)"; echo "hy_conn=7"; }
MANAGER_VERSION=1.2.3
GB=1073741824

now=$(date +%s)
printf '#%s\n' $(( now - 86400 )) > "$REPORT_BASE"
printf 'Нода-А\talice\t%s\t0\nНода-А\tbob\t%s\t0\nПир\tbob\t%s\t0\n' $GB $((5*GB)) $((2*GB)) >> "$REPORT_BASE"
# alice +3 ГБ; bob на нашей ноде сброшен до 1 ГБ (не −4!), на пире +1 ГБ; carol новая, 512 КБ — не «пользовался».
printf 'alice\t0\t%s\t0\nbob\t0\t%s\t0\ncarol\t0\t524288\t0\n' $((4*GB)) $GB > "$DATA_DIR/self.stats"
printf 'bob\t0\t%s\t0\n' $((3*GB)) > "$PEERS_DIR/peer1.stats"
printf 'LABEL=Пир\n' > "$PEERS_DIR/peer1.nodeinfo"
printf '1.2.2|%s\n' "$now" > "$PEERS_DIR/peer1.version"
printf 'ts=%s\nhy_conn=42\nkicks=3\nfails=caddy:2\n' "$now" > "$PEERS_DIR/peer1.netday"
for b in 1048576 4194304 3145728; do echo "$now|R|Нода-А|$b"; done > "$REPORT_SAMPLES"
printf '%s|T\n%s|T\n%s|D|peer1 (peer1) — недоступен\n' "$now" "$now" "$now" >> "$REPORT_SAMPLES"

out=$(daily_report)

echo "── клиенты"
grep -q 'оплачено 2 · без срока 1 · истёк 0 · бесплатный 1' <<< "$out" && ok "виды профилей" || bad "виды: $(grep Профилей <<< "$out")"
grep -q 'Пользовались за сутки: 2$' <<< "$out" && ok "512 КБ — не пользовался" || bad "$(grep Пользовались <<< "$out")"
grep -q 'Трафик: 5.0 ГБ' <<< "$out" && ok "сброшенный счётчик не дал минуса" || bad "$(grep 'Трафик:' <<< "$out")"
grep -q 'Больше всех: <code>alice</code> 3.0 ГБ · <code>bob</code> 2.0 ГБ' <<< "$out" && ok "топ по сумме всех нод" || bad "$(grep Больше <<< "$out")"
grep -q 'медиана 3.0 МБ/с' <<< "$out" && ok "медиана" || bad "$(grep Скорость <<< "$out")"

echo "── техническая часть"
grep -q $'^\f$' <<< "$out" && ok "две части через \\f" || bad "нет разделителя частей"
tech=$(sed -n $'/^\f$/,$p' <<< "$out")
grep -q 'подключений 42' <<< "$tech" && ok "сеть пира из его netday" || bad "нет сети пира"
grep -q '🔴 Пир: падения служб за сутки — caddy:2' <<< "$tech" && ok "падение — срочно" || bad "$(grep -i пад <<< "$tech")"
grep -q '🟡 Пир: версия 1.2.2, у нас 1.2.3' <<< "$tech" && ok "отставшая версия" || bad "нет сигнала версии"
grep -q '🟡 Пир: была недоступна в 1 из 2 проверок' <<< "$tech" && ok "недоступность за сутки" || bad "нет сигнала недоступности"
DOWN=1 out2=$(printf '#%s\n' "$now" > "$REPORT_BASE"; daily_report)
grep -q '🔴 Пир: сейчас недоступен' <<< "$out2" && ok "недоступна сейчас — срочно" || bad "нет срочного сигнала"
printf '#%s\n' $(( now - 86400 )) > "$REPORT_BASE"
printf 'Пир\tbob\t%s\t0\n' $((3*GB)) >> "$REPORT_BASE"
echo "── новый снимок"
[ ! -s "$REPORT_SAMPLES" ] && ok "выборки обнулены" || bad "выборки остались"
grep -q "^Пир	bob	$((3*GB))	0" "$REPORT_BASE" && ok "снимок обновлён" || bad "снимок старый"
printf '#%s\n' $(( now - REPORT_MAX_AGE_SEC - 10 )) > "$REPORT_BASE"; echo "1|T" > "$REPORT_SAMPLES"
report_sample
[ "$(grep -c '|T$' "$REPORT_SAMPLES")" = 1 ] && ! grep -q '^1|' "$REPORT_SAMPLES" && ok "без отчёта двое суток — выборки начаты заново" || bad "выборки копятся"

[ "$FAIL" = 0 ] && echo "✅ test-daily-report" || { echo "❌ test-daily-report"; exit 1; }
