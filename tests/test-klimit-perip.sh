#!/bin/bash
# Регрессия: класс скорости заводится на КАЖДЫЙ адрес, а не на величину тарифа.
# Раньше classid считался как 0x1000+rate, поэтому все адреса одного тарифа
# делили один класс, а все бестарифные — общий класс 1:1 на всю ноду: десять
# человек онлайн при лимите 30 получали по 3 Мбит/с. Проверяем без реального tc:
# подменяем его писателем в лог и разбираем, что именно менеджер попросил у ядра.
cd "$(dirname "$0")/.." || exit 1

export HY2M_DATA_DIR; HY2M_DATA_DIR=$(mktemp -d)
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT
DATA_DIR="$HY2M_DATA_DIR"
LOG="$DATA_DIR/tc.log"
source lib/perf.sh 2>/dev/null

fail() { echo "❌ $1"; exit 1; }

# Заглушка tc: показывает каркас с классами прошлого прохода и пишет остальные
# вызовы в лог. В каркасе намеренно есть 1:9999 (класс «без лимита» для
# не-туннельного трафика) и 1:ffff (общий класс) — уборка не должна их трогать.
tc() {
    case "$1 $2" in
        "qdisc show") echo "qdisc htb 1: root refcnt 2" ;;
        "class show") cat <<'T'
class htb 1:1 root rate 2000mbit
class htb 1:9999 root leaf 80ed: rate 10000mbit
class htb 1:ffff parent 1:1 leaf 80ee: rate 30mbit
class htb 1:2001 parent 1:1 leaf 80ef: rate 30mbit
T
            ;;
        *) printf '%s\n' "$*" >> "$LOG" ;;
    esac
}
export -f tc 2>/dev/null

declare -A DES=([10.0.0.1]=0 [10.0.0.2]=0 [10.0.0.3]=100)
_reconcile_dev dummy0 dst sport "17:38268 6:8443" 30

grep -q . "$LOG" || fail "не отдано ни одной команды tc"

# 1. Класс на каждый адрес: три адреса — три класса, все разные.
mapfile -t cls < <(grep '^class add' "$LOG" | grep -oP 'classid \K\S+' | sort -u)
[ "${#cls[@]}" -eq 3 ] || fail "классов ${#cls[@]}, а адресов 3 — класс всё ещё общий"

# 2. Все классы — дети потолка ноды 1:1.
[ "$(grep -c 'class add.*parent 1:1 ' "$LOG")" -eq 3 ] \
    || fail "пер-IP классы не подвешены под потолок ноды 1:1"

# 3. Потолки: без тарифа — общий лимит направления, с тарифом — тариф.
[ "$(grep -c 'class add.*ceil 30mbit' "$LOG")" -eq 2 ] \
    || fail "адрес без тарифа не получил класс на общий лимит направления"
grep -q 'class add.*ceil 100mbit' "$LOG" \
    || fail "адрес с тарифом 100 не получил класс на 100"

# 3a. Гарантия (rate) строго МЕНЬШЕ потолка (ceil). Если rate = ceil, HTB не
# спрашивает родителя, пока класс укладывается в свой rate, — и потолок ноды не
# действует вообще (замерено: два клиента по 30 при потолке 40 давали 53.7).
grep -q 'class add.*rate 30mbit ceil 30mbit' "$LOG" \
    && fail "гарантия равна потолку — потолок ноды перестанет держать"
grep -q 'class add.*rate 3mbit ceil 30mbit' "$LOG" \
    || fail "гарантия не равна десятой доле потолка"
grep -q 'class add.*rate 10mbit ceil 100mbit' "$LOG" \
    || fail "гарантия тарифного класса посчитана неверно"

# 4. Фильтр на каждый (адрес × протокол:порт), и каждый ведёт в свой класс.
[ "$(grep -c '^filter add' "$LOG")" -eq 6 ] \
    || fail "фильтров $(grep -c '^filter add' "$LOG"), ожидалось 6 (3 адреса × 2 порта)"
for c in "${cls[@]}"; do
    [ "$(grep -c "filter add.*flowid $c\$" "$LOG")" -eq 2 ] \
        || fail "в класс $c ведёт не 2 фильтра — адрес шейпится не на всех протоколах"
done

# 5. Раскладка сносится целиком перед пересборкой: сначала фильтры, потом классы
# (класс, на который ссылается фильтр, ядро удалить не даст).
grep -q '^filter del dev dummy0 parent 1: prio 1' "$LOG" || fail "старые пер-IP фильтры не сносятся"
[ "$(grep -n '^filter del' "$LOG" | head -1 | cut -d: -f1)" -lt \
  "$(grep -n '^class add' "$LOG" | head -1 | cut -d: -f1)" ] \
    || fail "классы заводятся раньше, чем снесены старые фильтры"
grep -q 'class del.*classid 1:2001' "$LOG" || fail "класс прошлого прохода не убран — миноры утекут"

# 6. Уборка бьёт ТОЛЬКО по своему диапазону. 0x9999 («без лимита», цель htb
# default) и 0xffff (общий класс) лежат выше него: снести их — значит отправить
# весь не-туннельный трафик ноды мимо дерева классов.
grep -q 'class del.*classid 1:9999' "$LOG" && fail "уборка снесла класс 1:9999 — htb default остался без класса"
grep -q 'class del.*classid 1:ffff' "$LOG" && fail "уборка снесла общий класс 1:ffff — catch-all повис"

echo "✅ klimit: класс скорости на каждый адрес, под общим потолком ноды"

# ---- Источники раскладки -----------------------------------------------------
# Адрес живого клиента обязан попасть в раскладку, даже если ни authmap, ни
# ips.dat про него не знают: authmap помнит адрес с момента аутентификации
# (долгая сессия из часового окна выпадает), а ips.dat ведётся по журналу
# Hysteria — клиента на Xray/TUIC там нет вовсе (P-18).
: > "$LOG"
AUTHMAP_FILE="$DATA_DIR/authmap.dat"; IPS_FILE="$DATA_DIR/ips.dat"
KLIMIT_SIG="$DATA_DIR/sig"
KLIMIT_CONF="$DATA_DIR/klimit.conf"; printf 'DOWN_MBIT=30\nUP_MBIT=30\n' > "$KLIMIT_CONF"
printf 'olduser|10.0.0.9|1\n' > "$AUTHMAP_FILE"      # ts=1 — заведомо старее часа
: > "$IPS_FILE"
CACHED_ONLINE_IPS='liveuser|203.0.113.7
ghost|?'
refresh_online() { :; }
klimit_get() { case "$1" in PORT) echo 38268 ;; SHAPE) echo "17:38268" ;; TARIFFS) echo "" ;; esac; }
klimit_down() { echo 30; }; klimit_up() { echo 30; }
get_user_rate() { echo 0; }
ip() { echo "default via 10.0.0.1 dev dummy0"; }

klimit_reconcile

grep -q 'match ip dst 203.0.113.7/32' "$LOG" \
    || fail "адрес клиента, который в сети прямо сейчас, не попал в раскладку"
grep -q '10.0.0.9' "$LOG" && fail "адрес старее часа всё-таки разложен"
grep -q '203.0.113.7.*flowid' "$LOG" || fail "для живого адреса не поставлен фильтр"
# По классу на направление (скачивание на самом интерфейсе, отдача через IFB).
[ "$(grep -c '^class add' "$LOG")" -eq 2 ] \
    || fail "классов $(grep -c '^class add' "$LOG"), ожидалось 2 (один адрес × два направления)"

echo "✅ klimit: адрес клиента в сети попадает в раскладку помимо authmap/ips"
