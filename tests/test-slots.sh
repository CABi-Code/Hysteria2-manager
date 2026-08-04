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
grep -qF "|$primary" "$SLOTPASS_DB" || fail "основного токена нет в справочнике — на другой ноде его пароль не примут"

# ---------- скрипт аутентификации ----------
source "$SCRIPT_DIR/lib/migration.sh"
install_auth_script
chmod +x "$AUTH_SCRIPT"

"$AUTH_SCRIPT" "1.2.3.4:100" "ann:basepass123" 0 >/dev/null || fail "базовый пароль перестал пускать"
out=$("$AUTH_SCRIPT" "1.2.3.4:100" "ann:$p1" 0) || fail "пароль слота не пустили"
[ "$out" = "ann" ] || fail "auth вернул id [$out] вместо имени юзера — учёт развалится"
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
