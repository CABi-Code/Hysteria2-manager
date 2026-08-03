#!/bin/bash
# ================================================
# Тарифы: чтение/правка tariffs.conf, цены, валюты, опции
# Часть Telegram-бота (общие настройки и API — lib/tgbot.sh).
# ================================================

# ---------- тарифы ----------
# Строка: «код|Название|дней|устройств|цена|валюта». Валюта XTR = Telegram Stars
# (цена = кол-во звёзд, целое). Иначе — валюта платёжного провайдера
# (цена в ОСНОВНЫХ единицах: 199 = 199 руб; в копейки переводим сами).
#
# Мультивалютность: поля «цена» и «валюта» могут быть '/'-списками одинаковой
# длины (индексы выровнены), напр. «100/199|XTR/RUB» — один тариф с ценой и в
# звёздах, и в рублях. Одиночная цена — частный случай списка из одного элемента.
tariff_list()   { grep -vE '^\s*(#|$)' "$TARIFFS_CONF" 2>/dev/null; }
tariff_get()    { tariff_list | awk -F'|' -v c="$1" '$1==c{print; exit}'; }
tariff_count()  { tariff_list | grep -c '^'; }
tariff_add()    {   # code title days devices price currency [opts]
    touch "$TARIFFS_CONF"
    sed -i "/^${1}|/d" "$TARIFFS_CONF" 2>/dev/null
    # 7-е поле — конструктор тарифа «k=v;k=v» (free/wk/mo/start, см. lib/freeplan.sh).
    # Пустое не пишем: строка остаётся в старом 6-польном формате.
    if [ -n "$7" ]; then
        printf '%s|%s|%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7" >> "$TARIFFS_CONF"
    else
        printf '%s|%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >> "$TARIFFS_CONF"
    fi
}
tariff_del()    { sed -i "/^${1}|/d" "$TARIFFS_CONF" 2>/dev/null; }

# Заменить строку тарифа НА МЕСТЕ (позиция в файле = порядок в /buy и в webapp
# сохраняется). Код тоже можно сменить: ищем по СТАРОМУ коду, пишем новую строку.
tariff_update() {   # oldcode newcode title days devices price currency [opts] [force_opts]
    local old="$1"; shift
    # Опции (7-е поле) сохраняем, если их не передали: правка тарифа из меню не
    # должна молча снимать с него лимиты/флаг бесплатности. Редактор опций
    # (tariff_ask_opts) передаёт force_opts — там пустая строка означает
    # «лимитов больше нет», и подставлять старые нельзя.
    local opts="${7:-$(tariff_opts "$old")}"
    [ "${8:-}" = force_opts ] && opts="$7"
    local new="$1|$2|$3|$4|$5|$6"; [ -n "$opts" ] && new="$new|$opts"
    local tmp line
    tmp=$(mktemp) || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" == "$old|"* ]]; then printf '%s\n' "$new"; else printf '%s\n' "$line"; fi
    done < "$TARIFFS_CONF" > "$tmp"
    mv "$tmp" "$TARIFFS_CONF"
}

