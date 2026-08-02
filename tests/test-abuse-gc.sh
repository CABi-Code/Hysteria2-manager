#!/bin/bash
# P-23: состояние анти-абуза не копит строки удалённых профилей.
#   • abuse_apply выбрасывает юзеров, которых нет ни локально, ни у пиров;
#   • пустой список известных юзеров фильтр НЕ включает (не сносим живое);
#   • cluster_delete_local (тихое удаление, им уходят демо-профили) чистит abuse.
# Запуск: bash tests/test-abuse-gc.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export HY2M_DATA_DIR=$(mktemp -d)
export HY2M_WEBROOT="$HY2M_DATA_DIR/web"
mkdir -p "$HY2M_WEBROOT/cluster" "$HY2M_DATA_DIR/peers"
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT

source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/antiabuse.sh"

sub_enabled()          { return 0; }
secure_web_files()     { return 0; }
# Живые юзеры кластера: alice — наша, bob — с манифеста пира.
sub_all_users()        { printf 'alice\nbob\n'; }

fail() { echo "❌ $1"; exit 1; }

now=$(date +%s)
printf 'alice|50|%s|0|2|3\ndemo-old|70|%s|0|1|1\n' "$now" "$now" > "$ABUSE_FILE"
printf 'bob|30|%s|0|1|0\ndemo-peer|90|%s|0|1|1\n' "$now" "$now" > "$PEERS_DIR/peer1.abuse"

abuse_apply
grep -q '^alice|' "$ABUSE_FILE" || fail "живой локальный юзер потерян"
grep -q '^bob|'   "$ABUSE_FILE" || fail "живой юзер пира потерян"
grep -q '^demo-'  "$ABUSE_FILE" && fail "призрак удалённого профиля остался"

# Список известных пуст (манифесты не прочитались) — фильтр молчит.
sub_all_users() { printf ''; }
printf 'alice|50|%s|0|2|3\n' "$now" > "$ABUSE_FILE"
abuse_apply
grep -q '^alice|' "$ABUSE_FILE" || fail "пустой список известных снёс живое состояние"

# Тихое кластерное удаление (демо-профили уходят через него) чистит abuse.
sub_all_users() { printf 'alice\n'; }
printf 'alice|50|%s|0|2|3\n' "$now" > "$ABUSE_FILE"
printf 'alice|1|5|0|0\n'     > "$ABUSE_OBS_FILE"
remove_user_abuse alice
grep -q '^alice|' "$ABUSE_FILE"     && fail "строка юзера осталась в abuse.dat"
grep -q '^alice|' "$ABUSE_OBS_FILE" && fail "строка юзера осталась в наблюдениях"

echo "✅ abuse: призраки не копятся"
