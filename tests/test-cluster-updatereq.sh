#!/bin/bash
# Просьба «обновите менеджер» по файловому каналу (lib/cluster.sh).
#
# Заменила POST в Web API соседа: тот компонент на ноде без кабинета не
# включают, и обновление кластера оказалось от него зависимым (P-133).
#
# Триггер — СВЕРКА ПО ФАКТУ («просят версию новее нашей»), а не дельта по ts:
# не доехавшее обновление обязано повториться, иначе новой метки времени взяться
# неоткуда (правило 7 в docs/guide/CLUSTER-SCOPE.md). Отсюда три опасности, и
# все три здесь сторожатся:
#   * повтор без паузы -> переустановка менеджера на каждой синхронизации;
#   * отсутствие повтора вовсе -> нода молча остаётся отставшей навсегда;
#   * чужая просьба уедет в наш раздел -> объявление станет бессмертным.
# Запуск: bash tests/test-cluster-updatereq.sh
set -o pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export HY2M_DATA_DIR=$(mktemp -d)
export HY2M_WEBROOT="$HY2M_DATA_DIR/web"
mkdir -p "$HY2M_WEBROOT"
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT

source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/node.sh"
source "$SCRIPT_DIR/lib/cluster.sh"
source "$SCRIPT_DIR/lib/update.sh"

fail=0
ok()  { echo "  ✅ $1"; }
bad() { echo "  ❌ $1"; fail=1; }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1: ждали «$3», получили «$2»"; }

# Заглушка обновления: считаем запуски вместо переустановки менеджера.
RUNS="$HY2M_DATA_DIR/runs"; : > "$RUNS"
manager_update_silent() { echo run >> "$RUNS"; return 0; }
# grep -c на пустом файле печатает 0 И возвращает 1, поэтому «|| echo 0»
# дописывал второй ноль. Нужен just-print: код возврата здесь не сигнал.
runs() { grep -c . "$RUNS" 2>/dev/null || true; }
# Подписка «настроена»: публикация иначе выходит сразу.
sub_enabled() { return 0; }
MANAGER_VERSION="4.28.100"
manager_local_version() { printf '%s' "$MANAGER_VERSION"; }

mkdir -p "$PEERS_DIR" "$WEBROOT/cluster"
peer_asks() {   # версия ts
    printf '%s|%s\n' "$1" "$2" > "$PEERS_DIR/сосед.updatereq"
}

echo "── Просят версию новее нашей — обновляемся ──"
peer_asks 4.28.200 "$(date +%s)"
cluster_apply_updatereq
is "обновление запущено один раз" "$(runs)" 1
[ -s "$UPDATEREQ_SEEN_FILE" ] && ok "метка попытки записана" || bad "метка попытки не записана"

echo "── На следующем sync повтора нет: пауза между попытками ──"
cluster_apply_updatereq
cluster_apply_updatereq
is "повторных запусков нет" "$(runs)" 1

echo "── Но факт всё ещё не сошёлся — после паузы ПОВТОРЯЕМ ──"
# Это главное отличие от дельты по ts: не доехавшее обновление обязано
# повториться, иначе новой метки времени взяться неоткуда (правило 7).
printf '%s\n' "$(( $(date +%s) - UPDATEREQ_RETRY_SEC - 1 ))" > "$UPDATEREQ_SEEN_FILE"
cluster_apply_updatereq
is "попытка повторена по тому же объявлению" "$(runs)" 2

echo "── Версия сошлась — попытки прекращаются ──"
MANAGER_VERSION="4.28.200"
printf '%s\n' "$(( $(date +%s) - UPDATEREQ_RETRY_SEC - 1 ))" > "$UPDATEREQ_SEEN_FILE"
cluster_apply_updatereq
is "дело сделано, больше не дёргаемся" "$(runs)" 2
MANAGER_VERSION="4.28.100"

echo "── Просьба до версии, которая уже есть — не работа ──"
: > "$RUNS"
peer_asks 4.28.100 "$(date +%s)"
printf '0\n' > "$UPDATEREQ_SEEN_FILE"
cluster_apply_updatereq
is "запуска не было" "$(runs)" 0
peer_asks 4.20.001 "$(date +%s)"
cluster_apply_updatereq
is "просьба откатиться назад игнорируется" "$(runs)" 0

echo "── Протухшая просьба перестаёт дёргать ──"
# Иначе объявление с недостижимой версией (опечатка, откат репо) осталось бы
# вечным поводом переустанавливать менеджер по кругу.
peer_asks 4.99.999 "$(( $(date +%s) - UPDATEREQ_TTL_SEC - 10 ))"
printf '0\n' > "$UPDATEREQ_SEEN_FILE"
cluster_apply_updatereq
is "по старой просьбе не обновляемся" "$(runs)" 0
peer_asks 4.99.999 "$(date +%s)"
cluster_apply_updatereq
is "по свежей — обновляемся" "$(runs)" 1

