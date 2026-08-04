#!/bin/bash
# Перевыпуск манифеста и подписок в --online-sync идёт только когда входы
# изменились (_subs_inputs_changed). Сторожим обе стороны: молчит на неизменных
# входах и срабатывает на правке любого из них.
# Запуск: bash tests/test-subs-sig.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export HY2M_DATA_DIR=$(mktemp -d)
export HY2M_WEBROOT="$HY2M_DATA_DIR/web"
mkdir -p "$HY2M_WEBROOT/cluster" "$HY2M_DATA_DIR/peers"
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT

source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/sub_links.sh"

ONLINE=2
node_online_count() { echo "$ONLINE"; }

fail() { echo "❌ $1"; exit 1; }

printf 'alice:pass1\n'            > "$USERS_DB"
printf 'alice:tok1\n'             > "$SUBTOKENS_DB"
printf 'NODE_HOST=n1.example\n'   > "$NODE_CONF"
printf 'alice\turi\n'             > "$PEERS_DIR/peer1.manifest"

_subs_inputs_changed || fail "первый вызов обязан считаться изменением"
_subs_inputs_changed && fail "на неизменных входах перевыпуск не нужен"

# Каждый вход по отдельности обязан будить перевыпуск.
check() {   # описание изменение-входа
    local what="$1"
    eval "$2"
    _subs_inputs_changed || fail "$what не разбудил перевыпуск"
    _subs_inputs_changed && fail "$what: подпись не запомнилась"
}
check "новый юзер"        'printf "bob:pass2\n" >> "$USERS_DB"'
check "новый токен"       'printf "bob:tok2\n" >> "$SUBTOKENS_DB"'
check "правка node.conf"  'printf "NODE_LABEL=🇫🇮\n" >> "$NODE_CONF"'
check "манифест пира"     'printf "bob\turi2\n" >> "$PEERS_DIR/peer1.manifest"'
check "отключение юзера"  'printf "bob|disabled|1\n" >> "$CLUSTER_STATE_FILE"'
check "смена онлайна"     'ONLINE=3' 

echo "✅ подпись входов подписки: молчит на неизменном, будит на каждой правке"
