#!/bin/bash
# Просьба «обновите менеджер» по файловому каналу (lib/cluster.sh).
#
# Заменила POST в Web API соседа: тот компонент на ноде без кабинета не
# включают, и обновление кластера оказалось от него зависимым (P-133). Механизм
# опасен двумя способами, и оба здесь сторожатся:
#   * просьба сработает не один раз -> переустановка менеджера каждые 5 минут;
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
runs() { grep -c . "$RUNS" 2>/dev/null || echo 0; }
# Подписка «настроена»: публикация иначе выходит сразу.
sub_enabled() { return 0; }
MANAGER_VERSION="4.28.100"
manager_local_version() { printf '%s' "$MANAGER_VERSION"; }

mkdir -p "$PEERS_DIR" "$WEBROOT/cluster"
peer_asks() {   # версия ts
    printf '%s|%s\n' "$1" "$2" > "$PEERS_DIR/сосед.updatereq"
}

echo "── Просьба соседа новее нашей метки — обновляемся ──"
peer_asks 4.28.200 1000
cluster_apply_updatereq
is "обновление запущено один раз" "$(runs)" 1
is "метка применённого ts записана" "$(cat "$UPDATEREQ_SEEN_FILE")" 1000

echo "── Та же просьба на следующем sync — НЕ повторяем ──"
cluster_apply_updatereq
cluster_apply_updatereq
is "повторных запусков нет" "$(runs)" 1

echo "── Просьба до версии, которая у нас уже есть — не работа ──"
peer_asks 4.28.100 2000
cluster_apply_updatereq
is "запуска не было" "$(runs)" 1
is "но ts всё равно зафиксирован (иначе застрянем на нём)" "$(cat "$UPDATEREQ_SEEN_FILE")" 2000
peer_asks 4.20.001 3000
cluster_apply_updatereq
is "просьба откатиться назад игнорируется" "$(runs)" 1

echo "── Новая просьба с более свежим ts — снова обновляемся ──"
peer_asks 4.29.001 4000
cluster_apply_updatereq
is "запущено второй раз" "$(runs)" 2

echo "── Из нескольких соседей берётся самая свежая ──"
printf '%s\n' '4.29.500|5000' > "$PEERS_DIR/сосед-б.updatereq"
printf '%s\n' '4.29.400|4500' > "$PEERS_DIR/сосед.updatereq"
cluster_apply_updatereq
is "взят максимальный ts" "$(cat "$UPDATEREQ_SEEN_FILE")" 5000
is "запущено третий раз" "$(runs)" 3

echo "── Битая строка не роняет и не запускает ──"
printf '%s\n' 'мусор без разделителя' > "$PEERS_DIR/сосед-в.updatereq"
cluster_apply_updatereq && ok "функция не упала" || bad "функция вернула ошибку"
is "запусков не добавилось" "$(runs)" 3

echo "── Мы публикуем ТОЛЬКО свою просьбу, чужие не перепубликовываем ──"
manager_remote_version() { printf '4.30.000'; }
ver=$(cluster_request_update)
is "опубликована запрошенная версия" "$ver" "4.30.000"
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
