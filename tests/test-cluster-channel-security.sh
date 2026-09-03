#!/bin/bash
# Безопасность файлового канала обмена между нодами (lib/cluster.sh).
#
# Канал устроен так: имя пира приходит ИЗВНЕ (gossip привозит чужой
# `/cluster/peers.list`), попадает в реестр и подставляется в путь файла кэша
# `$PEERS_DIR/<имя>.<раздел>`. Значит имя — недоверенные данные в имени файла,
# который менеджер пишет от root. Тест сторожит ровно это: P-134.
# Запуск: bash tests/test-cluster-channel-security.sh
set -o pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export HY2M_DATA_DIR=$(mktemp -d)
export HY2M_WEBROOT="$HY2M_DATA_DIR/web"
mkdir -p "$HY2M_WEBROOT"
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT

source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/node.sh"
source "$SCRIPT_DIR/lib/cluster.sh"

fail=0
ok()  { echo "  ✅ $1"; }
bad() { echo "  ❌ $1"; fail=1; }
# Путь обязан остаться внутри peers/ после нормализации «..».
inside() {   # имя описание
    local p; p=$(readlink -m "$PEERS_DIR/${1}.manifest")
    case "$p" in
        "$PEERS_DIR"/*) ok "$2" ;;
        *) bad "$2 — путь ушёл наружу: $p" ;;
    esac
}

mkdir -p "$PEERS_DIR"
printf 'Своя нода|self.example\n' > "$CLUSTER_CONF"

echo "── Отравленное имя не попадает в реестр ──"
# Ровно тот вызов, что делает цикл gossip в cluster_sync.
feed() { printf '%s\n' "$1" | while IFS='|' read -r pn ph; do
             [ -n "$ph" ] && cluster_add_peer "$pn" "$ph"; done; }

feed '../../../../etc/logrotate.d/pwn|attacker.example'
if grep -qF '../' "$CLUSTER_CONF"; then
    bad "обход записался в реестр: $(grep -F '../' "$CLUSTER_CONF")"
else
    ok "«..» и слэши вычищены на входе"
fi
grep -q '|attacker.example$' "$CLUSTER_CONF" \
    && ok "сам пир при этом добавлен (имя обезврежено, а не запрос отброшен)" \
    || bad "пир не добавился вовсе"

echo "── Хост обязан выглядеть как хост ──"
# Нужное свойство — не «RFC-корректное имя», а «в URL не пролезут метасимволы
# пути и авторитета»: слэш, двоеточие, пробел, @, ?, #. Строгий валидатор имён
# здесь был бы лишним кодом с тем же результатом.
for bogus in 'evil.example/../../x' 'evil.example:8443/x' '../etc' 'a b' '-lead.example' \
             'evil.example?x=1' 'evil.example#x' 'user@evil.example'; do
    if cluster_add_peer "имя" "$bogus" 2>/dev/null && grep -qF "|$bogus" "$CLUSTER_CONF"; then
        bad "принят негодный хост: $bogus"
    else
        ok "отклонён: $bogus"
    fi
done
cluster_add_peer "Нормальный" "node-b.example.net" && grep -q '|node-b.example.net$' "$CLUSTER_CONF" \
    && ok "нормальный хост принимается" || bad "нормальный хост отвергнут"

echo "── Вторая линия: реестр уже отравлен (обновились после атаки) ──"
# Имя в реестре в обход cluster_add_peer — так выглядел бы файл, записанный
# старой версией. cluster_peer_name обязан вычистить его при ЧТЕНИИ.
printf '%s\n' '../../../../etc/logrotate.d/pwn|legacy.example' >> "$CLUSTER_CONF"
got=$(cluster_peer_name legacy.example)
# Проверяем отсутствие СЛЭША, а не подстроки «..»: «..» внутри имени файла без
# слэша каталог не меняет, поэтому вычищать её отдельно незачем.
case "$got" in
    */*) bad "cluster_peer_name отдал имя со слэшем: $got" ;;
    *) ok "имя из отравленного реестра вычищено при чтении: $got" ;;
esac
inside "$got" "путь записи кэша остался внутри peers/"

echo "── Пир без имени не превращается в общий файл ──"
printf '%s\n' '|noname.example' >> "$CLUSTER_CONF"
got=$(cluster_peer_name noname.example)
[ -n "$got" ] && ok "пустое имя заменено на производное от хоста: $got" \
              || bad "имя пустое — все пиры писали бы в один файл .manifest"

echo "── Секрет кластера не читается посторонними ──"
# Реальный конфиг Caddy этой машины: секрет лежит в нём открытым текстом.
CF=/etc/caddy/Caddyfile
if [ -f "$CF" ] && grep -q "X-Cluster-Auth" "$CF" 2>/dev/null; then
    mode=$(stat -c '%a' "$CF")
    case "$mode" in
        *[0-7][0-7][4567]) bad "Caddyfile с секретом кластера доступен всем на чтение (режим $mode) — P-135" ;;
        *) ok "Caddyfile не читается посторонними (режим $mode)" ;;
    esac
else
    echo "  ⚪ Caddyfile с кластерным матчером не найден — проверка пропущена"
fi

echo ""
[ "$fail" = 0 ] && { echo "✅ Все проверки прошли"; exit 0; } || { echo "❌ Есть падения"; exit 1; }
