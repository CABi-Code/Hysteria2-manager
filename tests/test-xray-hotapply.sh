#!/bin/bash
# Горячее применение состава юзеров Xray без рестарта (lib/protocols.sh,
# _proto_xray_hot_apply): когда дельта уезжает через adu/rmu, а когда надо
# честно рестартовать. Ломается тихо — юзер остаётся без доступа, — поэтому
# проверяем и путь отката.
# Запуск: bash tests/test-xray-hotapply.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export HY2M_DATA_DIR=$(mktemp -d)
export HY2M_WEBROOT="$HY2M_DATA_DIR/web"
mkdir -p "$HY2M_WEBROOT"
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT

# Заглушка xray: пишет аргументы в лог, код возврата берёт из файла.
export XRAY_BIN="$HY2M_DATA_DIR/xray"
CALLS="$HY2M_DATA_DIR/calls"; RC_FILE="$HY2M_DATA_DIR/rc"
echo 0 > "$RC_FILE"; : > "$CALLS"
cat > "$XRAY_BIN" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$CALLS"
exit \$(cat "$RC_FILE")
EOF
chmod +x "$XRAY_BIN"

source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/protocols.sh"

# systemctl в отдельный лог — в $CALLS должны быть только вызовы xray.
SYSCALLS="$HY2M_DATA_DIR/syscalls"; : > "$SYSCALLS"
systemctl() { printf '%s\n' "$*" >> "$SYSCALLS"; return 0; }

mkdir -p "$PROTO_DIR"
printf 'PROTO_VLESS_ENABLED=1\nPROTO_TROJAN_ENABLED=1\n' > "$PROTO_CONF"

# Конфиг Xray руками: proto_write_xray_config тянет ключи REALITY через сам
# бинарник, а он тут заглушка. Нам важна только форма — инбаунды с clients
# плюс api без clients (он обязан отсеиваться).
write_cfg() {   # port
    cat > "$XRAY_CONFIG" <<EOF
{"inbounds":[
 {"listen":"0.0.0.0","port":${1},"protocol":"vless","tag":"vless-in","settings":{"clients":[],"decryption":"none"}},
 {"listen":"0.0.0.0","port":8444,"protocol":"trojan","tag":"trojan-in","settings":{"clients":[]}},
 {"listen":"127.0.0.1","port":10085,"protocol":"dokodemo-door","tag":"api","settings":{"address":"127.0.0.1"}}
],"outbounds":[{"protocol":"freedom"}]}
EOF
}
write_cfg 8443
users() { printf '%s\n' "$@" > "$USERS_DB"; }
users u1:pass1 u2:pass2

reset_calls() { : > "$CALLS"; }
count() { grep -c -- "$1" "$CALLS" 2>/dev/null; }

FAIL=0
ok()   { echo "  ✅ $1"; }
bad()  { echo "  ❌ $1"; FAIL=1; }
is()   { [ "$2" = "$3" ] && ok "$1" || bad "$1 (ждали «$3», получили «$2»)"; }

echo "── Горячее применение состава Xray ──"

# 1. Состояния нет — на лету применять не от чего, нужен рестарт.
_proto_xray_hot_apply; is "без состояния → рестарт" "$?" 1

# 2. Состав не менялся — ни одного вызова API, рестарт не нужен.
_proto_xray_save_state
reset_calls
_proto_xray_hot_apply; is "состав не менялся → без рестарта" "$?" 0
is "  и без вызовов API" "$(wc -l < "$CALLS")" 0

# 3. Добавился юзер — один adu, ни одного rmu, рестарта нет.
users u1:pass1 u2:pass2 u3:pass3
reset_calls
_proto_xray_hot_apply; is "новый юзер → без рестарта" "$?" 0
is "  один adu"     "$(count ' adu ')" 1
is "  ноль rmu"     "$(count ' rmu ')" 0
grep -q '^u3	' "$XRAY_APPLIED_USERS" && ok "  состояние учло u3" || bad "  состояние не учло u3"

# 4. Юзер удалён — rmu по каждому включённому тегу (vless-in, trojan-in).
users u1:pass1 u3:pass3
reset_calls
_proto_xray_hot_apply; is "юзер удалён → без рестарта" "$?" 0
is "  rmu по обоим тегам" "$(count ' rmu ')" 2
is "  ноль adu"           "$(count ' adu ')" 0

# 5. Сменился пароль — ключи производны от него, значит снять и завести заново.
users u1:pass1 u3:CHANGED
reset_calls
_proto_xray_hot_apply; is "смена пароля → без рестарта" "$?" 0
is "  rmu по обоим тегам" "$(count ' rmu ')" 2
is "  и один adu"         "$(count ' adu ')" 1

# 6. Изменились параметры узла (порт) — состав тут ни при чём, только рестарт.
write_cfg 9443
reset_calls
_proto_xray_hot_apply; is "сменился порт → рестарт" "$?" 1
is "  API не трогали" "$(wc -l < "$CALLS")" 0

# 7. adu упал — откатываемся к рестарту и НЕ считаем состав применённым,
#    иначе юзер навсегда остался бы без доступа при живом состоянии.
write_cfg 8443
_proto_xray_save_state
before=$(cat "$XRAY_APPLIED_USERS")
echo 1 > "$RC_FILE"
users u1:pass1 u3:CHANGED u9:pass9
reset_calls
_proto_xray_hot_apply; is "adu упал → рестарт" "$?" 1
is "  состояние не тронуто" "$(cat "$XRAY_APPLIED_USERS")" "$before"
ls "$PROTO_DIR"/.xray.users.* "$PROTO_DIR"/.xray.adu.* >/dev/null 2>&1 \
    && bad "  временные файлы остались" || ok "  временные файлы убраны"

echo
[ "$FAIL" = 0 ] && echo "✅ Все проверки прошли" || echo "❌ Есть падения"
exit "$FAIL"
