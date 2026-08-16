#!/bin/bash
# ================================================
# Диспетчер мутаций для hy2-webapi.py: единственная точка, через которую
# Web API меняет состояние менеджера. Сорсит lib/*.sh и вызывает ТЕ ЖЕ функции,
# что меню и Telegram-бот, — кластерная публикация, метки времени (LWW) и
# пересборка подписок происходят сами, без дублирования логики в питоне.
#
# Контракт с демоном:
#   • вызов: dispatch.sh <verb> [args...]; аргументы строго позиционные;
#   • stdout: ТОЛЬКО строки key=value (человеческий вывод lib-функций гасится);
#   • коды выхода: 0 ок · 2 объект не найден (404) · 3 конфликт состояния (409)
#     · 64 неизвестный verb/аргументы (bug в демоне) · 75 flock занят (503 busy,
#     EX_TEMPFAIL — «повторите позже») · прочее — ошибка (502);
#   • мутации сериализуются flock'ом ($DATA_DIR/.webapi.lock) — API-вызовы не
#     гоняются между собой (окно гонки с интерактивным меню остаётся, см. docs/guide/API.md).
#
# Безопасность: аргументы валидируются здесь ЗАНОВО (демон уже проверил — это
# второй барьер: никакой eval, только case по verb и позиционные параметры).
# ================================================
# Без set -e и set -u: lib-функции написаны в толерантном стиле (grep без
# совпадений в норме возвращает ненулевой код, опциональные позиционные
# аргументы читаются без :-) — ошибки контракта проверяются явно через || fail.
set -o pipefail

MANAGER_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT_DIR="$MANAGER_DIR"                       # его ждут lib-функции (пути до lib/)
MANAGER_VERSION="$(head -1 "$MANAGER_DIR/VERSION" 2>/dev/null | tr -d '[:space:]')"
LOG_DIR="/var/log/hy2-manager"                  # tgbot.sh читает при сорсинге
LOG_FILE="$LOG_DIR/error.log"

# Набор модулей НЕ дублируем: читаем тот же _required_libs из hy2-manager.sh,
# который парсит и install.sh (единственный источник правды). Своя копия списка
# уже разъезжалась: после разбиения subscription.sh на node/sub_links/... здесь
# остался source несуществующего файла, и demo-create отвечал sub_disabled.
# Интерактивные ui* демону не нужны — их пропускаем.
_libs=$(grep -oP '_required_libs=\(\K[^)]*' "$MANAGER_DIR/hy2-manager.sh" 2>/dev/null)
[ -n "$_libs" ] || { printf 'error=%s\nmessage=%s\n' 'libs_unknown' 'не удалось прочитать список модулей из hy2-manager.sh'; exit 1; }
for _lib in $_libs; do
    case "$_lib" in ui | ui_*) continue ;; esac
    [ -f "$MANAGER_DIR/lib/${_lib}.sh" ] || { printf 'error=%s\nmessage=%s\n' 'lib_missing' "модуль не найден: lib/${_lib}.sh"; exit 1; }
    # shellcheck disable=SC1090
    source "$MANAGER_DIR/lib/${_lib}.sh"
done
unset _libs _lib

fail() {   # exit_code api_code message
    printf 'error=%s\nmessage=%s\n' "$2" "$3"
    exit "$1"
}

