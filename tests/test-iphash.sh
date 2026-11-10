#!/bin/bash
# Адреса клиентов — только хэшем (P-176): соль кластера по месяцам, разовая
# миграция открытых адресов, ротация, auth-скрипт, сборщики и обмен с соседями.
# Главная проверка — «ни одного IPv4 в файлах данных», а не «функция вызвана».
# Запуск: bash tests/test-iphash.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export HY2M_DATA_DIR=$(mktemp -d)
export HY2M_WEBROOT="$HY2M_DATA_DIR/web"
export HY2M_RAW_DIR="$HY2M_DATA_DIR/run"
export HY2M_TMPFILES_CONF="$HY2M_DATA_DIR/tmpfiles.conf"
mkdir -p "$HY2M_WEBROOT/cluster" "$HY2M_DATA_DIR/peers"
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT

source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/ip_tracking.sh"
source "$SCRIPT_DIR/lib/migration.sh"
source "$SCRIPT_DIR/lib/cluster.sh"

FAIL=0
ok()    { echo "  ✅ $1"; }
bad()   { echo "  ❌ $1"; FAIL=1; }
check() { [ "$2" = "$3" ] && ok "$1" || bad "$1: ждали «$3», получили «$2»"; }
no_ipv4() {   # описание файл...
    local d="$1" f hit=""; shift
    for f in "$@"; do
        [ -f "$f" ] || continue
        grep -qE '(^|[^0-9.])(1\.2\.3\.4|5\.6\.7\.8|9\.9\.9\.9)([^0-9.]|$)' "$f" && hit="$hit $(basename "$f")"
    done
    [ -z "$hit" ] && ok "$d" || bad "$d: открытые адреса в$hit"
}
service_identity() { echo "root root"; }
h() { printf '%s\n' "$1" | ip_hash_map | cut -f2; }
NOW=$(date +%s)

echo "── соль: одна на кластер, своя на месяц"
printf 'cluster-secret-of-test\n' > "$CLUSTER_SECRET_FILE"
s1=$(python3 "$IPHASH_PY" derive "$CLUSTER_SECRET_FILE" 202611)
cp "$CLUSTER_SECRET_FILE" "$HY2M_DATA_DIR/other.secret"
s2=$(python3 "$IPHASH_PY" derive "$HY2M_DATA_DIR/other.secret" 202611)
s3=$(python3 "$IPHASH_PY" derive "$CLUSTER_SECRET_FILE" 202612)
check "у двух нод с одним секретом соль совпадает" "$s1" "$s2"
[ "$s1" != "$s3" ] && ok "новый месяц — новая соль" || bad "соль не сменилась с месяцем"

echo "── разовая миграция: всё открытое становится хэшами"
printf 'alice|1.2.3.4|%s|%s|3\n' "$NOW" "$NOW" > "$IPS_FILE"
printf 'tok123|5.6.7.8|%s|%s|1\n' "$NOW" "$NOW" > "$SUBIPS_FILE"
{ printf 'alice|1.2.3.4|%s\n' $(( NOW - 60 )); printf 'alice|9.9.9.9|%s\n' $(( NOW - 7200 )); } > "$AUTHMAP_FILE"
printf 'alice|-|1.2.3.4|%s\n' "$NOW" > "$SLOTMAP_FILE"
printf 'alice\t1\t0\t0\t0\t0\t1\t100\t1.2.3.4,5.6.7.8\n' > "$PEERS_DIR/a.stats"
printf 'alice|9.9.9.9|1|2|1\n' > "$PEERS_DIR/a.ips"
printf '2026-11-10 04:00:00 alice: cluster=2 local=1 | auth=[1.2.3.4@5s]\n' > "$DATA_DIR/limit.log"
printf 'alice|1.2.3.4\n' > "$DATA_DIR/onlineips.dat"
ip_salt_sync
[ -s "$IP_SALT_FILE" ] && ok "соль выдана" || bad "соли нет"
no_ipv4 "в файлах данных и кэше соседей адресов не осталось" \
    "$IPS_FILE" "$SUBIPS_FILE" "$AUTHMAP_FILE" "$SLOTMAP_FILE" "$PEERS_DIR/a.stats" "$PEERS_DIR/a.ips" "$DATA_DIR/limit.log"
H=$(h 1.2.3.4)
check "один адрес — один хэш во всех файлах" \
    "$(cut -d'|' -f2 "$IPS_FILE")/$(head -1 "$AUTHMAP_FILE" | cut -d'|' -f2)/$(cut -f9 "$PEERS_DIR/a.stats" | cut -d, -f1)" "$H/$H/$H"
check "tc-раскладка получила последний час настоящих адресов" "$(cut -d'|' -f2 "$RAW_AUTHMAP" | paste -sd, -)" "1.2.3.4"
[ ! -f "$DATA_DIR/onlineips.dat" ] && ok "сирота onlineips.dat удалён" || bad "onlineips.dat остался"
ip_rotation_quiet && ok "сразу после выдачи соли кики молчат" || bad "нет тихого окна после выдачи соли"

echo "── auth-скрипт: на диск хэш, в память — адрес"
printf 'bob:pw\n' > "$USERS_DB"
secure_auth_files() { :; }
install_auth_script; chmod +x "$AUTH_SCRIPT"
: > "$AUTHMAP_FILE"; : > "$SLOTMAP_FILE"; : > "$RAW_AUTHMAP"
out=$(bash "$AUTH_SCRIPT" "5.6.7.8:4444" "bob:pw" 0)
check "вход по паролю как раньше" "$out" "bob"
check "authmap.dat — хэш" "$(cut -d'|' -f2 "$AUTHMAP_FILE")" "$(h 5.6.7.8)"
check "slotmap.dat — хэш" "$(cut -d'|' -f3 "$SLOTMAP_FILE")" "$(h 5.6.7.8)"
check "настоящий адрес — только в RAW_DIR" "$(cut -d'|' -f2 "$RAW_AUTHMAP")" "5.6.7.8"
bash "$AUTH_SCRIPT" "5.6.7.8:4444" "bob:bad" 0 >/dev/null && bad "неверный пароль пустили" || ok "неверный пароль — отказ"

