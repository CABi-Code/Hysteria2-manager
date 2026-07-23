#!/bin/bash
# Регрессия: klimit.sh apply ОБЯЗАН снести подпись раскладки (KLIMIT_SIG), иначе
# после ребута/рестарта hy2-limit каркас пересобирается, пер-IP тарифные фильтры
# стираются, а klimit_reconcile (совпала подпись) их НЕ восстанавливает — и все
# тарифные/демо-клиенты молча уезжают в глобальный класс вместо своего лимита.
# Проверяем СТАТИЧЕСКИ (скрипт не запускаем: apply трогает реальный tc-интерфейс).
cd "$(dirname "$0")/.." || exit 1

export HY2M_DATA_DIR; HY2M_DATA_DIR=$(mktemp -d)
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT

# Мокаем то, что нужно _klimit_write_script (пути KLIMIT_*), без полного config.sh.
DATA_DIR="$HY2M_DATA_DIR"
KLIMIT_SCRIPT="$DATA_DIR/klimit.sh"
KLIMIT_SIG="$DATA_DIR/klimit_reconcile.sig"
source lib/perf.sh 2>/dev/null

_klimit_write_script 5 5 38268 "5 20" "17:38268 6:8443"

fail() { echo "❌ $1"; exit 1; }

grep -q "^SIG=${KLIMIT_SIG}" "$KLIMIT_SCRIPT" || fail "в klimit.sh нет SIG=<путь к подписи>"

# Внутри ветки apply) до сборки каркаса должен стоять снос подписи.
awk '/^[[:space:]]*apply\)/{a=1} a&&/rm -f "\$SIG"/{ok=1} a&&/detect_dev/{exit} END{exit(ok?0:1)}' \
    "$KLIMIT_SCRIPT" || fail "apply не сносит \$SIG перед пересборкой каркаса"

echo "✅ klimit: apply инвалидирует подпись раскладки (пер-IP восстановится после рестарта)"
