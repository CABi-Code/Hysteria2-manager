#!/bin/bash
# ================================================
# Анти-абуз: оценка «шаринга» подписки по ОДНОВРЕМЕННОМУ активному трафику на
# нескольких нодах и авто-включение жёсткой проверки на время.
#
# Идея. «Нарушение» — это когда подписка РЕАЛЬНО используется (скорость за минуту
# ≥ порога, см. collect_activity) сразу на БОЛЬШЕМ числе нод, чем разрешено
# устройств (pool_cap). Считаем НЕ объём трафика, а факт одновременной активности
# по текущей скорости КАЖДОЙ ноды. За такие минуты юзеру копятся баллы (0..100),
# которые сами угасают со временем. Когда балл переваливает порог — на время
# включается жёсткая проверка (traffic-based, см. enforce_active_node_limit),
# которая оставляет активной только «первую» ноду.
#
# Обмен между нодами. Сырые данные (активен/не активен по трафику на каждой ноде)
# уже расходятся ежеминутно в publish_stats (кол. 7-8). Раз в час каждая нода
# делает КОРРЕКЦИЮ (abuse_correct): угашает старый балл, добавляет за нарушения
# прошедшего часа, при превышении порога взводит окно авто-жёсткой проверки, и
# публикует итог. Ноды сливают эти итоги (abuse_apply): балл — LWW по метке
# времени, окно жёсткой проверки и пики — максимум (чтобы менее осведомлённая
# нода не снимала защиту раньше времени). Так все ноды сходятся к общему решению.
#
# ВАЖНО (переделка «утечки по IP»): раньше подозрение на шаринг ставилось по
# ЧИСЛУ уникальных IP. Это ложно срабатывало у роуминга (телефон на улице меняет
# IP постоянно) и у семьи (несколько устройств дома). Теперь подозрение — это
# именно ОДНОВРЕМЕННОЕ активное использование на нескольких нодах, а число IP —
# лишь справочная информация, не триггер.
# ================================================

