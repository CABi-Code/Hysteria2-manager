#!/bin/bash
# Слоты, фаза A: у каждой доп. ссылки подписки свой пароль Hysteria, и скрипт
# аутентификации принимает их наравне с базовым (docs/design/SLOTS).
# Запуск: bash tests/test-slots.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export HY2M_DATA_DIR=$(mktemp -d)
export HY2M_WEBROOT="$HY2M_DATA_DIR/web"
mkdir -p "$HY2M_WEBROOT/sub" "$HY2M_WEBROOT/cluster" "$HY2M_DATA_DIR/peers"
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT

source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/limits.sh"
source "$SCRIPT_DIR/lib/sub_links.sh"

fail() { echo "❌ $1"; exit 1; }

get_user_password() { awk -F: -v u="$1" '$1==u{print substr($0,length($1)+2); exit}' "$USERS_DB"; }
service_identity()  { echo "root root"; }
secure_auth_files() { chmod 700 "$AUTH_SCRIPT" 2>/dev/null; }   # живёт в users.sh, тут не нужен

printf 'ann:basepass123\nbob:otherpass\n' > "$USERS_DB"
: > "$SUBTOKENS_DB"
set_user_limits ann 3 0 "" 0

primary=$(sub_token_for ann)
extra1=$(sub_link_add ann)
extra2=$(sub_link_add ann)
[ -n "$extra1" ] && [ -n "$extra2" ] || fail "доп. ссылки не создались (лимит 3 устройства)"

# ---------- у каждой ссылки свой пароль, и он стабилен ----------
p1=$(sub_token_password ann "$extra1")
p2=$(sub_token_password ann "$extra2")
[ -n "$p1" ] && [ ${#p1} -eq 32 ] || fail "пароль слота пустой или не той длины: [$p1]"
[ "$p1" != "$p2" ] || fail "разные ссылки дали ОДИН пароль"
[ "$p1" != "basepass123" ] || fail "пароль слота совпал с базовым"
[ "$p1" = "$(sub_token_password ann "$extra1")" ] || fail "пароль слота не стабилен"
[ "$p1" != "$(sub_token_password bob "$extra1")" ] || fail "пароль слота не зависит от юзера"

# ---------- справочник для auth ----------
write_slotpass_db
grep -qF "ann|$p1|$extra1" "$SLOTPASS_DB" || fail "пароля слота нет в справочнике"

# id слота: «юзер.<8 hex>», стабилен и различает ссылки
sid1=$(sub_token_slotid ann "$extra1"); sid2=$(sub_token_slotid ann "$extra2")
[[ "$sid1" =~ ^ann\.[0-9a-f]{8}$ ]] || fail "id слота не той формы: [$sid1]"
[ "$sid1" != "$sid2" ] || fail "две ссылки дали один id слота"
[ "$sid1" = "$(sub_token_slotid ann "$extra1")" ] || fail "id слота не стабилен"
grep -qF "|$sid1" "$SLOTPASS_DB" || fail "id слота нет в справочнике"
grep -qF "|$primary" "$SLOTPASS_DB" || fail "основного токена нет в справочнике — на другой ноде его пароль не примут"

# ---------- скрипт аутентификации ----------
source "$SCRIPT_DIR/lib/migration.sh"
install_auth_script
chmod +x "$AUTH_SCRIPT"

"$AUTH_SCRIPT" "1.2.3.4:100" "ann:basepass123" 0 >/dev/null || fail "базовый пароль перестал пускать"
out=$("$AUTH_SCRIPT" "1.2.3.4:100" "ann:$p1" 0) || fail "пароль слота не пустили"
[ "$out" = "$sid1" ] || fail "auth вернул [$out], а должен id слота $sid1 — иначе сессии слотов не различить"
out=$("$AUTH_SCRIPT" "1.2.3.4:100" "ann:basepass123" 0)
[ "$out" = "ann" ] || fail "базовый пароль должен остаться под именем юзера (иначе порвётся история трафика)"
"$AUTH_SCRIPT" "1.2.3.4:100" "ann:$p2" 0 >/dev/null || fail "вторая ссылка не пустила"
"$AUTH_SCRIPT" "1.2.3.4:100" "ann:нетакой" 0 >/dev/null 2>&1 && fail "пустили с мусорным паролем"
"$AUTH_SCRIPT" "1.2.3.4:100" "bob:$p1" 0 >/dev/null 2>&1 && fail "чужой пароль слота пустил другого юзера"

# ---------- подписка отдаёт пароль слота ----------
node_name()   { echo testnode; }
node_host()   { echo test.example; }
link_host()   { echo test.example; }
get_port()    { echo 443; }
get_obfs_pass() { echo obfs; }
get_sni()     { echo test.example; }
render_tag()  { echo "$1"; }
sub_all_users() { echo ann; }
sub_enabled() { return 0; }
write_sub_titles() { return 1; }
refresh_online() { CACHED_ONLINE='{}'; }
_tag_needs_online() { return 1; }
_title_needs_online() { return 1; }

regen_subscriptions

decode() { base64 -d < "$WEBROOT/sub/$1"; }
decode "$primary" | grep -q "hysteria2://ann:basepass123@" || fail "основная ссылка потеряла базовый пароль"
decode "$extra1"  | grep -q "hysteria2://ann:${p1}@"       || fail "доп. ссылка не отдала пароль своего слота"
decode "$extra1"  | grep -q "hysteria2://ann:basepass123@" && fail "доп. ссылка всё ещё отдаёт базовый пароль"
[ "$(decode "$extra1")" != "$(decode "$extra2")" ] || fail "две доп. ссылки отдали одинаковое содержимое"

# ---------- токен чужой ноды остаётся на базовом пароле ----------
# У той ноды он основной: подставь мы свой пароль слота, устройство пришло бы к
# ней с кредом, которого она для этого токена не ждёт.
peertok="peertokenfromanothernode000000000000000"
printf 'ann:%s\n' "$peertok" > "$PEERS_DIR/other.subtokens"
regen_subscriptions
decode "$peertok" | grep -q "hysteria2://ann:basepass123@" || fail "чужой токен подменили паролем слота"
grep -qF "ann|$(sub_token_password ann "$peertok")|$peertok" "$SLOTPASS_DB" || fail "пароль чужого токена не принимается этой нодой"

echo "✅ test-slots: ok"

# ---------- кик юзера рвёт и слоты ----------
# Слоты живут под своими id, поэтому кик по одному имени оставил бы их работать.
source "$SCRIPT_DIR/lib/api.sh"
API_PORT=1; KICKED=""
api_post() { KICKED="$2"; }
hy_kick_user ann
for want in "\"ann\"" "\"$sid1\"" "\"$sid2\""; do
    case "$KICKED" in *"$want"*) : ;; *) fail "кик не задел $want (отправлено: $KICKED)" ;; esac
