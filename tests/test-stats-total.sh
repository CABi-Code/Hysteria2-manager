#!/bin/bash
# Суммарный трафик кластера (webapi/wa_users.py: total_traffic) — цифра витрины
# в GET /v1/stats. Проверяем ровно то, что легко сломать: складываются оба
# направления, локальный stats.dat и кэши пиров, и мусорные поля не роняют счёт.
# Запуск: bash tests/test-stats-total.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export HY2M_DATA_DIR=$(mktemp -d)
mkdir -p "$HY2M_DATA_DIR/peers"
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT

# user|tx|rx — локальные счётчики; последняя строка битая (её пропускаем).
printf '%s\n' 'alice|100|200' 'bob|1000|2000' 'broken|x|y' > "$HY2M_DATA_DIR/stats.dat"
# peers/*.stats: user \t online \t tx \t rx \t …
printf 'alice\t0\t10000\t20000\t0\t0\t0\t0\n' > "$HY2M_DATA_DIR/peers/n1.stats"
printf 'carol\t1\t100000\t200000\t0\t0\t0\t0\n' > "$HY2M_DATA_DIR/peers/n2.stats"
# Не .stats — в сумму не входит.
printf 'dave\t0\t999999999\t999999999\t0\t0\t0\t0\n' > "$HY2M_DATA_DIR/peers/n2.rates"

got=$(PYTHONPATH="$SCRIPT_DIR/webapi" python3 -c 'from wa_users import total_traffic; print(total_traffic())')
[ "$got" = "333300" ] || { echo "❌ сумма трафика: ждали 333300, получили $got"; exit 1; }

echo "✅ total_traffic: локальные + пиры, обе стороны, битые строки не в счёт"