# ---- Доступ к состоянию (ABUSE_FILE) ----
# Формат: «user|score|updated_ts|auto_hc_until|peak_active|viol_minutes».
_abuse_row()          { grep "^${1}|" "$ABUSE_FILE" 2>/dev/null | head -1; }
abuse_score()         { local v; v=$(_abuse_row "$1" | cut -d'|' -f2); [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" || echo 0; }
abuse_updated_ts()    { local v; v=$(_abuse_row "$1" | cut -d'|' -f3); [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" || echo 0; }
abuse_auto_hc_until() { local v; v=$(_abuse_row "$1" | cut -d'|' -f4); [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" || echo 0; }
abuse_peak_active()   { local v; v=$(_abuse_row "$1" | cut -d'|' -f5); [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" || echo 0; }

# Активна ли СЕЙЧАС авто-жёсткая проверка (окно ещё не истекло).
abuse_auto_hc_active() {
    local until; until=$(abuse_auto_hc_until "$1")
    [ "${until:-0}" -gt "$(date +%s)" ] 2>/dev/null
}

# Эффективная жёсткая проверка = ручная (userlimits) ИЛИ авто (окно анти-абуза).
# Именно её должны использовать энфорсеры и UI.
get_user_hardcheck_effective() {
    [ "$(get_user_hardcheck "$1")" = "1" ] && { echo 1; return; }
    abuse_auto_hc_active "$1" && echo 1 || echo 0
}

# Сколько нод СЕЙЧАС активно гонят трафик юзера (эта нода live + пиры из stats-
# кэша, кол. 7=active). Это и есть метрика «одновременного использования».
cluster_active_node_count() {   # user -> число
    local user="$1" la peers=0
    la=$(get_user_active "$user")
    if [ -d "$PEERS_DIR" ] && compgen -G "$PEERS_DIR/*.stats" >/dev/null 2>&1; then
        peers=$(awk -F'\t' -v u="$user" 'NF>=7 && $1==u && $7==1{c++} END{print c+0}' "$PEERS_DIR"/*.stats 2>/dev/null)
    fi
    [[ "$peers" =~ ^[0-9]+$ ]] || peers=0
    echo $(( la + peers ))
}

# ---- Ежеминутное НАБЛЮДЕНИЕ (вызывается из cluster_online_sync) ----
# Для каждого активного юзера смотрим, на скольких нодах он СЕЙЧАС активен по
# трафику. Если больше эффективного лимита устройств (pool_cap) — минута
# засчитывается как «нарушение», копим её (и «избыток» = сколько лишних нод).
# Ничего не кикаем — только накапливаем наблюдения часа в ABUSE_OBS_FILE.
abuse_observe() {
    sub_enabled || return 0
    local now user cap cn conn line viol samples esum pa pconn
    now=$(date +%s)
    local tmp="${ABUSE_OBS_FILE}.tmp"; : > "$tmp"
    while IFS= read -r user; do
        [ -n "$user" ] || continue
        cap=$(pool_cap "$user"); [[ "$cap" =~ ^[0-9]+$ ]] || cap=0
        cn=$(cluster_active_node_count "$user")
        conn=$(cluster_user_connections "$user")

        line=$(grep "^${user}|" "$ABUSE_OBS_FILE" 2>/dev/null | head -1)
        viol=$(printf   '%s' "$line" | cut -d'|' -f2); [[ "$viol" =~ ^[0-9]+$ ]]    || viol=0
        samples=$(printf '%s' "$line" | cut -d'|' -f3); [[ "$samples" =~ ^[0-9]+$ ]] || samples=0
        esum=$(printf   '%s' "$line" | cut -d'|' -f4); [[ "$esum" =~ ^[0-9]+$ ]]    || esum=0
        pa=$(printf     '%s' "$line" | cut -d'|' -f5); [[ "$pa" =~ ^[0-9]+$ ]]      || pa=0
        pconn=$(printf  '%s' "$line" | cut -d'|' -f6); [[ "$pconn" =~ ^[0-9]+$ ]]   || pconn=0

        samples=$(( samples + 1 ))
        [ "$cn" -gt "$pa" ] 2>/dev/null && pa=$cn
        [ "$conn" -gt "$pconn" ] 2>/dev/null && pconn=$conn
        if [ "$cap" -gt 0 ] && [ "$cn" -gt "$cap" ] 2>/dev/null; then
            viol=$(( viol + 1 )); esum=$(( esum + (cn - cap) ))
        fi
        printf '%s|%s|%s|%s|%s|%s\n' "$user" "$viol" "$samples" "$esum" "$pa" "$pconn" >> "$tmp"
    done < <(get_active_users)
    mv "$tmp" "$ABUSE_OBS_FILE" 2>/dev/null
}

# ---- Часовая КОРРЕКЦИЯ балла (вызывается из cron --antiabuse) ----
# score(new) = clamp( score*угасание + вклад_нарушений_часа, 0..100 ).
# Вклад = W * доля_минут_в_нарушении * (1 + средний_избыток), ограничен HOURLY_CAP,
# чтобы балл копился постепенно (за один час не «выстрелить» в максимум). При
# score ≥ HIGH — взводим/продлеваем окно авто-жёсткой проверки на AUTO_HC_HOURS.
# Окно само истекает по времени (см. abuse_auto_hc_active).
abuse_correct() {
    sub_enabled || return 0
    local now; now=$(date +%s)
    local W="${ABUSE_VIOL_WEIGHT:-40}" DEC="${ABUSE_DECAY_PER_HOUR:-10}" \
          CAPADD="${ABUSE_HOURLY_CAP:-35}" HIGH="${ABUSE_SCORE_HIGH:-60}" \
          HRS="${ABUSE_AUTO_HC_HOURS:-6}"
    [[ "$W"      =~ ^[0-9]+$ ]] || W=40
    [[ "$DEC"    =~ ^[0-9]+$ ]] || DEC=10
    [[ "$CAPADD" =~ ^[0-9]+$ ]] || CAPADD=35
    [[ "$HIGH"   =~ ^[0-9]+$ ]] || HIGH=60
    [[ "$HRS"    =~ ^[0-9]+$ ]] || HRS=6

    touch "$ABUSE_FILE" "$ABUSE_OBS_FILE" 2>/dev/null
    local tmp="${ABUSE_FILE}.tmp"; : > "$tmp"
    local users user
    users=$( { cut -d'|' -f1 "$ABUSE_OBS_FILE" 2>/dev/null; cut -d'|' -f1 "$ABUSE_FILE" 2>/dev/null; } | grep -v '^$' | sort -u )
    while IFS= read -r user; do
        [ -n "$user" ] || continue
        # Прошлое состояние.
        local prow score upd until
        prow=$(_abuse_row "$user")
        score=$(printf '%s' "$prow" | cut -d'|' -f2); [[ "$score" =~ ^[0-9]+$ ]] || score=0
        upd=$(printf   '%s' "$prow" | cut -d'|' -f3); [[ "$upd" =~ ^[0-9]+$ ]]   || upd=$now
        until=$(printf '%s' "$prow" | cut -d'|' -f4); [[ "$until" =~ ^[0-9]+$ ]] || until=0
        # Наблюдения за час.
        local orow viol samples esum pa
        orow=$(grep "^${user}|" "$ABUSE_OBS_FILE" 2>/dev/null | head -1)
        viol=$(printf   '%s' "$orow" | cut -d'|' -f2); [[ "$viol" =~ ^[0-9]+$ ]]    || viol=0
        samples=$(printf '%s' "$orow" | cut -d'|' -f3); [[ "$samples" =~ ^[0-9]+$ ]] || samples=0
        esum=$(printf   '%s' "$orow" | cut -d'|' -f4); [[ "$esum" =~ ^[0-9]+$ ]]    || esum=0
        pa=$(printf     '%s' "$orow" | cut -d'|' -f5); [[ "$pa" =~ ^[0-9]+$ ]]      || pa=0

        local newscore
        newscore=$(awk -v s="$score" -v upd="$upd" -v now="$now" \
            -v viol="$viol" -v samples="$samples" -v esum="$esum" \
            -v W="$W" -v DEC="$DEC" -v CAP="$CAPADD" 'BEGIN{
                hours=(now-upd)/3600.0; if(hours<0)hours=0;
                s = s - DEC*hours; if(s<0)s=0;
                if(samples>0 && viol>0){
                    ratio=viol/samples;                # доля часа в нарушении (0..1)
                    avg_excess=esum/viol;              # ≥1 (сколько лишних нод в среднем)
                    added=W*ratio*(1+avg_excess);
                    if(added>CAP)added=CAP;
                    s+=added;
                }
                if(s>100)s=100; if(s<0)s=0;
                printf "%d", int(s+0.5);
            }')
        [[ "$newscore" =~ ^[0-9]+$ ]] || newscore=0

        # Балл высок — (пере)взводим окно авто-жёсткой проверки.
        [ "$newscore" -ge "$HIGH" ] 2>/dev/null && until=$(( now + HRS*3600 ))

        printf '%s|%s|%s|%s|%s|%s\n' "$user" "$newscore" "$now" "$until" "$pa" "$viol" >> "$tmp"
    done <<< "$users"
    mv "$tmp" "$ABUSE_FILE" 2>/dev/null
    : > "$ABUSE_OBS_FILE"        # начать новый час наблюдений
    chmod 640 "$ABUSE_FILE" 2>/dev/null || true

    publish_cluster_abuse
    abuse_apply                 # слить с итогами пиров и получить общий взгляд
}

# ---- Кластерный обмен состоянием анти-абуза ----
publish_cluster_abuse() {
    sub_enabled || return 0
    mkdir -p "$WEBROOT/cluster"
    cp -f "$ABUSE_FILE" "$WEBROOT/cluster/abuse" 2>/dev/null || : > "$WEBROOT/cluster/abuse"
    chmod 640 "$WEBROOT/cluster/abuse" 2>/dev/null || true
    declare -F secure_web_files >/dev/null && secure_web_files
}

# Слить локальный ABUSE_FILE с кэшами пиров (PEERS_DIR/*.abuse). Балл берём по
# самой свежей метке (LWW по updated_ts), окно авто-жёсткой проверки и пики —
# максимумом. Так защита распространяется быстро и её не снимает раньше времени
# нода с устаревшими данными.
abuse_apply() {
    sub_enabled || return 0
    local merged
    merged=$(
        { [ -f "$ABUSE_FILE" ] && cat "$ABUSE_FILE"
          [ -d "$PEERS_DIR" ] && cat "$PEERS_DIR"/*.abuse 2>/dev/null; } \
        | awk -F'|' 'NF>=4 && $1!="" {
            u=$1;
            if(!(u in ts) || ($3+0)>ts[u]){ ts[u]=$3+0; sc[u]=$2+0 }
            if(($4+0)>until[u]) until[u]=$4+0;
            if(($5+0)>pa[u])    pa[u]=$5+0;
            if(($6+0)>vm[u])    vm[u]=$6+0;
          }
          END{ for(u in ts) printf "%s|%s|%s|%s|%s|%s\n", u, sc[u], ts[u], until[u]+0, pa[u]+0, vm[u]+0 }'
    )
    [ -n "$merged" ] || return 0
    printf '%s\n' "$merged" > "$ABUSE_FILE"
    chmod 640 "$ABUSE_FILE" 2>/dev/null || true
}

# Удалить состояние анти-абуза юзера (при полном удалении юзера).
remove_user_abuse() {
    sed -i "/^${1}|/d" "$ABUSE_FILE" "$ABUSE_OBS_FILE" 2>/dev/null
}

# Человекочитаемый статус анти-абуза для карточки/меню (одна строка).
abuse_status_line() {   # user
    local user="$1" sc until pa now left
    sc=$(abuse_score "$user"); until=$(abuse_auto_hc_until "$user"); pa=$(abuse_peak_active "$user")
    now=$(date +%s)
    local msg="Балл абуза: ${sc}/100"
    if [ "${until:-0}" -gt "$now" ] 2>/dev/null; then
        left=$(( (until - now + 59) / 60 ))
        msg="$msg · 🛡 авто-жёсткая проверка ВКЛ (ещё ~${left} мин)"
    elif [ "${pa:-0}" -gt 1 ] 2>/dev/null; then
        msg="$msg · пик одновременной активности: ${pa} нод(ы)"
    fi
    printf '%s' "$msg"
}