done
hy_kick_user bob
case "$KICKED" in *"$sid1"*) fail "кик bob задел слоты ann: $KICKED" ;; esac

# ---------- фаза D: отказ по числу СЕССИЙ слота ----------
# Поднимаем заглушку API Hysteria: /online отдаёт заданный JSON, /kick пишет в файл.
API_STATE="$HY2M_DATA_DIR/online.json"; KICKLOG="$HY2M_DATA_DIR/kicks.log"
echo '{}' > "$API_STATE"; : > "$KICKLOG"
export API_PORT=25599
python3 - "$API_STATE" "$KICKLOG" "$API_PORT" <<'PYEOF' &
import sys, json
from http.server import BaseHTTPRequestHandler, HTTPServer
state, kicklog, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        body = open(state, "rb").read()
        self.send_response(200); self.send_header("Content-Type","application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        with open(kicklog, "a") as f: f.write(self.rfile.read(n).decode() + "\n")
        self.send_response(200); self.send_header("Content-Length","2"); self.end_headers(); self.wfile.write(b"{}")
HTTPServer(("127.0.0.1", port), H).serve_forever()
PYEOF
STUB=$!
trap 'kill $STUB 2>/dev/null; rm -rf "$HY2M_DATA_DIR"' EXIT
for _ in $(seq 1 40); do curl -s --max-time 1 "http://127.0.0.1:$API_PORT/online" >/dev/null 2>&1 && break; sleep 0.1; done

echo "secret" > "$API_SECRET_FILE"
: > "$SLOTMAP_FILE"; : > "$NODE_CONF"
install_auth_script

# Рубильник выключен — сессии никого не волнуют.
printf '{"%s":5}\n' "$sid1" > "$API_STATE"
"$AUTH_SCRIPT" "10.0.0.2:100" "ann:$p1" 0 >/dev/null || fail "рубильник выключен, а отказ уже случился"

printf 'SLOT_REJECT=1\n' > "$NODE_CONF"
"$AUTH_SCRIPT" "10.0.0.2:100" "ann:$p1" 0 >/dev/null 2>&1 && fail "занятый слот пустил второе устройство"
[ -s "$KICKLOG" ] && fail "занявшего слот трогать нельзя: иначе проверка пинга у клиента рвёт его же туннель"

# Второе устройство с ТОГО ЖЕ адреса — тоже отказ: ради этого и делались слоты,
# за домашним NAT адрес один, различает только счётчик сессий слота.
: > "$KICKLOG"
"$AUTH_SCRIPT" "10.0.0.1:100" "ann:$p1" 0 >/dev/null 2>&1 && fail "второе устройство с того же адреса прошло — слоты бессмысленны"

# Слот пуст — пускаем.
printf '{"%s":0,"ann":3}\n' "$sid1" > "$API_STATE"
"$AUTH_SCRIPT" "10.0.0.2:100" "ann:$p1" 0 >/dev/null || fail "пустой слот не пустил"

# Соседний слот занят — нам всё равно.
printf '{"%s":9}\n' "$sid2" > "$API_STATE"
"$AUTH_SCRIPT" "10.0.0.2:100" "ann:$p1" 0 >/dev/null || fail "чужой занятый слот перекрыл наш"

# Порог настраивается: с SLOT_MAX_SESSIONS=2 одна сессия ещё не занятость.
printf 'SLOT_REJECT=1\nSLOT_MAX_SESSIONS=2\n' > "$NODE_CONF"
printf '{"%s":1}\n' "$sid1" > "$API_STATE"
"$AUTH_SCRIPT" "10.0.0.2:100" "ann:$p1" 0 >/dev/null || fail "порог 2 не даёт пройти при одной сессии"
printf '{"%s":2}\n' "$sid1" > "$API_STATE"
"$AUTH_SCRIPT" "10.0.0.2:100" "ann:$p1" 0 >/dev/null 2>&1 && fail "порог 2 не сработал на двух сессиях"

# API недоступен — пускаем (fail-open): аутентификация не падает из-за него.
printf 'SLOT_REJECT=1\n' > "$NODE_CONF"
kill $STUB 2>/dev/null; wait $STUB 2>/dev/null
"$AUTH_SCRIPT" "10.0.0.2:100" "ann:$p1" 0 >/dev/null || fail "API молчит, а вход закрылся"

echo "✅ test-slots (фаза D): ok"
