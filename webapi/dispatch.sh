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
#     гоняются между собой (окно гонки с интерактивным меню остаётся, см. docs/API.md).
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

# Тот же набор модулей, что грузит hy2-manager.sh (без ui — интерактив не нужен).
for _lib in config deps api traffic ip_tracking online expiry limits users cron migration subscription protocols antiabuse perf cluster tgbot; do
    # shellcheck disable=SC1090
    source "$MANAGER_DIR/lib/${_lib}.sh"
done

fail() {   # exit_code api_code message
    printf 'error=%s\nmessage=%s\n' "$2" "$3"
    exit "$1"
}

valid_user()  { [[ "$1" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || fail 64 bad_username "недопустимое имя пользователя"; }
valid_tgid()  { [[ "$1" =~ ^[0-9]{1,20}$ ]] || fail 64 bad_tg_id "недопустимый tg_id"; }
valid_num()   { [[ "$1" =~ ^[0-9]{1,7}$ ]] || fail 64 bad_number "ожидалось число"; }
valid_code()  { [[ "$1" =~ ^[A-Za-z0-9]{4,64}$ ]] || fail 64 bad_code "недопустимый код"; }

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
        pass=$(bot_provision_user "$1") || fail 1 provision_failed "не удалось создать пользователя"
        [ -n "$pass" ] || fail 1 provision_failed "пустой пароль"
        write_authlimits >/dev/null 2>&1 || true
        sub_refresh >/dev/null 2>&1 || true
        printf 'password=%s\n' "$pass"
        if sub_enabled; then
            printf 'sub_url=%s\n' "$(subscription_url "$1")"
        fi
        ;;

    extend)      # <user> <days> → expiry=YYYY-MM-DD
        [ $# -eq 2 ] || fail 64 bad_args "extend <user> <days>"
        valid_user "$1"; valid_num "$2"
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
        set_user_limits "$1" "$2" "$(get_user_hardcheck "$1")" "" "$3" >/dev/null 2>&1
        write_authlimits >/dev/null 2>&1 || true
        # Пересобрать kernel-лимит: гарантирует HTB-класс под назначенную скорость
        # (иначе тариф без совпадающего класса игнорируется klimit_reconcile) и
        # немедленно раскладывает пер-IP правила. Меню бота делает то же (ui.sh).
        klimit_apply "$(klimit_down)" "$(klimit_up)" >/dev/null 2>&1 || true
        printf 'devices=%s\nrate=%s\n' "$(get_user_devices "$1")" "$(get_user_rate "$1")"
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

    *)
        fail 64 unknown_verb "неизвестная команда: ${verb:-<пусто>}"
        ;;
esac