# Поменять тариф местами с соседним (dir = up|down). Меняет порядок показа
# тарифов клиенту. Возврат 1, если тариф уже с краю или не найден.
tariff_move() {   # code up|down
    local code="$1" dir="$2" tmp i idx=-1 j
    local -a lines
    mapfile -t lines < <(tariff_list)
    local n=${#lines[@]}
    for ((i=0; i<n; i++)); do
        [ "${lines[$i]%%|*}" = "$code" ] && { idx=$i; break; }
    done
    [ "$idx" -lt 0 ] && return 1
    if [ "$dir" = "up" ]; then j=$((idx-1)); else j=$((idx+1)); fi
    if [ "$j" -lt 0 ] || [ "$j" -ge "$n" ]; then return 1; fi
    local t="${lines[$idx]}"; lines[$idx]="${lines[$j]}"; lines[$j]="$t"
    tmp=$(mktemp) || return 1
    printf '%s\n' "${lines[@]}" > "$tmp"
    mv "$tmp" "$TARIFFS_CONF"
}

# Переставить тариф на позицию N (1-based) в списке: удаляем со старого места и
# вставляем на нужное. N вне диапазона зажимается к [1..кол-во]. Возврат 1, если
# тариф не найден.
tariff_move_to() {   # code position
    local code="$1" pos="$2" tmp i idx=-1 target
    [[ "$pos" =~ ^[0-9]+$ ]] || return 1
    local -a lines; mapfile -t lines < <(tariff_list)
    local n=${#lines[@]}
    [ "$n" -eq 0 ] && return 1
    [ "$pos" -lt 1 ] && pos=1; [ "$pos" -gt "$n" ] && pos="$n"
    for ((i=0; i<n; i++)); do
        [ "${lines[$i]%%|*}" = "$code" ] && { idx=$i; break; }
    done
    [ "$idx" -lt 0 ] && return 1
    target=$((pos-1))
    [ "$target" -eq "$idx" ] && return 0
    local moved="${lines[$idx]}"
    local -a rest=() out=()
    for ((i=0; i<n; i++)); do [ "$i" -ne "$idx" ] && rest+=("${lines[$i]}"); done
    for ((i=0; i<${#rest[@]}; i++)); do
        [ "$i" -eq "$target" ] && out+=("$moved")
        out+=("${rest[$i]}")
    done
    [ "$target" -ge "${#rest[@]}" ] && out+=("$moved")
    tmp=$(mktemp) || return 1
    printf '%s\n' "${out[@]}" > "$tmp"
    mv "$tmp" "$TARIFFS_CONF"
}

# Человеческая цена тарифа: «⭐ 100», «199 RUB» или список «⭐ 100 / 199 RUB».
# Оба аргумента — '/'-списки одинаковой длины (или одиночные значения).
tariff_price_str() {   # price[/...] currency[/...]
    local -a pa ca; IFS='/' read -r -a pa <<< "$1"; IFS='/' read -r -a ca <<< "$2"
    local i p c one out=""
    for i in "${!pa[@]}"; do
        p="${pa[$i]}"; c="${ca[$i]:-XTR}"
        if [ "$c" = "XTR" ]; then one="⭐ $p"; else one="$p $c"; fi
        [ -n "$out" ] && out="$out / $one" || out="$one"
    done
    printf '%s' "$out"
}

# Цена тарифа для конкретной валюты из '/'-списков price/cur (пусто → нет такой).
tariff_price_in_list() {   # price_list cur_list want_currency
    local -a pa ca; IFS='/' read -r -a pa <<< "$1"; IFS='/' read -r -a ca <<< "$2"
    local i
    for i in "${!ca[@]}"; do
        [ "${ca[$i]}" = "$3" ] && { printf '%s' "${pa[$i]}"; return 0; }
    done
    return 1
}

# ---------- цена в звёздах: fixed или от рублёвой ----------
# Два режима (bot.conf, меню «Цена в звёздах»), см. docs/design/SALES/README.md:
#   fixed — цена XTR берётся из строки тарифа как есть (поведение по умолчанию);
#   rate  — XTR считается из рублёвой цены: ceil(RUB / STARS_RUB_PER_STAR),
#           колонка XTR в файле игнорируется и может отсутствовать.
# Режим живёт ЗДЕСЬ, а не в надстройке: цена — часть каталога, а каталог у
# менеджера. Курс пополнения баланса — не сюда, это деньги надстройки.
stars_mode() { [ "$(bot_get STARS_MODE)" = rate ] && printf 'rate' || printf 'fixed'; }

# Рублей за звезду для режима rate. Мусор и 0 → 1 (цена в звёздах = цене в ₽),
# лишь бы не делить на ноль в витрине.
stars_rub_per_star() {
    awk -v r="$(bot_get STARS_RUB_PER_STAR)" 'BEGIN{ r=r+0; printf "%s", (r>0 ? r : 1) }'
}

# Цены тарифа с учётом режима: в rate звёздная цена пересчитывается из рублёвой
# (и появляется, даже если её нет в файле). Единственная точка пересчёта —
# витрина, счёт и API зовут её, а не считают сами.
tariff_prices_effective() {   # price_list cur_list -> «price_list cur_list»
    local pl="$1" cl="$2" rub xtr i seen=0
    [ "$(stars_mode)" = rate ] || { printf '%s %s' "$pl" "$cl"; return; }
    rub=$(tariff_price_in_list "$pl" "$cl" RUB) || { printf '%s %s' "$pl" "$cl"; return; }
    # Округляем ВВЕРХ: звёзды целые, а недобор — это продажа ниже цены.
    xtr=$(awk -v r="$rub" -v k="$(stars_rub_per_star)" 'BEGIN{ s=r/k; printf "%d", (s==int(s) ? s : int(s)+1) }')
    local -a pa ca; IFS='/' read -r -a pa <<< "$pl"; IFS='/' read -r -a ca <<< "$cl"
    for i in "${!ca[@]}"; do
        [ "${ca[$i]}" = "XTR" ] && { pa[$i]="$xtr"; seen=1; }
    done
    [ "$seen" = 0 ] && { pa+=("$xtr"); ca+=("XTR"); }
    local p c
    p=$(IFS='/'; printf '%s' "${pa[*]}"); c=$(IFS='/'; printf '%s' "${ca[*]}")
    printf '%s %s' "$p" "$c"
}

# Список валют тарифа (через пробел) по его коду — с учётом режима звёздной цены.
tariff_currencies_of() {   # code
    local row p c; row=$(tariff_get "$1"); [ -z "$row" ] && return 1
    IFS='|' read -r _ _ _ _ p c <<< "$row"
    read -r p c <<< "$(tariff_prices_effective "$p" "$c")"
    printf '%s' "$c" | tr '/' ' '
}

# Диалог ввода набора валют и цены для каждой. Результат в _TPRICE/_TCUR
# ('/'-списки). Возврат 1 при ошибке ввода (сообщение уже напечатано).
# Необязательные аргументы cur_default/price_default показываются как текущие.
tariff_ask_prices() {   # [cur_default] [price_default] [zero_ok]
    _TPRICE=""; _TCUR=""
    local dcur="${1:-}" dprice="${2:-}" zero_ok="${3:-0}" raw
    local hint="  Валюты через пробел/запятую/слеш (XTR — Stars; RUB/USD/...)"
    if [ -n "$dcur" ]; then
        ask raw "$hint [$(printf '%s' "$dcur" | tr '/' ' ')]: "; raw="${raw:-$dcur}"
    else
        ask raw "$hint (Enter = XTR): "; raw="${raw:-XTR}"
    fi
    raw=$(printf '%s' "$raw" | tr ',/' '  ' | tr 'a-z' 'A-Z')
    local -a curs=(); local c dup s
    for c in $raw; do
        [ -z "$c" ] && continue
        [[ "$c" =~ ^[A-Z]{3}$ ]] || { echo "  ❌ Валюта «$c» — ровно 3 буквы (XTR/RUB/USD...)."; return 1; }
        dup=0; for s in "${curs[@]}"; do [ "$s" = "$c" ] && dup=1; done
        [ "$dup" -eq 0 ] && curs+=("$c")
    done
    [ "${#curs[@]}" -eq 0 ] && { echo "  ❌ Не указано ни одной валюты."; return 1; }
    local -a prices=(); local cur p def
    for cur in "${curs[@]}"; do
        def=$(tariff_price_in_list "$dprice" "$dcur" "$cur" 2>/dev/null || true)
        if [ "$cur" = "XTR" ]; then
            ask p "  Цена в звёздах (XTR)${def:+ [$def]}: "
        else
            ask p "  Цена в $cur (целое, осн. единицы)${def:+ [$def]}: "
        fi
        p="${p:-$def}"
        # У бесплатного тарифа цена 0 — законная (zero_ok), у остальных нет.
        [[ "$p" =~ ^[0-9]+$ ]] && { [ "$p" -gt 0 ] || [ "$zero_ok" = 1 ]; } \
            || { echo "  ❌ Цена в $cur — целое число > 0."; return 1; }
        prices+=("$p")
    done
    local IFS='/'
    _TCUR="${curs[*]}"; _TPRICE="${prices[*]}"
    return 0
}

# Значение ключа в строке опций «k=v;k=v» (в отличие от tariff_opt берёт саму
# строку, а не код тарифа — опции могут быть ещё не сохранены).
tariff_opt_of() {   # opts key -> значение или пусто
    printf '%s' "$1" | tr ';' '\n' | awk -F= -v k="$2" '$1==k{print $2; exit}'
}

# Опции тарифа — 7-е поле строки («free=1;wk=5G;mo=15G;start=online», см.
# lib/freeplan.sh). Спрашиваем по ключам, а не одной строкой: строку руками не
# набрать без опечатки, а опечатка молча снимает лимит. Неизвестные ключи
# (появятся в будущем) сохраняем как есть.
tariff_ask_opts() {   # [current_opts] -> _TOPTS
    _TOPTS=""
    local cur="${1:-}" dfree dwk dmo dstart ans kv keep=""
    dfree=$(tariff_opt_of "$cur" free)
    dwk=$(tariff_opt_of "$cur" wk); dmo=$(tariff_opt_of "$cur" mo)
    dstart=$(tariff_opt_of "$cur" start)
    for kv in $(printf '%s' "$cur" | tr ';' ' '); do
        case "${kv%%=*}" in free|wk|mo|start) ;; *) [ -n "$kv" ] && keep="$keep;$kv" ;; esac
    done

    ask ans "  Бесплатный тариф — на него переводят по истечении платного (да/нет) [$([ "$dfree" = 1 ] && echo да || echo нет)]: "
    local free=0
    case "${ans:-$([ "$dfree" = 1 ] && echo да || echo нет)}" in
        да|yes|y|д|1) free=1 ;;
        нет|no|n|н|0|"") free=0 ;;
        *) echo "  ❌ Ответьте «да» или «нет»."; return 1 ;;
    esac

    ask ans "  Лимиты трафика «неделя месяц» (напр. «5G 15G»; пусто — без лимитов) [${dwk:-—} ${dmo:-—}]: "
    local wk mo
    if [ -z "$ans" ]; then
        wk="$dwk"; mo="$dmo"
    else
        read -r wk mo <<< "$(printf '%s' "$ans" | tr ',/' '  ')"
        # «-» и «0» — явный способ снять лимит, не выходя из редактора.
        [ "$wk" = "-" ] || [ "$wk" = "0" ] && wk=""
        [ "$mo" = "-" ] || [ "$mo" = "0" ] && mo=""
    fi
    local size
    for size in "$wk" "$mo"; do
        [ -z "$size" ] && continue
        [[ "${size^^}" =~ ^[0-9]+[GMK]?$ ]] || { echo "  ❌ Лимит «$size»: число с G/M/K (5G, 500M) или пусто."; return 1; }
    done

    local start=""
    if [ -n "$wk" ] || [ -n "$mo" ]; then
        ask ans "  Отсчёт окон: online — с первого выхода в сеть, paid — с оплаты [${dstart:-online}]: "
        start="${ans:-${dstart:-online}}"
        case "$start" in online|paid) ;; *) echo "  ❌ Только online или paid."; return 1 ;; esac
    fi

    local out=""
    [ "$free" = 1 ] && out="$out;free=1"
    [ -n "$wk" ] && out="$out;wk=${wk^^}"
    [ -n "$mo" ] && out="$out;mo=${mo^^}"
    [ -n "$start" ] && out="$out;start=$start"
    out="$out$keep"
    _TOPTS="${out#;}"
    return 0
}

