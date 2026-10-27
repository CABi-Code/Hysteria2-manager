#!/bin/bash
# ================================================
# Бесплатный тариф с лимитами трафика (idea 02 веб-аппа).
#
# КОНСТРУКТОР ТАРИФОВ. Любой тариф в tariffs.conf может нести 7-е поле опций
# «ключ=значение;…» (поле опционально — старые строки читаются как раньше):
#
#   free|Бесплатный|0|1|0/0|XTR/RUB|free=1;wk=5G;mo=15G;start=online
#
#   free=1      тариф бесплатный: в него автоматически падают, когда кончился
#               платный доступ (вместо отключения);
#   wk=<размер> лимит трафика на скользящее окно 7 дней;
#   mo=<размер> лимит трафика на скользящее окно 30 дней;
#   start=online|paid  с какого момента отсчитывать окна: с первого выхода
#               в онлайн (free) или с момента оплаты (обычные тарифы).
#
# КАК РАБОТАЕТ. Юзер с истёкшим сроком не отключается, а попадает в freeplan.dat
# в состоянии pending. Окна стартуют в момент первого выхода в онлайн (start=online)
# и дальше катятся сами: следующее окно начинается ровно через 7 (30) суток.
# Расход = ОБЩИЙ трафик по кластеру минус база, зафиксированная на старте окна.
# Выбрал любой из лимитов — юзер отключается до ближайшего сброса окна.
#
# ПОЧЕМУ ФАЙЛ КЛАСТЕРНЫЙ. Байты считаются по всем нодам сразу, поэтому и окна
# должны быть общими: будь состояние локальным, юзер сбрасывал бы квоту, просто
# переключившись на другую ноду (там окно стартовало бы заново с нулём).
# Синхронизация — LWW по ts, как cluster_state (см. cluster_apply_freeplan).
# ================================================

# ---------- опции тарифа (7-е поле) ----------

tariff_opts() {   # code -> «k=v;k=v» или пусто
    tariff_get "$1" 2>/dev/null | cut -d'|' -f7
}

tariff_opt() {    # code key -> значение или пусто
    local opts; opts=$(tariff_opts "$1")
    printf '%s' "$opts" | tr ';' '\n' | awk -F= -v k="$2" '$1==k{print $2; exit}'
}

# Код бесплатного тарифа (первый с free=1). Пусто = фича выключена.
free_tariff_code() {
    local row code
    while IFS= read -r row; do
        code=$(printf '%s' "$row" | cut -d'|' -f1)
        [ -n "$code" ] || continue
        [ "$(tariff_opt "$code" free)" = "1" ] && { printf '%s' "$code"; return 0; }
    done < <(tariff_list 2>/dev/null)
    return 1
}

free_enabled() { [ -n "$(free_tariff_code)" ]; }

# «5G» / «500M» / «100K» / «123» → байты. Пусто/мусор → 0 (лимита нет).
free_size_bytes() {   # size -> bytes
    local s="${1^^}" n mult=1
    case "$s" in
        *G) n=${s%G}; mult=$((1024*1024*1024)) ;;
        *M) n=${s%M}; mult=$((1024*1024)) ;;
        *K) n=${s%K}; mult=1024 ;;
        *)  n="$s" ;;
    esac
    [[ "$n" =~ ^[0-9]+$ ]] || { printf '0'; return; }
    printf '%s' $(( n * mult ))
}

free_wk_limit() { free_size_bytes "$(tariff_opt "$(free_tariff_code)" wk)"; }
free_mo_limit() { free_size_bytes "$(tariff_opt "$(free_tariff_code)" mo)"; }

