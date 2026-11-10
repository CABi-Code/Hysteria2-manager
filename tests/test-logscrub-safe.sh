#!/bin/bash
# Фильтр журнала не убивает движок (P-177): умер хэшер — демон дорабатывает и
# отдаёт свой код; нет python3 или служба «тихая» — фильтра нет вовсе.
# Запуск: bash tests/test-logscrub-safe.sh
set -uo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export HY2M_DATA_DIR=$(mktemp -d)
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/ip_tracking.sh"
FAIL=0
ok()  { echo "  ✅ $1"; }
bad() { echo "  ❌ $1"; FAIL=1; }

D="$HY2M_DATA_DIR/daemon.sh"
printf '#!/bin/bash\nfor i in $(seq 1 20); do echo "from 10.0.0.$i"; sleep 0.1; done; exit 7\n' > "$D"; chmod +x "$D"
run() { local c=${1#/bin/bash -c \'}; c=${c%\'}; bash -c "$c"; }

echo "── хэшер умер посреди работы"
es=$(logscrub_execstart "$D" t.service)
( run "$es" >/dev/null; echo $? > "$HY2M_DATA_DIR/rc" ) &
sleep 0.5; pkill -f "^python3 -u .*scrub $HY2M_DATA_DIR"; wait
[ "$(cat "$HY2M_DATA_DIR/rc")" = 7 ] && ok "демон доработал, код его собственный" || bad "демон убит: код $(cat "$HY2M_DATA_DIR/rc")"

echo "── адреса скрыты"
run "$es" | grep -qE '10\.0\.0\.' && bad "адрес в выводе" || ok "в выводе нет адресов"

echo "── тихая служба"
mkdir -p "$LOGSCRUB_QUIET_DIR"; : > "$LOGSCRUB_QUIET_DIR/t.service"
es=$(logscrub_execstart "$D" t.service)
grep -q python3 <<< "$es" && bad "у тихой службы остался фильтр" || ok "фильтра нет"
[ -z "$(run "$es")" ] && ok "вывод выброшен" || bad "вывод тихой службы виден"
run "$es"; [ $? = 7 ] && ok "код демона доходит до systemd" || bad "код потерян"

[ "$FAIL" = 0 ] && echo "✅ test-logscrub-safe" || { echo "❌ test-logscrub-safe"; exit 1; }
