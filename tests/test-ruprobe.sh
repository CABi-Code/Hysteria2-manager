#!/bin/bash
# Проба из РФ (lib/ruprobe.sh): лестница подтверждений, слепая проба, живое
# сообщение эпизода, фильтр недоверенного ответа. Сеть и SSH не трогаем —
# _ruprobe_exec подменён и печатает то, что «ответила» проба.
set -u

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export HY2M_DATA_DIR="$TMP/data"
mkdir -p "$HY2M_DATA_DIR/peers"

cd "$(dirname "$0")/.." || exit 1
source lib/config.sh >/dev/null 2>&1
source lib/cluster.sh >/dev/null 2>&1
set +u; source lib/tgbot.sh >/dev/null 2>&1; set -u
source lib/ruprobe.sh >/dev/null 2>&1

fail() { echo "FAIL: $*"; exit 1; }

echo "RUPROBE_SSH=probe" > "$RUPROBE_CONF"
sub_tokens_all() { :; }
ruprobe_targets() { printf 'А|a.example|vless|8443|tcp\nА|a.example|https|443|tcp\nБ <b>|b.example|https|443|tcp\n'; }

ANSWER=""
_ruprobe_exec() { cat >/dev/null; printf '%s\n' "$ANSWER"; }
ok_all='_ru|ctl|0|ok|0|0
a.example|vless|8443|ok|300|65536
a.example|https|443|ok|300|65536
a.example|ping|0|ok|40|0
b.example|https|443|ok|300|65536
b.example|ping|0|ok|40|0'
a_frozen='_ru|ctl|0|ok|0|0
a.example|vless|8443|frz|20000|16384
a.example|https|443|ok|300|65536
a.example|ping|0|ok|40|0
b.example|https|443|ok|300|65536
b.example|ping|0|ok|40|0'

# --- 1. Всё доступно — молчание ---
ANSWER=$ok_all
[ -z "$(ruprobe_run)" ] || fail "при полной доступности что-то напечатано"

# --- 2. Один провал — шум, молчание; второй подряд — тревога ---
ANSWER=$a_frozen
[ -z "$(ruprobe_run)" ] || fail "одиночный провал объявлен"
out=$(ruprobe_run)
head -1 <<<"$out" | grep -qE '^ruprobe:[0-9]+$' || fail "первая строка не ключ: $out"
grep -q 'А · VLESS — обрыв после 16 КБ' <<<"$out" || fail "нет строки о замирании: $out"
key=$(head -1 <<<"$out")

# --- 3. Проба ослепла — вердикты по нодам не меняются, ключ тот же ---
ANSWER=""
out=$(ruprobe_run)
[ "$(head -1 <<<"$out")" = "$key" ] || fail "слепая проба сменила эпизод"
grep -q 'А · VLESS' <<<"$out" || fail "слепая проба стёрла инцидент"
grep -q 'Проба сама' <<<"$out" && fail "слепота объявлена с первого такта"

# --- 4. Недоверенный ответ: мусор и разметка отбрасываются ---
ANSWER="$a_frozen
a.example|vless|8443|<b>x</b>|1|1
rm -rf /|ping|0|ok|1|1"
out=$(ruprobe_run)
grep -q '<b>x' <<<"$out" && fail "разметка из ответа пробы попала в сообщение"
grep -q 'Б &lt;b&gt;' <<<"$(ANSWER='_ru|ctl|0|ok|0|0
b.example|https|443|cls|0|0
b.example|ping|0|ok|1|0
a.example|vless|8443|frz|1|20000'; ruprobe_run; ruprobe_run)" || fail "имя ноды не экранировано"

# --- 5. Всё вернулось — то же сообщение закрывается итогом ---
ANSWER=$ok_all
out=$(ruprobe_run)
[ "$(head -1 <<<"$out")" = "$key" ] || fail "закрытие пришло другим ключом"
grep -q 'снова всё доступно' <<<"$out" || fail "нет итога закрытия: $out"
grep -q 'А: VLESS' <<<"$out" || fail "итог не называет, что лежало: $out"

# --- 6. После хвоста — снова молчание ---
sed -i "s/^\([0-9]*\)|\([0-9]*\)|/\1|$(( $(date +%s) - RUPROBE_TAIL_SEC - 5 ))|/" "$RUPROBE_EPISODE"
[ -z "$(ruprobe_run)" ] || fail "закрытый эпизод печатается после хвоста"

# --- 7. Недоступны адреса всех нод — одно сообщение «весь кластер» ---
ANSWER='_ru|ctl|0|ok|0|0
a.example|ping|0|cls|0|100
b.example|ping|0|cls|0|100'
ruprobe_run >/dev/null; out=$(ruprobe_run)
[ "$(head -1 <<<"$out")" != "$key" ] || fail "новый эпизод получил старый ключ"
grep -q 'недоступен весь кластер</b> (2 из 2' <<<"$out" || fail "нет сообщения о всём кластере: $out"

# --- 8. Слепота дольше порога — о самой пробе ---
ANSWER=""
for _ in 1 2; do ruprobe_run >/dev/null; done
grep -q 'Проба сама не на связи' <<<"$(ruprobe_run)" || fail "долгая слепота не объявлена"

# --- 8б. Ключ служебного профиля не поднял туннель — своя причина ---
rm -f "$RUPROBE_STATE" "$RUPROBE_EPISODE"
ANSWER='_ru|ctl|0|ok|0|0
a.example|vless|8443|ok|1|65536
a.example|vless|8443|tun|1|0
a.example|ping|0|ok|1|0'
ruprobe_run >/dev/null
grep -q "VLESS — ключ не работает" <<<"$(ruprobe_run)" || fail "итог туннеля не перекрыл внешнюю проверку"

# --- 9. Без конфига функция молчит ---
rm -f "$RUPROBE_CONF"
[ -z "$(ruprobe_run)" ] || fail "без конфига что-то напечатано"

echo "OK: test-ruprobe"