# «: 5G в неделю, 15G в месяц» для карточек пользователя. Пусто, если лимитов
# нет вовсе (бесплатный тариф без ограничений трафика — тоже допустимая настройка).
freeplan_limits_line() {
    local code wk mo out=""
    code=$(free_tariff_code) || return 0
    wk=$(tariff_opt "$code" wk); mo=$(tariff_opt "$code" mo)
    [ -n "$wk" ] && out="$wk в неделю"
    [ -n "$mo" ] && out="${out:+$out, }$mo в месяц"
    [ -n "$out" ] && printf ': %s' "$out"
}

FREE_WEEK_SEC=604800     # 7 суток
FREE_MONTH_SEC=2592000   # 30 суток

# ---------- состояние ----------

freeplan_row()  { awk -F'|' -v u="$1" '$1==u{print; exit}' "$FREEPLAN_FILE" 2>/dev/null; }
freeplan_has()  { [ -n "$(freeplan_row "$1")" ]; }
freeplan_field(){ freeplan_row "$1" | cut -d'|' -f"$2"; }

freeplan_set() {   # user state start wk_start wk_base mo_start mo_base notified [ts]
    local user="$1" ts="${9:-$(date +%s)}"
    mkdir -p "$DATA_DIR"; touch "$FREEPLAN_FILE"
    sed -i "/^${user}|/d" "$FREEPLAN_FILE" 2>/dev/null
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$user" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$ts" >> "$FREEPLAN_FILE"
    declare -F publish_cluster_freeplan >/dev/null 2>&1 && publish_cluster_freeplan
}

freeplan_remove() {
    [ -f "$FREEPLAN_FILE" ] || return 0
    sed -i "/^${1}|/d" "$FREEPLAN_FILE" 2>/dev/null
    declare -F publish_cluster_freeplan >/dev/null 2>&1 && publish_cluster_freeplan
}

# Перевод на бесплатный тариф: срок кончился, но доступ не отключаем. Окна ещё
# не идут (pending) — они стартуют с первого выхода в онлайн (start=online).
freeplan_enter() {   # user [quiet]
    free_enabled || return 1
    freeplan_has "$1" && return 0          # уже на free — идемпотентно
    freeplan_set "$1" pending 0 0 0 0 0 0
    # quiet — юзер включил тариф сам кнопкой в кабинете: он видит результат на
    # экране, а «платный доступ закончился» в такой момент прямая ложь. Отметка
    # в журнале — чтобы и freeplan_notify_sync не прислал это позже.
    [ "${2:-}" = quiet ] && { _freeplan_mark "$1" entered; return 0; }
    freeplan_notify_sync
}

# Подключить бесплатный тариф ПО ЖЕЛАНИЮ (кнопка в кабинете), а не по истечении
# платного. Возврат 3 — платный доступ ещё действует: перебивать его бесплатным
# нельзя, иначе юзер сам себе обрежет оплаченное. Юзер без срока (провижининг без
# оплаты) тоже попадает сюда — ему проставляем вчерашнюю дату, чтобы состояние
# было тем же, что и у естественно истёкшего.
freeplan_activate() {   # user -> 0 ок · 1 нельзя · 3 подписка активна
    local user="$1" exp
    free_enabled || return 1
    db_user_exists "$user" || is_user_disabled "$user" || return 1
    exp=$(get_user_expiry "$user")
    # Оплаченный срок ещё идёт — перебивать его бесплатным нельзя (та же
    # проверка, что у check_expired_users и freeplan_tick).
    if [ -n "$exp" ] && ! expiry_is_over "$exp"; then
        freeplan_has "$user" || return 3
    fi
    [ -n "$(get_user_expiry "$user")" ] || set_user_expiry "$user" "$(date -d 'yesterday' +%Y-%m-%d)"
    is_user_disabled "$user" && enable_user "$user" >/dev/null 2>&1
    freeplan_enter "$user" quiet
}

# ---------- учёт трафика ----------