echo "── Из нескольких соседей берётся самая свежая ──"
: > "$RUNS"; printf '0\n' > "$UPDATEREQ_SEEN_FILE"
now=$(date +%s)
printf '%s\n' "4.29.500|$now"          > "$PEERS_DIR/сосед-б.updatereq"
printf '%s\n' "4.20.000|$((now-100))"  > "$PEERS_DIR/сосед.updatereq"
cluster_apply_updatereq
is "взята просьба с максимальным ts" "$(runs)" 1

echo "── Битая строка не роняет и не запускает ──"
: > "$RUNS"; printf '0\n' > "$UPDATEREQ_SEEN_FILE"
rm -f "$PEERS_DIR"/*.updatereq
printf '%s\n' 'мусор без разделителя' > "$PEERS_DIR/сосед-в.updatereq"
cluster_apply_updatereq && ok "функция не упала" || bad "функция вернула ошибку"
is "запусков нет" "$(runs)" 0

echo "── «unknown» вместо версии не считается просьбой ──"
# sort -V ставит «unknown» ВЫШЕ любых цифр, поэтому такая строка (у соседа не
# прочиталась VERSION) гнала бы нас в бесконечные попытки догнать несуществующее.
: > "$RUNS"; printf '0\n' > "$UPDATEREQ_SEEN_FILE"
rm -f "$PEERS_DIR"/*.updatereq
peer_asks unknown "$(date +%s)"
cluster_apply_updatereq
is "по «unknown» не обновляемся" "$(runs)" 0
peer_asks "4.28.200-hack" "$(date +%s)"
cluster_apply_updatereq
is "по мусору с цифрами тоже" "$(runs)" 0

echo "── И сами такого не публикуем ──"
manager_remote_version() { printf ''; }
MANAGER_VERSION=""
if ver=$(cluster_request_update); then
    bad "опубликовали просьбу без вменяемой версии: «$ver»"
else
    ok "без версии просьба не публикуется (возврат ошибки)"
fi
MANAGER_VERSION="4.28.100"
manager_remote_version() { printf 'unknown'; }
ver=$(cluster_request_update)
is "мусор из репозитория отброшен, взята своя" "$ver" "4.28.100"

echo "── Мы публикуем ТОЛЬКО свою просьбу, чужие не перепубликовываем ──"
manager_remote_version() { printf '4.30.000'; }
ver=$(cluster_request_update)
is "опубликована версия репозитория" "$ver" "4.30.000"
# CDN GitHub первые минуты после пуша отдаёт ПРЕДЫДУЩУЮ версию. Просьба на неё
# уходит в никуда: у соседей она уже стоит. Поймано на живой ноде.
manager_remote_version() { printf '4.28.000'; }
MANAGER_VERSION="4.28.100"
ver=$(cluster_request_update)
is "своя версия новее репо — просим догнать себя" "$ver" "4.28.100"
manager_remote_version() { printf '4.30.000'; }
ver=$(cluster_request_update)
pub="$WEBROOT/cluster/updatereq"
is "в разделе ровно одна строка" "$(grep -c . "$pub")" 1
grep -q '^4.30.000|' "$pub" && ok "и это наша строка" || bad "в разделе не наша строка: $(cat "$pub")"
grep -qF '4.29.500' "$pub" && bad "чужая просьба утекла в наш раздел" || ok "чужих просьб в разделе нет"
is "права на раздел 640" "$(stat -c '%a' "$pub")" 640

echo "── Раздел подключён к синхронизации ──"
case " $CLUSTER_SYNC_SECTIONS " in
    *" updatereq "*) ok "updatereq есть в CLUSTER_SYNC_SECTIONS" ;;
    *) bad "раздел не опрашивается — соседи его не увидят" ;;
esac

echo "── Удаление пира чистит и новый раздел ──"
printf 'сосед|peer.example\n' > "$CLUSTER_CONF"
: > "$PEERS_DIR/сосед.updatereq"
publish_peers_list() { :; }; regen_subscriptions() { :; }
cluster_remove_peer peer.example >/dev/null 2>&1
[ -f "$PEERS_DIR/сосед.updatereq" ] && bad "кэш раздела остался после удаления пира" \
                                    || ok "кэш раздела удалён"

echo ""
[ "$fail" = 0 ] && { echo "✅ Все проверки прошли"; exit 0; } || { echo "❌ Есть падения"; exit 1; }