echo "── сборщики: журнал Hysteria и лог Caddy"
SERVICE=hysteria-server; LAST_LOG_TS="$HY2M_DATA_DIR/last_log_ts"; SUBLOG_TS="$HY2M_DATA_DIR/sublog_ts"
journalctl() {
    case "$*" in
        *hysteria-server*)
            printf '%s\n' 'INFO client connected {"addr": "'"$(h 9.9.9.9)"':1111", "id": "carol"}' \
                          'INFO client connected {"addr": "1.2.3.4:2222", "id": "dave"}' ;;
    esac
}
: > "$IPS_FILE"
collect_ips
check "хэш из журнала принят как адрес" "$(grep '^carol|' "$IPS_FILE" | cut -d'|' -f2)" "$(h 9.9.9.9)"
check "строка журнала до фильтра — тоже в хэш" "$(grep '^dave|' "$IPS_FILE" | cut -d'|' -f2)" "$(h 1.2.3.4)"
printf '%s\n' '{"request":{"remote_ip":"5.6.7.8","uri":"/sub/tokABC","headers":{"User-Agent":["Happ/1.2.3.4/android"]}}}' > "$CADDY_RAW_LOG"
: > "$SUBIPS_FILE"
collect_sub_ips
check "адрес скачавшего подписку — хэш" "$(grep '^tokABC|' "$SUBIPS_FILE" | cut -d'|' -f2)" "$(h 5.6.7.8)"
[ ! -s "$CADDY_RAW_LOG" ] && ok "лог Caddy обнулён после разбора" || bad "лог Caddy с адресами остался"
no_ipv4 "в собранных файлах адресов нет" "$IPS_FILE" "$SUBIPS_FILE"
ls "$RAW_DIR"/tmp.* >/dev/null 2>&1 && bad "промежуточный файл сборщика остался" || ok "промежуточный файл убран"

echo "── сосед на старой версии шлёт адреса открытыми"
cluster_secret() { echo s; }
curl() { printf 'alice\t1\t0\t0\t0\t0\t1\t100\t1.2.3.4\n'; }
check "в кэш соседа адрес ложится хэшем" "$(cluster_call peer.example /cluster/stats | cut -f9)" "$(h 1.2.3.4)"
curl() { printf 'manifest 1.2.3.4\n'; }
check "чужие разделы хэшер не трогает" "$(cluster_call peer.example /cluster/manifest)" "manifest 1.2.3.4"
unset -f curl

echo "── смена месяца"
printf 'alice|%s|1|2|1\n' "$H" > "$IPS_FILE"
printf 'alice|%s|1|2|1\n' "$H" > "$PEERS_DIR/a.ips"
printf '200001 oldsalt 1\n' > "$IP_SALT_FILE"
ip_rotation_quiet && bad "тихое окно не должно длиться месяцами" || ok "старая смена — окно давно закрыто"
ip_salt_sync
check "эпоха обновилась" "$(awk '{print $1}' "$IP_SALT_FILE")" "$(date -u +%Y%m)"
check "хэши прошлого месяца стёрты" "$(wc -c < "$IPS_FILE")" "0"
[ ! -f "$PEERS_DIR/a.ips" ] && ok "кэш адресов соседа стёрт" || bad "кэш адресов соседа остался"
ip_rotation_quiet && ok "после смены соли кики молчат" || bad "нет тихого окна после смены"

echo "── каталоги в памяти: владельцы-писатели заранее"
service_identity() { echo "nobody nogroup"; }
raw_dirs_ensure
check "authmap.raw принадлежит юзеру сервиса" "$(stat -c %U "$RAW_AUTHMAP" 2>/dev/null)" "nobody"
if id caddy >/dev/null 2>&1; then
    # caddy validate от root открыл бы лог сам и создал его root:600 — Caddy не стартовал бы.
    check "лог Caddy создан заранее и принадлежит caddy" "$(stat -c %U "$CADDY_RAW_LOG" 2>/dev/null)" "caddy"
fi
chown root "$RAW_AUTHMAP"; raw_dirs_ensure
check "чужой владелец исправляется на следующем прогоне" "$(stat -c %U "$RAW_AUTHMAP")" "nobody"
check "тест с подменённым DATA_DIR не трогает боевой /run" \
    "$(env -u HY2M_RAW_DIR -u HY2M_TMPFILES_CONF HY2M_DATA_DIR=/x bash -c 'source "'"$SCRIPT_DIR"'/lib/config.sh"; source "'"$SCRIPT_DIR"'/lib/ip_tracking.sh"; echo "$RAW_DIR $TMPFILES_CONF"')" \
    "/x/run /x/tmpfiles.conf"
service_identity() { echo "root root"; }

echo "── без соли адрес не уходит открытым"
check "нет соли — «?»" "$(printf '1.2.3.4\n' | python3 "$IPHASH_PY" scrub "$HY2M_DATA_DIR/none")" "?"

[ "$FAIL" = 0 ] && echo "✅ test-iphash: адреса только хэшем" || { echo "❌ test-iphash"; exit 1; }