# Суммарные байты юзера ПО ВСЕМУ КЛАСТЕРУ (tx+rx, кумулятивно с момента заведения).
freeplan_user_bytes() {   # user -> bytes
    local user="$1" tl tx rx total line cum base peers
    tl=$(get_user_traffic "$user"); tx=$(printf '%s' "$tl" | cut -d'|' -f2); rx=$(printf '%s' "$tl" | cut -d'|' -f3)
    total=$(( ${tx:-0} + ${rx:-0} ))

    # Ещё не собранный остаток ЭТОЙ ноды: минутный снимок кумулятива
    # (activity_prev.dat) минус база, до которой уже досчитан STATS_FILE
    # (traffic_prev.dat). Даёт минутную точность там, где юзер качает прямо
    # сейчас, и не считает байты дважды. Раньше сбор обнулял счётчики движка, и
    # здесь брался весь кумулятив снимка — с неразрушающим сбором (P-37) он
    # растёт до рестарта движка, и такое сложение завысило бы расход в разы.
    line=$(grep "^${user}|" "$ACTIVITY_PREV_FILE" 2>/dev/null | head -1)
    cum=$(printf '%s' "$line" | cut -d'|' -f2)
    base=$(awk -F'|' -v u="$user" '$1==u {printf "%.0f", $2+$3; exit}' "$TRAFFIC_PREV_FILE" 2>/dev/null)
    if [[ "$cum" =~ ^[0-9]+$ ]]; then
        [[ "$base" =~ ^[0-9]+$ ]] || base=0
        [ "$cum" -gt "$base" ] && total=$(( total + cum - base ))
    fi

    # ponytail: трафик пиров берём из их опубликованной статистики — она обновляется
    # их 30-минутным сбором, т.е. чужие байты видны с задержкой до 30 мин. Перерасход
    # ограничен этим окном и только при переезде между нодами: нода, где юзер качает
    # ПРЯМО СЕЙЧАС, видит его минутно и отключит сама. Нужна точность — публиковать
    # живой кумулятив в publish_stats.
    if [ -d "$PEERS_DIR" ] && compgen -G "$PEERS_DIR/*.stats" >/dev/null 2>&1; then
        # «%.0f», а не «%d»: mawk (штатный awk в Debian) режет %d по int32, и любой
        # расход пира больше 2 ГиБ превращался в 2147483647 — квота недосчитывалась.
        peers=$(awk -F'\t' -v u="$user" 'NF>=4 && $1==u {s+=$3+$4} END{printf "%.0f", s+0}' "$PEERS_DIR"/*.stats 2>/dev/null)
        [[ "$peers" =~ ^[0-9]+$ ]] && total=$(( total + peers ))
    fi
    printf '%s' "$total"
}

# Начало текущего окна: катим стартовую метку вперёд шагами по длине окна, пока
# она не окажется в прошлом не дальше одного шага. Возвращает новую метку.
freeplan_window_start() {   # start_ts window_sec now -> ts
    local st="$1" win="$2" now="$3" k
    [ "${st:-0}" -gt 0 ] 2>/dev/null || { printf '%s' "$now"; return; }
    k=$(( (now - st) / win ))
    [ "$k" -lt 0 ] && k=0
    printf '%s' $(( st + k * win ))
}

# Снять с бесплатного тарифа тех, кто снова оплатил.
#
# Отдельно от freeplan_tick и БЕЗ гейта free_enabled: это не учёт квот, а уборка
# КЛАСТЕРНОГО файла, и нода, где free=1 не настроен, обязана делать её тоже.
# Иначе строка висит у оплатившего вечно, а последствия видит клиент:
#   • в заголовке подписки стоит квота бесплатного тарифа, и приложение пишет
#     «квота исчерпана» при полностью работающем платном доступе;
#   • любая нода, где free=1 всё-таки настроен, увидит перерасход и отключит
#     его — то самое отключение, из которого профиль потом не возвращается.
# Уборка идёт на КАЖДОЙ ноде именно поэтому: cluster_apply_freeplan сливает
# строки LWW, и удаление на одной ноде соседи привезли бы обратно (P-131).
freeplan_release_paid() {
    [ -s "$FREEPLAN_FILE" ] || return 0
    local user exp paid=""
    # Сначала собираем список, потом правим файл: freeplan_remove делает sed -i
    # по тому же файлу, который мы бы читали циклом.
    while IFS='|' read -r user _; do
        [ -n "$user" ] || continue
        [[ "$user" =~ ^[a-zA-Z0-9_-]+$ ]] || continue
        exp=$(get_user_expiry "$user")
        # Пустой срок — это не оплата, а бессрочный/неизвестный доступ:
        # expiry_is_over на пустой строке говорит «не истёк», и без этой
        # проверки мы сняли бы с тарифа всех подряд.
        [ -n "$exp" ] || continue
        expiry_is_over "$exp" && continue
        paid="$paid $user"
    done < "$FREEPLAN_FILE"
    [ -n "$paid" ] || return 0
    for user in $paid; do
        is_user_disabled "$user" && enable_user "$user" >/dev/null 2>&1
        freeplan_remove "$user"
    done
    # Заголовок подписки несёт квоту бесплатного тарифа — её надо перевыпустить,
    # иначе приложение продолжит показывать «квота исчерпана».
    declare -F sub_refresh >/dev/null 2>&1 && sub_refresh
    return 0
}

# ---------- прогон (раз в минуту из --online-sync) ----------

freeplan_tick() {
    [ -s "$FREEPLAN_FILE" ] || return 0
    freeplan_release_paid          # уборка за оплатившими — без гейта, см. выше
    free_enabled || return 0
    [ -s "$FREEPLAN_FILE" ] || return 0
    local now wk_lim mo_lim user state start wks wkb mos mob notif ts
    local bytes wk_used mo_used wk_new mo_new left changed rolled
    now=$(date +%s)
    wk_lim=$(free_wk_limit); mo_lim=$(free_mo_limit)

    while IFS='|' read -r user state start wks wkb mos mob notif ts; do
        [ -n "$user" ] || continue
        [[ "$user" =~ ^[a-zA-Z0-9_-]+$ ]] || continue

        # Снова оплатил — бесплатный тариф больше не при чём. Проверка общая с
        # check_expired_users (expiry_is_over): раньше здесь было своё сравнение,
        # и на сутках расхождения юзер каждую минуту слетал с тарифа и тут же
        # возвращался обратно — с уведомлением «платный доступ закончился».
        if ! expiry_is_over "$(get_user_expiry "$user")"; then
            is_user_disabled "$user" && enable_user "$user" >/dev/null 2>&1
            freeplan_remove "$user"
            continue
        fi

        # Ждём первого выхода в онлайн: пока юзер не пользуется — окна не идут.
        if [ "$state" = "pending" ]; then
            [ "$(get_user_active "$user")" = "1" ] || continue
            bytes=$(freeplan_user_bytes "$user")
            freeplan_set "$user" active "$now" "$now" "$bytes" "$now" "$bytes" 0
            continue
        fi

        bytes=$(freeplan_user_bytes "$user")
        changed=0; rolled=0

        # Прокрутка окон: новое окно — новая база (расход обнуляется).
        wk_new=$(freeplan_window_start "$wks" "$FREE_WEEK_SEC" "$now")
        mo_new=$(freeplan_window_start "$mos" "$FREE_MONTH_SEC" "$now")
        if [ "$wk_new" != "$wks" ]; then wks=$wk_new; wkb=$bytes; changed=1; rolled=1; fi
        if [ "$mo_new" != "$mos" ]; then mos=$mo_new; mob=$bytes; changed=1; rolled=1; fi

        wk_used=$(( bytes - ${wkb:-0} )); [ "$wk_used" -lt 0 ] && wk_used=0
        mo_used=$(( bytes - ${mob:-0} )); [ "$mo_used" -lt 0 ] && mo_used=0

        # Остаток до ближайшего из двух лимитов. has=0 — лимитов нет вовсе
        # (тариф free без wk/mo): тогда просто ничего не ограничиваем.
        local has=0
        left=0
        if [ "$wk_lim" -gt 0 ]; then left=$(( wk_lim - wk_used )); has=1; fi
        if [ "$mo_lim" -gt 0 ]; then
            local l2=$(( mo_lim - mo_used ))
            if [ "$has" = 0 ] || [ "$l2" -lt "$left" ]; then left=$l2; fi
            has=1
        fi

        if [ "$has" = 1 ] && [ "$left" -le 0 ]; then
            # Квота выбрана — отключаем до ближайшего сброса окна.
            if [ "$state" != "blocked" ]; then
                disable_user "$user" silent >/dev/null 2>&1
                declare -F cstate_mark >/dev/null 2>&1 && cstate_mark "$user" disabled
                state=blocked; notif=4; changed=1
            fi
        else
            # Есть остаток: если были заблокированы — впускаем, но ТОЛЬКО когда
            # окно действительно прокрутилось. Остаток без прокрутки значит
            # одно: эта нода видит меньше байт, чем та, что заблокировала
            # (статистика соседа приезжает с опозданием до 30 минут). Раньше
            # такая нода впускала обратно, та снова блокировала, состояние
            # переезжало между нодами по LWW, и человек каждые несколько минут
            # получал «доступ снова работает» и «трафик закончился» (P-160).
            if [ "$state" = "blocked" ] && [ "$rolled" = 1 ]; then
                is_user_disabled "$user" && enable_user "$user" >/dev/null 2>&1
                declare -F cstate_mark >/dev/null 2>&1 && cstate_mark "$user" active
                state=active; notif=0; changed=1
            fi
            # Пороги «осталось немного»: 1 ГБ → 500 МБ → 50 МБ, по одному разу.
            # Заблокированному (остаток виден только отстающей ноде) — молчим.
            if [ "$has" = 1 ] && [ "$state" != "blocked" ]; then
                local step=0
                [ "$left" -le $((1024*1024*1024)) ] && step=1
                [ "$left" -le $((500*1024*1024)) ] && step=2
                [ "$left" -le $((50*1024*1024)) ] && step=3
                if [ "$step" -gt "${notif:-0}" ] 2>/dev/null; then
                    notif=$step; changed=1
                fi
            fi
        fi

        [ "$changed" = 1 ] && freeplan_set "$user" "$state" "$start" "$wks" "$wkb" "$mos" "$mob" "$notif"
    done < "$FREEPLAN_FILE"
    freeplan_notify_sync
}

# ---------- уведомления: из состояния, один раз, одной нодой ----------
# Состояние бесплатного тарифа кластерное (LWW), а переход в нём делает та
# нода, что посчитала первой. Слать сообщение из самого перехода значило:
# нода без бота его теряла, а каждая нода с токеном того же бота — дублировала,
# и любая качель состояния превращалась в поток сообщений (P-160, P-162).
# Поэтому переходы молчат, а сообщения выводит из СОСТОЯНИЯ нода с запущенным
# демоном бота (двух живых на один токен не бывает) — по своему журналу
# отправленного: событие уходит один раз на окно квоты, как бы ни качалось.
#   entered             — перевод на бесплатный (раз за пребывание на нём);
#   blocked:<wk>:<mo>   — квота выбрана в этих окнах;
#   reset:<wk>:<mo>     — доступ вернулся в новых окнах (только после blocked);
#   low<N>:<wk>:<mo>    — порог «осталось немного» N в этих окнах.
# Журнал локальный: его читатель — только эта нода. Ушёл юзер с тарифа —
# строки уходят, следующий заход начнётся с «entered».
FREEPLAN_NOTIFIED_FILE="${FREEPLAN_NOTIFIED_FILE:-$DATA_DIR/freeplan_notified.dat}"

_freeplan_marked() { grep -qxF "$1|$2" "$FREEPLAN_NOTIFIED_FILE" 2>/dev/null; }
_freeplan_mark()   { _freeplan_marked "$1" "$2" || printf '%s|%s\n' "$1" "$2" >> "$FREEPLAN_NOTIFIED_FILE"; }

# Остаток до ближайшего лимита и момент возврата доступа — те же правила, что
# у freeplan_tick. Печатает «left reset_ts».
_freeplan_left_reset() {   # user wks wkb mos mob
    local bytes wk_lim mo_lim wk_used mo_used left=0 has=0 reset=0 mreset l2
    bytes=$(freeplan_user_bytes "$1"); wk_lim=$(free_wk_limit); mo_lim=$(free_mo_limit)
    wk_used=$(( bytes - ${3:-0} )); [ "$wk_used" -lt 0 ] && wk_used=0
    mo_used=$(( bytes - ${5:-0} )); [ "$mo_used" -lt 0 ] && mo_used=0
    if [ "$wk_lim" -gt 0 ]; then left=$(( wk_lim - wk_used )); has=1; fi
    if [ "$mo_lim" -gt 0 ]; then
        l2=$(( mo_lim - mo_used ))
        if [ "$has" = 0 ] || [ "$l2" -lt "$left" ]; then left=$l2; fi
    fi
    [ "$left" -lt 0 ] && left=0
    # Выбраны оба окна — доступ вернётся с позднейшим из сбросов: пока не
    # освободятся оба лимита, юзер всё равно заблокирован.
    [ "$wk_lim" -gt 0 ] && [ "$wk_used" -ge "$wk_lim" ] && reset=$(( $2 + FREE_WEEK_SEC ))
    if [ "$mo_lim" -gt 0 ] && [ "$mo_used" -ge "$mo_lim" ]; then
        mreset=$(( $4 + FREE_MONTH_SEC ))
        [ "$mreset" -gt "$reset" ] && reset=$mreset
    fi
    [ "$reset" -gt 0 ] || reset=$(( $2 + FREE_WEEK_SEC ))
    printf '%s %s' "$left" "$reset"
}

freeplan_notify_sync() {
    declare -F bot_running >/dev/null 2>&1 && bot_running || return 0
    [ -f "$FREEPLAN_FILE" ] || return 0
    local prime=0 user state start wks wkb mos mob notif ts win lr step k
    # Первый запуск: всё, что уже есть, считается отправленным — иначе
    # выкатка разослала бы каждому на бесплатном тарифе его историю заново.
    [ -f "$FREEPLAN_NOTIFIED_FILE" ] || prime=1
    touch "$FREEPLAN_NOTIFIED_FILE" 2>/dev/null || return 0
    chmod 600 "$FREEPLAN_NOTIFIED_FILE" 2>/dev/null

    while IFS='|' read -r user state start wks wkb mos mob notif ts; do
        [[ "$user" =~ ^[a-zA-Z0-9_-]+$ ]] || continue
        win="$wks:$mos"
        if ! _freeplan_marked "$user" entered; then
            [ "$prime" = 1 ] || { declare -F bot_notify_free_entered >/dev/null 2>&1 && bot_notify_free_entered "$user"; }
            _freeplan_mark "$user" entered
        fi
        case "$state" in
            blocked)
                if ! _freeplan_marked "$user" "blocked:$win"; then
                    lr=$(_freeplan_left_reset "$user" "$wks" "$wkb" "$mos" "$mob")
                    [ "$prime" = 1 ] || { declare -F bot_notify_free_blocked >/dev/null 2>&1 && bot_notify_free_blocked "$user" "${lr#* }"; }
                    _freeplan_mark "$user" "blocked:$win"
                fi ;;
            active)
                # Вернулся после блокировки — в НОВЫХ окнах и один раз.
                if grep -q "^${user}|blocked:" "$FREEPLAN_NOTIFIED_FILE" 2>/dev/null \
                   && ! _freeplan_marked "$user" "blocked:$win" && ! _freeplan_marked "$user" "reset:$win"; then
                    lr=$(_freeplan_left_reset "$user" "$wks" "$wkb" "$mos" "$mob")
                    [ "$prime" = 1 ] || { declare -F bot_notify_free_reset >/dev/null 2>&1 && bot_notify_free_reset "$user" "${lr%% *}"; }
                    _freeplan_mark "$user" "reset:$win"
                fi
                # Порог: шлём один, самый строгий из неотправленных, остальные
                # отмечаем — без пачки «1 ГБ, 500 МБ, 50 МБ» разом.
                [[ "$notif" =~ ^[1-3]$ ]] || continue
                if ! _freeplan_marked "$user" "low$notif:$win"; then
                    lr=$(_freeplan_left_reset "$user" "$wks" "$wkb" "$mos" "$mob")
                    [ "$prime" = 1 ] || { declare -F bot_notify_free_low >/dev/null 2>&1 && bot_notify_free_low "$user" "${lr%% *}"; }
                fi
                for step in $(seq 1 "$notif"); do _freeplan_mark "$user" "low$step:$win"; done ;;
        esac
    done < "$FREEPLAN_FILE"

    # Уборка: ушёл с бесплатного — его отметки больше не нужны.
    k="${FREEPLAN_NOTIFIED_FILE}.tmp.$BASHPID"
    awk -F'|' 'NR==FNR { on[$1]=1; next } ($1 in on)' "$FREEPLAN_FILE" "$FREEPLAN_NOTIFIED_FILE" > "$k" 2>/dev/null \
        && mv "$k" "$FREEPLAN_NOTIFIED_FILE" || rm -f "$k"
    chmod 600 "$FREEPLAN_NOTIFIED_FILE" 2>/dev/null   # mv принёс права временного файла
}

# Наружу состояние отдаёт Web API: он и так читает stats/peers для traffic,
# поэтому считает окна сам по freeplan.dat (см. free_status в webapi/wa_users.py).

# ---------- кластер ----------

publish_cluster_freeplan() {
    sub_enabled || return 0
    mkdir -p "$WEBROOT/cluster"; touch "$FREEPLAN_FILE"
    cp -f "$FREEPLAN_FILE" "$WEBROOT/cluster/freeplan" 2>/dev/null || : > "$WEBROOT/cluster/freeplan"
    chmod 640 "$WEBROOT/cluster/freeplan" 2>/dev/null || true
    secure_web_files
}

# Слить состояния с пиров: по каждому юзеру берём строку с наибольшим ts.
# Все поля строки нодо-независимы (байты считаются по всему кластеру), поэтому
# LWW корректен: у кого свежее решение — того и состояние.
cluster_apply_freeplan() {
    sub_enabled || return 0
    # БЕЗ проверки free_enabled: состояние бесплатного тарифа кластерное, а
    # тарифы у нод свои. Нода, где free=1 не настроен, всё равно обязана знать,
    # что юзер на бесплатном, — иначе check_expired_users отключит его у себя
    # (и пришлёт «автоотключение»), пока другие ноды считают его живым.
    local merged
    merged=$(
        { [ -f "$FREEPLAN_FILE" ] && cat "$FREEPLAN_FILE"
          [ -d "$PEERS_DIR" ] && cat "$PEERS_DIR"/*.freeplan 2>/dev/null; } \
        | awk -F'|' 'NF>=9 && $1!="" { if (($9+0) > (ts[$1]+0)) { ts[$1]=$9; row[$1]=$0 } }
                     END { for (u in row) print row[u] }'
    )
    [ -n "$merged" ] || return 0
    printf '%s\n' "$merged" > "$FREEPLAN_FILE"
    publish_cluster_freeplan
    # Переход мог сделать сосед — сообщение всё равно уходит отсюда, один раз.
    freeplan_notify_sync
}
