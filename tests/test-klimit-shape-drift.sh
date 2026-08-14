#!/bin/bash
# Регрессия: klimit_sync_port обязан считать дрейфом и ОТСУТСТВИЕ SHAPE.
# klimit.conf, записанный до появления SHAPE, откатывается на фолбэк «17:$PORT» —
# шейпится только Hysteria, а VLESS/Trojan/TUIC/SS идут мимо лимита. Такая нода
# показывает сотни Мбит вместо глобального лимита, и раньше не лечилась никогда:
# ветку SHAPE-дрейфа закрывал guard [ -n "$saved_shape" ].
cd "$(dirname "$0")/.." || exit 1

export HY2M_DATA_DIR; HY2M_DATA_DIR=$(mktemp -d)
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT

DATA_DIR="$HY2M_DATA_DIR"
KLIMIT_CONF="$DATA_DIR/klimit.conf"
source lib/perf.sh 2>/dev/null

fail() { echo "❌ $1"; exit 1; }

# Заглушки вместо реального окружения ноды: klimit_apply только отмечается.
APPLIED=""
klimit_apply() { APPLIED="$1/$2"; }
klimit_down()  { echo 30; }
klimit_up()    { echo 30; }
klimit_get()   { grep -oP "^$1=\K.*" "$KLIMIT_CONF" 2>/dev/null | head -1; }
get_port()     { echo "$PORT_MOCK"; }
_klimit_shape_ports() { echo "$SHAPE_MOCK"; }

run() {  # <конфиг> <порт> <вычисленный SHAPE> -> APPLIED
    printf '%s\n' "$1" > "$KLIMIT_CONF"
    PORT_MOCK="$2"; SHAPE_MOCK="$3"; APPLIED=""
    klimit_sync_port
    echo "$APPLIED"
}

# 1. Старый конфиг без SHAPE — главный случай: должен перегенерироваться.
[ -n "$(run 'DOWN_MBIT=30
PORT=38268' 38268 '17:38268 6:8443')" ] \
    || fail "конфиг без SHAPE не признан дрейфом — нода останется с шейпингом одного Hysteria"

# 2. SHAPE на месте и совпадает — не трогаем живой шейпинг.
[ -z "$(run 'DOWN_MBIT=30
PORT=38268
SHAPE=17:38268 6:8443' 38268 '17:38268 6:8443')" ] \
    || fail "SHAPE совпадает, а лимит всё равно пересобирается"

# 3. Включили протокол — запечённый SHAPE отстал.
[ -n "$(run 'DOWN_MBIT=30
PORT=38268
SHAPE=17:38268' 38268 '17:38268 6:8443')" ] \
    || fail "устаревший SHAPE не признан дрейфом"

# 4. Порт Hysteria не читается — пересобирать не на чем, конфиг не ломаем.
[ -z "$(run 'DOWN_MBIT=30
PORT=38268
SHAPE=17:38268 6:8443' '' '17:')" ] \
    || fail "лимит пересобран при нечитаемом порте Hysteria"

echo "✅ klimit: отсутствующий SHAPE лечится сам (шейпятся все протоколы, не только Hysteria)"
