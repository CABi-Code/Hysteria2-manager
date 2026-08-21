#!/bin/bash
# Право на забвение: erase_user стирает ВСЕ следы человека, а метки удаления
# оставляет — без них профиль и привязка Telegram вернутся с соседней ноды.
#   • строки данных по имени, слоту-устройству и токенам подписки;
#   • строки журналов, где имя стоит внутри строки события;
#   • чужие строки не трогает, в том числе с похожим именем (cab / cabi);
#   • cluster_state.dat и tgusers.dat из обхода исключены.
# Запуск: bash tests/test-erase-user.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export HY2M_DATA_DIR=$(mktemp -d)
export HY2M_WEBROOT="$HY2M_DATA_DIR/web"
mkdir -p "$HY2M_WEBROOT/cluster" "$HY2M_DATA_DIR/peers"
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT

source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/users.sh"
# tgusers.dat ведёт lib/tgbot.sh — здесь нужен только путь к нему.
TGUSERS_FILE="$DATA_DIR/tgusers.dat"

# Заглушки того, что трогает систему: профиля в базе нет, значит delete_user не
# зовётся, а публикация и кик не наше дело в этом тесте.
db_user_exists()   { return 1; }
is_user_disabled() { return 1; }
tg_user_chats()    { printf '378664180\n'; }
tg_unbind()        { printf '%s||%s\n' "$1" "$(date +%s)" >> "$TGUSERS_FILE"; }

fail() { echo "❌ $1"; exit 1; }

user=erased
token=TOKENabc123
slot=erased.9f9f9f9f
slottoken=SLOTtok456

# --- данные: строки жертвы, соседа с похожим именем и живого юзера
printf '%s|1.2.3.4|1|2|3\n%s|5.6.7.8|1|2|3\nerasedtwin|9.9.9.9|1|2|3\nalice|8.8.8.8|1|2|3\n' \
    "$user" "$slot" > "$IPS_FILE"
printf '%s|1.2.3.4|100\nalice|8.8.8.8|100\n' "$user" > "$AUTHMAP_FILE"
printf '%s|1.2.3.4|1|2|3\n%s|4.4.4.4|1|2|3\nLIVEtok|8.8.8.8|1|2|3\n' \
    "$token" "$slottoken" > "$SUBIPS_FILE"
printf '%s:%s\nalice:LIVEtok\n' "$user" "$token" > "$SUBTOKENS_DB"
printf '%s|pw|%s|%s\nalice|pw|LIVEtok|alice.1111\n' "$user" "$slottoken" "$slot" > "$SLOTPASS_DB"
printf '%s|active|1|2|3|4|5|6|7\nalice|active|1|2|3|4|5|6|7\n' "$user" > "$FREEPLAN_FILE"
printf '%s|1787000000\nalice|1787000000\n' "$user" > "$EXPIRY_TS_FILE"
printf '%s|1.2.3.4|1|2|3\nalice|8.8.8.8|1|2|3\n' "$user" > "$PEERS_DIR/peer1.ips"

# --- журналы: имя внутри строки события
printf '2026-08-11 11:26:06 %s: cluster=2 local=2 — кик\n' "$user" > "$DATA_DIR/limit.log"
printf '2026-08-11 11:26:06 erasedtwin: cluster=2 local=2 — кик\n' >> "$DATA_DIR/limit.log"
printf '1786435273|webapp|POST|/v1/users/%s/free-plan|200|1\n' "$user" > "$DATA_DIR/webapi_access.log"
printf '1786435273|webapp|GET|/v1/users/alice|200|1\n' >> "$DATA_DIR/webapi_access.log"

# --- метки удаления: их трогать нельзя
printf '%s|deleted|1787000000\n' "$user" > "$CLUSTER_STATE_FILE"
: > "$TGUSERS_FILE"

erase_user "$user" >/dev/null || fail "erase_user вернул ошибку"

# 1) следов нет нигде
for f in "$IPS_FILE" "$AUTHMAP_FILE" "$SUBIPS_FILE" "$SUBTOKENS_DB" "$SLOTPASS_DB" \
         "$FREEPLAN_FILE" "$EXPIRY_TS_FILE" "$PEERS_DIR/peer1.ips" \
         "$DATA_DIR/limit.log" "$DATA_DIR/webapi_access.log"; do
    grep -q "^${user}[|:.]" "$f" 2>/dev/null && fail "имя осталось в $(basename "$f")"
done
grep -q "$token"     "$SUBIPS_FILE" && fail "адрес по токену подписки остался"
grep -q "$slottoken" "$SUBIPS_FILE" && fail "адрес по токену слота остался"
grep -q "$slot"      "$IPS_FILE"    && fail "адреса слота-устройства остались"
# «erasedtwin» содержит «erased» — сверяем по границе, иначе тест врёт.
grep -q "${user}:"   "$DATA_DIR/limit.log" && fail "строка журнала лимита осталась"
grep -q "/v1/users/${user}/" "$DATA_DIR/webapi_access.log" && fail "строка аудита API осталась"

# 2) чужое на месте, включая похожее имя
grep -q '^alice|'      "$IPS_FILE"       || fail "потерян живой юзер в ips"
grep -q '^alice:'      "$SUBTOKENS_DB"   || fail "потерян токен живого юзера"
grep -q '^erasedtwin|' "$IPS_FILE"       || fail "унесло похожее имя из ips"
grep -q 'erasedtwin'   "$DATA_DIR/limit.log" || fail "унесло похожее имя из журнала"
grep -q 'LIVEtok'      "$SUBIPS_FILE"    || fail "унесло адрес живого токена"
grep -q '/v1/users/alice' "$DATA_DIR/webapi_access.log" || fail "унесло чужую строку аудита"

# 3) метки удаления на месте
grep -q "^${user}|deleted|" "$CLUSTER_STATE_FILE" || fail "снесена метка удаления профиля"
grep -q '^378664180||'      "$TGUSERS_FILE"       || fail "нет tombstone отвязки Telegram"

echo "✅ erase-user: следы стёрты, чужое цело, метки удаления сохранены"
