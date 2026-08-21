#!/bin/bash
# Заголовки подписки: subscription-userinfo и announce у каждого юзера свои и
# собираются из ТЕХ ЖЕ данных, по которым доступ реально отбирают (демо, окно
# бесплатного тарифа, срок платного). Сторожим сборку сниппета для Caddy.
# Запуск: bash tests/test-sub-headers.sh
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export HY2M_DATA_DIR=$(mktemp -d)
export HY2M_WEBROOT="$HY2M_DATA_DIR/web"
mkdir -p "$HY2M_WEBROOT/sub" "$HY2M_DATA_DIR/peers"
trap 'rm -rf "$HY2M_DATA_DIR"' EXIT

for lib in config traffic expiry limits node tariffs freeplan demo sub_links caddy; do
    # shellcheck disable=SC1090
    source "$SCRIPT_DIR/lib/$lib.sh"
done

# Сниппет пишем в песочницу, а не в /etc/caddy (пути в config.sh жёсткие).
CADDY_SUBTITLES="$HY2M_DATA_DIR/sub-titles.conf"
TARIFFS_CONF="$HY2M_DATA_DIR/tariffs.conf"   # обычно объявлен в lib/tgbot.sh
sub_enabled() { return 0; }        # без домена/сертификата логика та же
node_online_count() { echo 1; }

fail() { echo "❌ $1"; exit 1; }
snippet() { write_sub_titles >/dev/null; cat "$CADDY_SUBTITLES"; }
# Значение заголовка по токену из map (base64 расшифровываем).
hval() {   # map-имя токен
    local v
    v=$(sed -n "/{$1} {/,/}/p" "$CADDY_SUBTITLES" | awk -v t="/sub/$2" '$1==t{ $1=""; sub(/^ /,""); print }' | tr -d '"')
    case "$v" in base64:*) printf '%s' "${v#base64:}" | base64 -d 2>/dev/null ;; *) printf '%s' "$v" ;; esac
}

printf 'alice:pass1\ndemo-aaaa:pass2\nfreddy:pass3\n' > "$USERS_DB"
printf 'alice:tokA\ndemo-aaaa:tokD\nfreddy:tokF\n'    > "$SUBTOKENS_DB"
printf 'NODE_HOST=n1.example\nNODE_NAME=n1\n'         > "$NODE_CONF"

# Трафик: «user|tx|rx» (STATS_FILE) — расход платного и база окон.
printf 'alice|1048576|2097152\ndemo-aaaa|0|10485760\nfreddy|0|314572800\n' > "$STATS_FILE"
printf 'alice|%s\n' "$(date -d '+3 days' +%Y-%m-%d)" > "$EXPIRY_FILE"
# Демо: user|state|created|expires|cap|base|used
DEMO_EXP=$(( $(date +%s) + 1800 ))
printf 'demo-aaaa|active|0|%s|524288000|0|0\n' "$DEMO_EXP" > "$DEMOS_DB"
# Бесплатный тариф: тариф с опцией free + строка юзера (окно с нулевой базой).
printf 'free|Бесплатный|0|1|0|RUB|free=1;wk=5G;mo=15G\n' > "$TARIFFS_CONF"
printf 'freddy|active|0|0|0|0|0|0|0\n'                   > "$FREEPLAN_FILE"

# ---- subscription-userinfo ----
snippet >/dev/null
info_a=$(hval sub_info tokA)
info_d=$(hval sub_info tokD)
case "$info_a" in
    *"download=3145728"*) ;;
    *) fail "расход платного юзера не тот: $info_a" ;;
esac
case "$info_a" in *"expire=$(date -d "$(date -d '+3 days' +%Y-%m-%d) 23:59:59" +%s)"*) ;; *) fail "срок платного не попал в userinfo: $info_a" ;; esac
# Безлимит — большим числом, а не нулём: на total=0 Hiddify рисует «Квота
# исчерпана». Порог «∞» у клиентов — 10 ТиБ, значение обязано быть выше.
case "$info_a" in *"total=$SUB_UNLIMITED_BYTES"*) ;; *) fail "у платного безлимит должен быть большим числом: $info_a" ;; esac
[ "$SUB_UNLIMITED_BYTES" -gt $((10 * 1099511627776)) ] || fail "безлимит ниже порога «∞» (10 ТиБ)"
case "$info_d" in *'total=524288000'*) ;; *) fail "лимит демо не тот: $info_d" ;; esac
case "$info_d" in *"expire=$DEMO_EXP"*) ;; *) fail "срок демо не тот: $info_d" ;; esac
case "$(hval sub_info tokF)" in *'total=5368709120'*) ;; *) fail "недельный лимит бесплатного не тот" ;; esac

# ---- announce: свой текст на каждый план ----
ann_d=$(hval sub_ann tokD); ann_f=$(hval sub_ann tokF); ann_a=$(hval sub_ann tokA)
case "$ann_d" in *'Демо-доступ'*'500.0M'*' мин'*) ;; *) fail "анонс демо: $ann_d" ;; esac
case "$ann_f" in *'Бесплатный тариф'*'300.0M'*'5.0G'*) ;; *) fail "анонс бесплатного: $ann_f" ;; esac
case "$ann_a" in *'Тариф активен до'*'3.0M'*) ;; *) fail "анонс платного: $ann_a" ;; esac

# «-» — анонс этому плану не показывать. Остальные планы не трогает.
setting_set SUB_ANN_PAID '-'
snippet >/dev/null
[ -z "$(hval sub_ann tokA)" ] || fail "«-» обязан выключать анонс плана"
[ -n "$(hval sub_ann tokD)" ] || fail "«-» у платного погасил анонс демо"

# Свой шаблон с плейсхолдерами.
setting_set SUB_ANN_PAID 'До {expire} · {left} · {plan} · {user} · {name} · {devices} устр.'
snippet >/dev/null
case "$(hval sub_ann tokA)" in
    *'платный'*'alice'*'n1'*'устр.'*) ;;
    *) fail "плейсхолдеры анонса не подставились: $(hval sub_ann tokA)" ;;
esac

# ---- название профиля ----
# Без плейсхолдеров — один статический заголовок, без map.
grep -q 'header profile-title "base64:' "$CADDY_SUBTITLES" || fail "статичное название должно быть заголовком, а не map"
setting_set SUB_TITLE 'Доступ · {user} · {left}'
snippet >/dev/null
grep -q 'map {path} {sub_title}' "$CADDY_SUBTITLES" || fail "название с плейсхолдерами обязано идти через map"
case "$(hval sub_title tokD)" in *'demo-aaaa'*'мин'*) ;; *) fail "плановый плейсхолдер в названии: $(hval sub_title tokD)" ;; esac

# ---- свободный список заголовков ----
[ "$(_caddy_hval 'a"b\c')" = 'abc' ] || fail "кавычки и слэши обязаны вырезаться из значения заголовка"

echo "✅ test-sub-headers: заголовки подписки собираются по плану юзера"
