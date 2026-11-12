#!/bin/bash
# Единственный вход данных пира в кэш (peer_pull, lib/cluster.sh): форма
# ключевого поля, «пустой ответ кэш не затирает», обнуляемые разделы. Сеть не
# трогаем — curl подменён и раскладывает заготовленные ответы по своим -o.
# Сторожит P-138 (токен -> путь файла) и P-139 (имя -> адрес sed).
set -o pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export HY2M_DATA_DIR=$(mktemp -d)
export HY2M_WEBROOT="$HY2M_DATA_DIR/web"
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/node.sh"
source "$SCRIPT_DIR/lib/cluster.sh"

fail() { echo "FAIL: $*"; exit 1; }
ip_scrub() { cat; }
ANS="$HY2M_DATA_DIR/answers"; mkdir -p "$ANS" "$PEERS_DIR"
CURL_CALLS=0
# Подмена: «-o файл url» — кладём $ANS/<раздел>, если он есть (404 = файла нет).
curl() {
    CURL_CALLS=$((CURL_CALLS + 1))
    while [ $# -gt 0 ]; do
        if [ "$1" = "-o" ]; then
            [ -f "$ANS/${3##*/}" ] && cp "$ANS/${3##*/}" "$2"
            shift 3
        else shift; fi
    done
}

good_tok=abcdefghijklmnopqrstuvwxyz0123456789ABCD
printf 'ok|deleted|1\nx/d;s/^.*$/PWNED/;/|deleted|2\n../../etc/x|active|3\n' > "$ANS/state"
printf 'u:%s\nu:../../../etc/cron.d/x\nbad name:%s\n' "$good_tok" "$good_tok" > "$ANS/subtokens"
printf '#label|Нода\nu|1|2|3\n<b>|1|2|3\n' > "$ANS/rates"
printf '1||5\n1|u|5\n1|a b|5\n' > "$ANS/tgbind"
printf 'VER=1\nлюбой текст\n' > "$ANS/nodeinfo"

peer_pull peer.example P "state subtokens rates tgbind nodeinfo version" || fail "забор вернул отказ"
[ "$CURL_CALLS" = 1 ] || fail "разделы забраны не одним заходом: $CURL_CALLS"
[ "$(cat "$PEERS_DIR/P.state")" = "ok|deleted|1" ] || fail "state: $(cat "$PEERS_DIR/P.state")"
[ "$(cat "$PEERS_DIR/P.subtokens")" = "u:$good_tok" ] || fail "subtokens: $(cat "$PEERS_DIR/P.subtokens")"
[ "$(grep -c . "$PEERS_DIR/P.rates")" = 2 ] || fail "rates: шапка или строка потеряны"
[ "$(grep -c . "$PEERS_DIR/P.tgbind")" = 2 ] || fail "tgbind: отвязка (пустое имя) должна проходить"
[ "$(grep -c . "$PEERS_DIR/P.nodeinfo")" = 2 ] || fail "nodeinfo не про профили — проходит как есть"
[ -e "$PEERS_DIR/P.version" ] && fail "раздел, которого у пира нет, не должен появляться"
case " $PEER_PULL_GOT " in *" state "*) ;; *) fail "PEER_PULL_GOT без state: $PEER_PULL_GOT" ;; esac

# Пустой ответ и ответ из одного мусора прошлый кэш не затирают...
rm -f "$ANS/state"; printf '../x|deleted|9\n' > "$ANS/subtokens"
peer_pull peer.example P "state subtokens"
[ "$(cat "$PEERS_DIR/P.state")" = "ok|deleted|1" ] || fail "пустой ответ затёр кэш"
[ "$(cat "$PEERS_DIR/P.subtokens")" = "u:$good_tok" ] || fail "мусорный раздел затёр кэш"
# ...кроме обнуляемых: недоступный пир = ноль.
rm -f "$ANS/rates"; peer_pull peer.example P rates 5 rates
[ -e "$PEERS_DIR/P.rates" ] && [ ! -s "$PEERS_DIR/P.rates" ] || fail "обнуляемый раздел не обнулён"
[ -z "$(ls -A "$PEERS_DIR" | grep '^\.pull')" ] || fail "остался временный каталог"

# Вторая линия у стоков.
valid_token '../../x' && fail "valid_token пропустил путь"
valid_name 'x/d;s/a/b/' && fail "valid_name пропустил sed"
valid_name 'demo-ab_12' || fail "valid_name отверг обычное имя"

echo "OK: test-peer-pull"