valid_user()  { [[ "$1" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || fail 64 bad_username "недопустимое имя пользователя"; }
valid_tgid()  { [[ "$1" =~ ^[0-9]{1,20}$ ]] || fail 64 bad_tg_id "недопустимый tg_id"; }
valid_num()   { [[ "$1" =~ ^[0-9]{1,7}$ ]] || fail 64 bad_number "ожидалось число"; }
# Со знаком: extend умеет и укорачивать срок (эскроу подарочных дней в мини-аппе).
valid_snum()  { [[ "$1" =~ ^-?[0-9]{1,7}$ ]] || fail 64 bad_number "ожидалось число"; }
valid_code()  { [[ "$1" =~ ^[A-Za-z0-9]{4,64}$ ]] || fail 64 bad_code "недопустимый код"; }
# Тариф пишется строкой «code|title|days|devices|prices|currencies|opts»: любой
# «|» или перевод строки в аргументе расщепил бы запись, поэтому проверяем здесь
# ещё раз, независимо от демона.
valid_tcode()       { [[ "$1" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || fail 64 bad_code "недопустимый код тарифа"; }
valid_ttitle()      { [ -n "$1" ] && [ ${#1} -le 64 ] && [[ "$1" != *"|"* ]] && [[ "$1" != *$'\n'* ]] || fail 64 bad_title "недопустимое название тарифа"; }
valid_tprices()     { [[ "$1" =~ ^[0-9]+([.][0-9]{1,2})?(/[0-9]+([.][0-9]{1,2})?)*$ ]] || fail 64 bad_price "недопустимая цена"; }
valid_tcurrencies() { [[ "$1" =~ ^[A-Z]{3}(/[A-Z]{3})*$ ]] || fail 64 bad_currency "недопустимая валюта"; }
valid_topts()       { [[ "$1" =~ ^[A-Za-z0-9=\;.]{0,128}$ ]] || fail 64 bad_options "недопустимые опции тарифа"; }

# Мутации сериализуются между собой. -w 15: лучше отдать 503 busy (rc 75,
# демон добавит Retry-After), чем висеть вечно.
take_lock() {
    exec 200>"$DATA_DIR/.webapi.lock"
    flock -w 15 200 || fail 75 busy "менеджер занят, повторите позже"
}

verb="${1:-}"; shift || true

case "$verb" in

    provision)   # <user> → password=…, sub_url=…
        [ $# -eq 1 ] || fail 64 bad_args "provision <user>"
        valid_user "$1"
        take_lock
        # Ручка идемпотентная, и мини-апп зовёт её перед каждой выдачей доступа.
        # Уже заведённому юзеру перегенерация не нужна: sub_refresh правит
        # конфиги Xray/sing-box и РЕСТАРТУЕТ их (рвутся живые сессии платящих),
        # а весь блок занимает ~20 с — клиент отваливался по таймауту 5 с и
        # получал «сервер недоступен». Снятому с отключённых sub_refresh делает
        # сам enable_user внутри bot_provision_user.
        existed=0
        { db_user_exists "$1" || is_user_disabled "$1"; } && existed=1
        pass=$(bot_provision_user "$1") || fail 1 provision_failed "не удалось создать пользователя"
        [ -n "$pass" ] || fail 1 provision_failed "пустой пароль"
        if [ "$existed" = 0 ]; then
            write_authlimits >/dev/null 2>&1 || true
            sub_refresh >/dev/null 2>&1 || true
        fi
        printf 'password=%s\n' "$pass"
        if sub_enabled; then
            printf 'sub_url=%s\n' "$(subscription_url "$1")"
        fi
        ;;

    extend)      # <user> <days> → expiry=YYYY-MM-DD
        [ $# -eq 2 ] || fail 64 bad_args "extend <user> <days>"
        valid_user "$1"; valid_snum "$2"
        db_user_exists "$1" || is_user_disabled "$1" || fail 2 user_not_found "пользователь не найден"
        take_lock
        new=$(bot_extend_user "$1" "$2") || fail 1 extend_failed "не удалось продлить"
        printf 'expiry=%s\n' "$new"
        ;;

    enable)      # <user>
        [ $# -eq 1 ] || fail 64 bad_args "enable <user>"
        valid_user "$1"
        take_lock
        if db_user_exists "$1"; then
            printf 'status=active\n'; exit 0    # уже включён — идемпотентно
        fi
        is_user_disabled "$1" || fail 2 user_not_found "пользователь не найден"
        # Код возврата lib-функций не контракт (см. disable ниже) — проверяем состояние.
        enable_user "$1" >/dev/null 2>&1
        db_user_exists "$1" || fail 1 enable_failed "не удалось включить"
        printf 'status=active\n'
        ;;

    disable)     # <user>
        [ $# -eq 1 ] || fail 64 bad_args "disable <user>"
        valid_user "$1"
        take_lock
        if is_user_disabled "$1"; then
            printf 'status=disabled\n'; exit 0  # уже выключен — идемпотентно
        fi
        db_user_exists "$1" || fail 2 user_not_found "пользователь не найден"
        # disable_user с «silent» всегда возвращает 1 (последним выполняется
        # проваленный [ silent != silent ]) — успех проверяем по состоянию базы.
        disable_user "$1" silent >/dev/null 2>&1
        is_user_disabled "$1" || fail 1 disable_failed "не удалось отключить"
        printf 'status=disabled\n'
        ;;

    set-limits)  # <user> <devices> <rate_mbps>  (hardcheck сохраняется текущий)
        [ $# -eq 3 ] || fail 64 bad_args "set-limits <user> <devices> <rate>"
        valid_user "$1"; valid_num "$2"; valid_num "$3"
        db_user_exists "$1" || is_user_disabled "$1" || fail 2 user_not_found "пользователь не найден"
        take_lock
        set_user_limits "$1" "$2" "$(get_user_hardcheck "$1")" "" "$3" "$(get_user_prefer "$1")" >/dev/null 2>&1
        write_authlimits >/dev/null 2>&1 || true
        # Пересобрать kernel-лимит: гарантирует HTB-класс под назначенную скорость
        # (иначе тариф без совпадающего класса игнорируется klimit_reconcile) и
        # немедленно раскладывает пер-IP правила. Меню бота делает то же (ui.sh).
        klimit_apply "$(klimit_down)" "$(klimit_up)" >/dev/null 2>&1 || true
        printf 'devices=%s\nrate=%s\n' "$(get_user_devices "$1")" "$(get_user_rate "$1")"
        ;;

    set-prefer)  # <user> <«host/протокол»|-> — первый ключ подписки, «-» снять
        # Отдельно от set-limits намеренно: там пересборка kernel-лимитов и
        # снимок жёсткой проверки, к порядку ключей отношения не имеющие, а
        # вместе это уже несколько секунд — дольше, чем клиент ждёт ответ.
        [ $# -eq 2 ] || fail 64 bad_args "set-prefer <user> <host/протокол|->"
        valid_user "$1"
        _pref="$2"; [ "$_pref" = "-" ] && _pref=""
        [ -z "$_pref" ] || prefer_valid "$_pref" || fail 64 bad_prefer "prefer: «host/протокол» или «-»"
        db_user_exists "$1" || is_user_disabled "$1" || fail 2 user_not_found "пользователь не найден"
        take_lock
        if [ "$_pref" != "$(get_user_prefer "$1")" ]; then
            set_user_prefer "$1" "$_pref" >/dev/null 2>&1
            # Порядок живёт в файле подписки: без пересборки клиент увидел бы
            # старый до ближайшего общего regen (десятки секунд на всех юзеров).
            regen_user_subscription "$1" >/dev/null 2>&1 || true
        fi
        printf 'prefer=%s\n' "$(get_user_prefer "$1")"
        ;;

    reset-subscription)  # <user> → sub_url=… (новая ссылка + новые ключи везде)
        [ $# -eq 1 ] || fail 64 bad_args "reset-subscription <user>"
        valid_user "$1"
        db_user_exists "$1" || is_user_disabled "$1" || fail 2 user_not_found "пользователь не найден"
        sub_enabled || fail 3 sub_disabled "подписка на ноде не настроена"
        take_lock
        url=$(reset_subscription "$1") || fail 1 reset_failed "не удалось сбросить подписку"
        [ -n "$url" ] || fail 1 reset_failed "пустая ссылка после сброса"
        printf 'sub_url=%s\n' "$url"
        ;;

    free-activate)  # <user> — подключить бесплатный тариф по кнопке
        [ $# -eq 1 ] || fail 64 bad_args "free-activate <user>"
        valid_user "$1"
        db_user_exists "$1" || is_user_disabled "$1" || fail 2 user_not_found "пользователь не найден"
        free_enabled || fail 3 free_disabled "бесплатный тариф не настроен"
        take_lock
        freeplan_activate "$1"
        case $? in
            0) printf 'state=%s\n' "$(freeplan_field "$1" 2)" ;;
            3) fail 3 subscription_active "платная подписка ещё действует" ;;
            *) fail 1 free_failed "не удалось подключить бесплатный тариф" ;;
        esac
        ;;

    traffic-refresh)  # → refreshed=1|0 — пересчитать трафик/активность сейчас
        [ $# -eq 0 ] || fail 64 bad_args "traffic-refresh"
        # Кулдаун общий на ноду: пересчёт глобальный (один проход по всем
        # юзерам), поэтому десяти спросившим подряд хватает одного прогона.
        _now=$(date +%s); _last=$(cat "$TRAFFIC_REFRESH_TS" 2>/dev/null)
        [[ "$_last" =~ ^[0-9]+$ ]] || _last=0
        if [ $(( _now - _last )) -lt "$TRAFFIC_REFRESH_MIN_SEC" ]; then
            printf 'refreshed=0\n'
            exit 0
        fi
        # Блокировка НЕ ждущая: пересчёт уже идёт (или занята мутация) — молча
        # отвечаем refreshed=0. Ждать нельзя: страница спрашивает каждые
        # несколько секунд, очередь из ждунов дороже, чем чуть менее свежие цифры.
        exec 200>"$DATA_DIR/.webapi.lock"
        flock -n 200 || { printf 'refreshed=0\n'; exit 0; }
        printf '%s' "$_now" > "$TRAFFIC_REFRESH_TS"
        # Только collect_activity: он даёт и свежий кумулятив (расход демо и
        # free-плана), и флаг active — то самое «в сети». Спидометр (collect_rates)
        # сюда не берём: его тик и так идёт каждые RATES_TICK_SEC, а лишний
        # опрос API протоколов удваивает цену запроса. Ошибку глотаем:
        # свежесть не важнее доступности.
        collect_activity >/dev/null 2>&1 || true
        printf 'refreshed=1\n'
        ;;

    demo-create)  # → user=… sub_url=… expires=… cap=… rate=…
        [ $# -eq 0 ] || fail 64 bad_args "demo-create"
        sub_enabled || fail 3 sub_disabled "подписка на ноде не настроена"
        take_lock
        out=$(demo_create) || fail 1 demo_failed "не удалось выдать демо"
        [ -n "$out" ] || fail 1 demo_failed "пустой ответ demo_create"
        printf '%s\n' "$out"
        ;;

    tg-bind)     # <tg_id> <user>
        [ $# -eq 2 ] || fail 64 bad_args "tg-bind <tg_id> <user>"
        valid_tgid "$1"; valid_user "$2"
        db_user_exists "$2" || is_user_disabled "$2" || fail 2 user_not_found "пользователь не найден"
        take_lock
        existing=$(tg_bound_user "$1" || true)
        if [ -n "$existing" ] && [ "$existing" != "$2" ]; then
            fail 3 already_bound "tg_id уже привязан к другому пользователю"
        fi
        tg_bind "$1" "$2" >/dev/null 2>&1
        printf 'bound=1\n'
        ;;

    redeem)      # <code> [tg_id] → username=… (код одноразовый — гасится)
        [ $# -ge 1 ] && [ $# -le 2 ] || fail 64 bad_args "redeem <code> [tg_id]"
        valid_code "$1"
        [ $# -eq 2 ] && valid_tgid "$2"
        take_lock
        user=$(bot_code_lookup "$1" || true)
        [ -n "$user" ] || fail 2 code_invalid "код не найден или истёк"
        if [ $# -eq 2 ]; then
            existing=$(tg_bound_user "$2" || true)
            if [ -n "$existing" ] && [ "$existing" != "$user" ]; then
                fail 3 already_bound "tg_id уже привязан к другому пользователю"
            fi
            tg_bind "$2" "$user" >/dev/null 2>&1
        fi
        printf 'username=%s\n' "$user"
        ;;

    user-links)  # <user> → link=hysteria2://… (read-verb: сборка ссылки требует
                 # config.yaml/get_ip — оставляем её родным lib-функциям)
        [ $# -eq 1 ] || fail 64 bad_args "user-links <user>"
        valid_user "$1"
        pass=$(get_user_password "$1" || true)
        [ -z "$pass" ] && pass=$(get_disabled_password "$1" || true)
        [ -n "$pass" ] || fail 2 user_not_found "пользователь не найден"
        printf 'link=%s\n' "$(build_user_link "$1" "$pass")"
        ;;

    user-all-links)  # <user> → link=<uri> построчно (все протоколы + все ноды
                     # кластера). Read-verb: сборка ссылок требует config/get_ip.
        [ $# -eq 1 ] || fail 64 bad_args "user-all-links <user>"
        valid_user "$1"
        # Печатаем по строке «link=<uri>»: контракт stdout = key=value,
        # демон читает повторяющийся ключ как список (run_dispatch_lines).
        while IFS= read -r _uri; do
            [ -n "$_uri" ] && printf 'link=%s\n' "$_uri"
        done < <(build_user_all_links "$1")
        ;;

    link-add)  # <user> → token=… (новая ссылка-устройство; лимит = кол-во устройств)
        [ $# -eq 1 ] || fail 64 bad_args "link-add <user>"
        valid_user "$1"
        db_user_exists "$1" || fail 2 user_not_found "пользователь не найден"
        sub_enabled || fail 3 sub_disabled "подписка на ноде не настроена"
        take_lock
        tok=$(sub_link_add "$1") || fail 3 links_exhausted "лимит ссылок исчерпан (по числу устройств)"
        [ -n "$tok" ] || fail 3 links_exhausted "лимит ссылок исчерпан (по числу устройств)"
        # Только этот юзер: полный sub_refresh перебирает всех и занимает
        # десятки секунд, а кнопке в мини-аппе надо ответить сразу.
        regen_user_subscription "$1" >/dev/null 2>&1 || true
        publish_subtokens >/dev/null 2>&1 || true
        write_sub_titles >/dev/null 2>&1 && systemctl reload caddy >/dev/null 2>&1 || true
        printf 'token=%s\n' "$tok"
        ;;

    link-del)  # <user> <token> (основную ссылку снять нельзя)
        [ $# -eq 2 ] || fail 64 bad_args "link-del <user> <token>"
        valid_user "$1"
        db_user_exists "$1" || fail 2 user_not_found "пользователь не найден"
        take_lock
        sub_link_remove "$1" "$2"
        case $? in
            0) : ;;
            2) fail 3 link_primary "основную ссылку снять нельзя" ;;
            *) fail 2 link_not_found "ссылка не найдена" ;;
        esac
        regen_user_subscription "$1" >/dev/null 2>&1 || true
        publish_subtokens >/dev/null 2>&1 || true
        write_sub_titles >/dev/null 2>&1 && systemctl reload caddy >/dev/null 2>&1 || true
        printf 'removed=%s\n' "$2"
        ;;

    tariff-set)  # <code> <title> <days> <devices> <prices> <currencies> <options>
                 # Upsert: существующий правим НА МЕСТЕ (позиция в витрине —
                 # часть каталога), новый дописываем в конец. Бота не
                 # рестартуем: tariff_list читает файл на каждом обращении.
        [ $# -eq 7 ] || fail 64 bad_args "tariff-set <code> <title> <days> <devices> <prices> <currencies> <options>"
        valid_tcode "$1"; valid_ttitle "$2"; valid_num "$3"; valid_num "$4"
        valid_tprices "$5"; valid_tcurrencies "$6"; valid_topts "$7"
        take_lock
        if [ -n "$(tariff_get "$1")" ]; then
            # force_opts: пустые опции от API означают «опций нет», а не
            # «оставь как было» (иначе снять лимиты снаружи было бы нельзя).
            tariff_update "$1" "$1" "$2" "$3" "$4" "$5" "$6" "$7" force_opts \
                || fail 1 tariff_write_failed "не удалось записать тариф"
        else
            tariff_add "$1" "$2" "$3" "$4" "$5" "$6" "$7" \
                || fail 1 tariff_write_failed "не удалось записать тариф"
        fi
        printf 'code=%s\n' "$1"
        ;;

    tariff-del)  # <code>
        [ $# -eq 1 ] || fail 64 bad_args "tariff-del <code>"
        valid_tcode "$1"
        take_lock
        [ -n "$(tariff_get "$1")" ] || fail 2 tariff_not_found "тариф не найден"
        tariff_del "$1"
        printf 'code=%s\n' "$1"
        ;;

    tariff-move) # <code> <up|down|позиция>
        [ $# -eq 2 ] || fail 64 bad_args "tariff-move <code> <up|down|N>"
        valid_tcode "$1"
        take_lock
        [ -n "$(tariff_get "$1")" ] || fail 2 tariff_not_found "тариф не найден"
        case "$2" in
            up|down) tariff_move "$1" "$2" || fail 3 tariff_at_edge "тариф уже с краю" ;;
            [0-9]|[0-9][0-9]|[0-9][0-9][0-9])
                tariff_move_to "$1" "$2" || fail 3 tariff_move_failed "не удалось переместить" ;;
            *) fail 64 bad_args "направление: up, down или номер позиции" ;;
        esac
        printf 'code=%s\n' "$1"
        ;;

    pricing-set) # <fixed|rate> <rub_per_star> — режим звёздной цены (bot.conf)
        [ $# -eq 2 ] || fail 64 bad_args "pricing-set <fixed|rate> <rub_per_star>"
        case "$1" in fixed | rate) ;; *) fail 64 bad_args "режим: fixed или rate" ;; esac
        [[ "$2" =~ ^[0-9]+([.][0-9]+)?$ ]] || fail 64 bad_number "курс — число"
        awk -v r="$2" 'BEGIN{exit !(r+0>0)}' || fail 64 bad_number "курс — число больше нуля"
        take_lock
        bot_set STARS_MODE "$1"
        bot_set STARS_RUB_PER_STAR "$2"
        printf 'stars_mode=%s\nrub_per_star=%s\n' "$1" "$2"
        ;;

    *)
        fail 64 unknown_verb "неизвестная команда: ${verb:-<пусто>}"
        ;;
esac
