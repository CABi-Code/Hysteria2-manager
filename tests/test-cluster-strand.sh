#!/bin/bash
# P-130: профиль, отключённый локально при кластерном «active», должен
# возвращаться в строй сам. Раньше cluster_apply_roster пропускал таких
# («is_user_disabled && continue»), а cluster_apply_state работает только на
# НОВОМ ts — расхождение становилось вечным, и клиент видел в подписке один
# сервер вместо всех.
#
# Проверяем ОБЕ стороны: что расхождение лечится и что лечение не превращается
# в качели с автоотключением по сроку.
# Запуск: bash tests/test-cluster-strand.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export HY2M_DATA_DIR=$(mktemp -d)
export HY2M_WEBROOT="$HY2M_DATA_DIR/web"
mkdir -p "$HY2M_WEBROOT/cluster" "$HY2M_DATA_DIR/peers"
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT

source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/users.sh"
source "$SCRIPT_DIR/lib/expiry.sh"
source "$SCRIPT_DIR/lib/cluster.sh"

# Заглушки: интересует только решение «завести / оставить отключённым».
sub_enabled()       { return 0; }
secure_web_files()  { return 0; }
secure_auth_files() { return 0; }
sub_refresh()       { return 0; }
hy_kick_user()      { return 0; }

# Бесплатный тариф есть только у free_user. Так же, как в check_expired_users,
# free-план проверяется ВЫШЕ срока: у сидящего на нём дата в expiry.dat
# намеренно вчерашняя (см. freeplan_activate), и она не повод его не заводить.
freeplan_has() { [ "$1" = "free_user" ]; }

fail() { echo "❌ $1"; exit 1; }

FUTURE=$(date -d '+30 days' '+%Y-%m-%d')
PAST=$(date -d '-30 days' '+%Y-%m-%d')

# Все четверо объявлены кластерными пиром и локально отсутствуют в users.db.
printf 'bought\nexpired\nblocked\nfree_user\n' > "$PEERS_DIR/peer1.roster"

# Точка правды кластера: blocked отключён по кластеру (так метит free-план,
# выбравший квоту), остальные активны.
cat > "$CLUSTER_STATE_FILE" <<EOF
bought|active|1000
expired|active|1000
blocked|disabled|1000
free_user|active|1000
EOF

# Локально все четверо отключены — тот самый разъезд с точкой правды.
cat > "$DISABLED_FILE" <<EOF
bought|pass_bought
expired|pass_expired
blocked|pass_blocked
free_user|pass_free
EOF

cat > "$EXPIRY_FILE" <<EOF
bought|$FUTURE
expired|$PAST
blocked|$FUTURE
free_user|$PAST
EOF

: > "$USERS_DB"

cluster_apply_roster

# 1. Купил тариф после отключения по сроку — ровно случай, с которого начали.
db_user_exists bought || fail "bought: кластер считает активным, срок в будущем — должен быть заведён"
grep -q '^bought|' "$DISABLED_FILE" && fail "bought: заведён, но остался в отключённых"
grep -q '^bought:pass_bought$' "$USERS_DB" || fail "bought: должен вернуться СВОИМ паролем, а не новым"

# 2. Срок реально истёк — воскрешать нельзя, иначе качели с check_expired_users.
db_user_exists expired && fail "expired: срок истёк, заводить не должны (качели со sweep)"
grep -q '^expired|' "$DISABLED_FILE" || fail "expired: должен остаться в отключённых"

# 3. Отключён по кластеру (блок free-плана по квоте) — точка правды главнее.
db_user_exists blocked && fail "blocked: отключён по кластеру, заводить не должны"

# 4. На бесплатном тарифе дата в expiry вчерашняя ПО ЗАМЫСЛУ — не повод бросать.
db_user_exists free_user || fail "free_user: на бесплатном тарифе, должен быть заведён"

# 5. Пустой пароль в disabled.dat: заводим с новым, но не теряем юзера разом
#    из базы и из отключённых.
printf 'nopass\n' > "$PEERS_DIR/peer1.roster"
printf 'nopass|active|1000\n' > "$CLUSTER_STATE_FILE"
printf 'nopass|\n'            > "$DISABLED_FILE"
printf 'nopass|%s\n' "$FUTURE" > "$EXPIRY_FILE"
: > "$USERS_DB"

cluster_apply_roster

db_user_exists nopass || fail "nopass: пустой пароль — должен быть заведён с новым"
grep -q '^nopass|' "$DISABLED_FILE" && fail "nopass: заведён, но остался в отключённых"

# --- Видимость: расхождение должно быть ВИДНО, а не молчать ------------------
# Ровно то, чего не хватало: пир жив и синхронизируется, а профилей у него нет.
printf 'alice\nbob\ncarol\n' > "$CLUSTER_USERS_FILE"
: > "$PEERS_DIR/peer1.roster"
printf 'peer1|peer1.example\n' > "$CLUSTER_CONF"
# У пира заведена только alice — bob и carol отсутствуют.
printf 'alice\thysteria2://x@peer1.example:443/\n' > "$PEERS_DIR/peer1.example.manifest"

out=$(cluster_coverage_report)
[ -n "$out" ] || fail "покрытие: расхождение есть, а отчёт молчит"
printf '%s' "$out" | grep -q 'нет 2 из 3' || fail "покрытие: ждали «нет 2 из 3», получили: $out"

# Пустой манифест — это «нода не отдала данные» (о ней уже сказал .health),
# а не «у неё нет профилей»: второй раз шуметь не о чем.
: > "$PEERS_DIR/peer1.example.manifest"
[ -z "$(cluster_coverage_report)" ] || fail "покрытие: пустой манифест не повод для тревоги"

# Полное совпадение — тишина.
printf 'alice\tu\nbob\tu\ncarol\tu\n' > "$PEERS_DIR/peer1.example.manifest"
[ -z "$(cluster_coverage_report)" ] || fail "покрытие: всё на месте, а отчёт ругается"

# --- Обновление соседей не зависит от Web API --------------------------------
# Раньше здесь был POST в /v1/cluster/update, и отчёт приходилось строить по
# ТЕЛУ ответа: нода без снятия префикса /api отдавала бодрый 200 статической
# заглушкой подписки. Теперь просьба публикуется в файловом канале, и разбирать
# чужие ответы не нужно — их просто нет (P-133). Главное, что сторожим:
# Web API из этого пути ушёл и вернуться не должен.
cluster_peers() { printf 'peer1.example\n'; }
cluster_post()  { echo "ЗВАЛИ WEB API" >> "$HY2M_DATA_DIR/api-calls"; printf '{"ok":true}'; }
: > "$HY2M_DATA_DIR/api-calls"

out=$(cluster_update_peers)
[ -s "$HY2M_DATA_DIR/api-calls" ] && fail "обновление снова ходит в Web API соседа"
printf '%s' "$out" | grep -q 'peer1.example' || fail "обновление: пир не упомянут в отчёте"
[ -s "$WEBROOT/cluster/updatereq" ] || fail "обновление: просьба не опубликована в разделе"
grep -qE '^[^|]+\|[0-9]+$' "$WEBROOT/cluster/updatereq" \
    || fail "обновление: формат просьбы не «версия|ts»: $(cat "$WEBROOT/cluster/updatereq")"

echo "✅ test-cluster-strand: расхождение лечится, срок и кластерный блок уважаются, недостача видна"
