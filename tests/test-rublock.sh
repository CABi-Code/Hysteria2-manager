#!/bin/bash
# Блокировка РФ (lib/rublock.sh): вырезка .dat только с нужным кодом, блок acl
# Hysteria — идемпотентен, снимается по RU_BLOCK=0 и не лезет в чужой acl,
# профили маршрутизации в подписке — валидный JSON с тем же списком.
# Запуск: bash tests/test-rublock.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
RU_BLOCK=""
node_get() { [ "$1" = RU_BLOCK ] && printf '%s' "$RU_BLOCK"; }
_sub_b64() { printf '%s' "$1" | base64 -w0; }
systemctl() { echo restart >> "$T/restarts"; }
source "$SCRIPT_DIR/lib/rublock.sh"
PROTO_DIR="$T/proto"; RUBLOCK_GEO_DIR="$T/geo"; CONFIG="$T/config.yaml"
fail() { echo "❌ $1"; exit 1; }
restarts() { wc -l < "$T/restarts" 2>/dev/null || echo 0; }

# .dat: protobuf-список записей {1: код, 2: payload}. Собираем из трёх стран.
mkdir -p "$RUBLOCK_GEO_DIR"
python3 - "$RUBLOCK_GEO_DIR" <<'PY'
import sys
def rec(code, pl):
    e = b'\x0a' + bytes([len(code)]) + code + b'\x12' + bytes([len(pl)]) + pl
    return b'\x0a' + bytes([len(e)]) + e
for k in ('geoip', 'geosite'):
    open(f'{sys.argv[1]}/{k}.dat', 'wb').write(rec(b'CN', b'x'*5) + rec(b'RU', b'r'*7) + rec(b'CATEGORY-RU', b's'*3) + rec(b'US', b'y'*4))
PY
gi=$(_rublock_trim_dat geoip ru) || fail "вырезка geoip не собралась"
[ "$(python3 -c "import sys;print(open(sys.argv[1],'rb').read().count(b'RU'))" "$gi")" = 1 ] || fail "в вырезке geoip не ровно одна запись RU"
grep -q 'CN\|US\|CATEGORY' "$gi" && fail "в вырезку geoip попали чужие коды"
gs=$(_rublock_trim_dat geosite category-ru) || fail "вырезка geosite не собралась"
grep -q 'CATEGORY-RU' "$gs" || fail "нет category-ru в вырезке geosite"
_rublock_trim_dat geoip xx >/dev/null && fail "несуществующий код дал непустую вырезку"

# Hysteria: блок добавляется один раз, повтор ничего не меняет и не рестартует.
printf 'listen: :443\n' > "$CONFIG"
rublock_hysteria_apply
grep -q 'reject(geoip:ru)' "$CONFIG" || fail "acl не добавлен"
[ "$(restarts)" = 1 ] || fail "ожидали ровно один рестарт"
rublock_hysteria_apply
[ "$(restarts)" = 1 ] || fail "повторный apply рестартанул Hysteria"
[ "$(grep -c '^acl:' "$CONFIG")" = 1 ] || fail "acl задвоился"

RU_BLOCK=0; rublock_hysteria_apply
grep -q 'acl:\|rublock' "$CONFIG" && fail "RU_BLOCK=0 не снял блок"
RU_BLOCK=""

printf 'listen: :443\nacl:\n  inline:\n    - direct(all)\n' > "$CONFIG"
rublock_hysteria_apply
[ "$(grep -c '^acl:' "$CONFIG")" = 1 ] || fail "перетёрли/задвоили ручной acl"

# Подписка: оба профиля — валидный JSON и несут geoip:ru.
h=$(rublock_sub_headers)
echo "$h" | grep -oP 'onadd/\K[^"]+' | base64 -d | jq -e '.DirectIp|index("geoip:ru")' >/dev/null || fail "профиль Happ битый"
echo "$h" | grep -P 'rub_v2rt routing' | grep -oP '"\K[^"]+(?="$)' | base64 -d \
    | jq -e '.rules[1].ip|index("geoip:ru")' >/dev/null || fail "профиль v2RayTun битый"

# Xray/sing-box: фрагменты склеиваются в валидный JSON.
printf '[{}%s]' "$(rublock_xray_rules)" | jq -e 'length==3' >/dev/null || fail "правила Xray не JSON"
RU_BLOCK=0; [ -z "$(rublock_xray_rules)$(rublock_singbox_route)" ] || fail "RU_BLOCK=0 оставил правила"

echo "✅ rublock: все проверки прошли"
