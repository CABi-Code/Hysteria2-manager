#!/bin/bash
# ================================================
# Бот, админская часть: список и карточка юзера, статус сервера
# Часть Telegram-бота (общие настройки и API — lib/tgbot.sh).
# ================================================

# ---------- админ: список/карточка пользователя ----------
bot_admin_users() {   # chat_id page [message_id]
    local chat="$1" page="$2" mid="$3"
    local users total pages start
    users=$(get_all_users)
    total=$(printf '%s\n' "$users" | grep -c .)
    [ "$total" -eq 0 ] && { bot_show "$chat" "$mid" "Пользователей нет." "$KB_ADMIN"; return; }
    pages=$(( (total + 7) / 8 )); [ "$page" -gt "$pages" ] && page=$pages; [ "$page" -lt 1 ] && page=1
    start=$(( (page - 1) * 8 + 1 ))
    local online; online=$(api_get "/online")
    local rows u icon oc
    rows=$(printf '%s\n' "$users" | sed -n "${start},$((start+7))p" | while IFS= read -r u; do
        [ -n "$u" ] || continue
        if is_user_disabled "$u"; then icon="🔴"
        else
            oc=$(echo "$online" | jq -r --arg x "$u" '.[$x] // 0' 2>/dev/null); [[ "$oc" =~ ^[0-9]+$ ]] || oc=0
            [ "$oc" -gt 0 ] && icon="💚" || icon="⚫"
        fi
        jq -nc --arg t "$icon $u" --arg d "a:u:$u" '[{text:$t,callback_data:$d}]'
    done | jq -sc '.')
    local nav='[]'
    if [ "$pages" -gt 1 ]; then
        nav=$(jq -nc --arg p "a:users:$((page-1))" --arg n "a:users:$((page+1))" --arg t "стр. $page/$pages" \
            '[{text:"←",callback_data:$p},{text:$t,callback_data:"a:menu"},{text:"→",callback_data:$n}]')
    fi
    local kb; kb=$(jq -nc --argjson r "$rows" --argjson n "$nav" '{inline_keyboard:($r + (if ($n|length)>0 then [$n] else [] end))}')
    bot_show "$chat" "$mid" "👥 <b>Пользователи</b> (всего $total)" "$kb"
}

bot_admin_user_card() {   # chat_id username [message_id]
    local chat="$1" user="$2" mid="$3"
    local st exp exps tl tx rx dev oc ipc tglabel
    if is_user_disabled "$user"; then st="🔴 отключён"
    elif db_user_exists "$user"; then st="✅ активен"
    else st="❓ не найден"; fi
    exp=$(get_user_expiry "$user")
    if declare -F freeplan_has >/dev/null 2>&1 && freeplan_has "$user"; then
        exps="🆓 бесплатный тариф$(freeplan_limits_line) · платный был до ${exp:-—}"
    else
        [ -n "$exp" ] && exps="$exp ($(format_remaining "$exp" 2>/dev/null || echo '—'))" || exps="бессрочно"
    fi
    IFS='|' read -r _ tx rx <<< "$(get_user_traffic "$user")"
    dev=$(get_user_devices "$user")
    oc=$(api_get "/online" | jq -r --arg u "$user" '.[$u] // 0' 2>/dev/null); [[ "$oc" =~ ^[0-9]+$ ]] || oc=0
    ipc=$(get_user_ip_count "$user")
    tglabel=$(tg_user_chats "$user" | tr '\n' ' ')
    local text="👤 <b>$(tg_esc "$user")</b>
Статус: $st · онлайн: $oc
Срок: $exps
Трафик: ↑$(format_bytes "$tx") ↓$(format_bytes "$rx") · IP: $ipc
Устройств (лимит): $dev
Telegram: ${tglabel:-не привязан}"
    local tgl_text="🔴 Отключить"
    is_user_disabled "$user" && tgl_text="✅ Включить"
    local kb
    kb=$(jq -nc --arg u "$user" --arg tgl "$tgl_text" '{inline_keyboard:[
        [{text:$tgl,callback_data:("a:tgl:"+$u)},{text:"✂ Кик",callback_data:("a:kick:"+$u)}],
        [{text:"🔗 Ссылка",callback_data:("a:link:"+$u)},{text:"📡 Подписка",callback_data:("a:sub:"+$u)}],
        [{text:"⏰ +30 дней",callback_data:("a:ext:"+$u+":30")},{text:"⏰ +90",callback_data:("a:ext:"+$u+":90")},{text:"⏰ снять срок",callback_data:("a:ext:"+$u+":0")}],
        [{text:"🎫 Код привязки",callback_data:("a:code:"+$u)},{text:"🗑 Удалить",callback_data:("a:del:"+$u)}],
        [{text:"↩ К списку",callback_data:"a:users:1"}]
    ]}')
    bot_show "$chat" "$mid" "$text" "$kb"
}

# Кнопка возврата в карточку юзера — для экранов, которые её замещают
# (ссылка, подписка, код привязки).
bot_kb_back_user() {   # username
    jq -nc --arg u "$1" '{inline_keyboard:[[{text:"↩ К юзеру",callback_data:("a:u:"+$u)}]]}'
}

bot_admin_server_status() {   # chat_id [message_id]
    local chat="$1" mid="${2:-}" la mem du online total
    la=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)
    mem=$(free -m 2>/dev/null | awk '/^Mem:/{printf "%s/%s МБ", $3, $2}')
    du=$(df -h / 2>/dev/null | awk 'NR==2{printf "%s/%s (%s)", $3, $2, $5}')
    online=$(api_get "/online" | jq 'to_entries | map(select(.value>0)) | length' 2>/dev/null); [[ "$online" =~ ^[0-9]+$ ]] || online=0
    total=$(get_all_users | grep -c .)
    local hyst="🔴 остановлена"
    systemctl is-active --quiet "$SERVICE" 2>/dev/null && hyst="💚 работает"
    local kl="⚪ выкл"
    if declare -F klimit_down >/dev/null && { [ "$(klimit_down)" -gt 0 ] || [ "$(klimit_up)" -gt 0 ]; } 2>/dev/null; then
        klimit_active && kl="💚 ↓$(klimit_down)/↑$(klimit_up) Мбит" || kl="🔴 настроен, но не загружен"
    fi
    bot_show "$chat" "$mid" "📈 <b>Сервер «$(tg_esc "$(node_name 2>/dev/null || hostname -s)")»</b>
Hysteria: $hyst · онлайн: $online из $total
LoadAvg: ${la:-?} · RAM: ${mem:-?}
Диск: ${du:-?}
Лимит скорости: $kl" "$KB_ADMIN"
}

# ---------- обработка одного апдейта ----------
