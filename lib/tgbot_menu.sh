#!/bin/bash
# ================================================
# Бот: systemd-юнит и меню управления ботом/тарифами в TUI
# Часть Telegram-бота (общие настройки и API — lib/tgbot.sh).
# ================================================

# ---------- systemd-юнит ----------
bot_install_unit() {
    cat > "$BOT_UNIT" <<EOF
[Unit]
Description=Hysteria2 Manager Telegram bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash ${SCRIPT_DIR}/hy2-manager.sh --bot-daemon
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload 2>/dev/null
}

bot_start()  { bot_install_unit; systemctl enable --now hy2-bot.service &>/dev/null; bot_running; }
bot_stop()   { systemctl disable --now hy2-bot.service &>/dev/null; return 0; }
bot_remove() { bot_stop; rm -f "$BOT_UNIT"; systemctl daemon-reload 2>/dev/null; }
bot_restart(){ bot_running && systemctl restart hy2-bot.service &>/dev/null; return 0; }

# ---------- TUI-меню бота (вызывается из настроек менеджера) ----------
bot_menu() {
    while true; do
        clear
        local tok admins st getme un prov cur
        tok=$(bot_token); admins=$(bot_get ADMIN_IDS)
        prov=$(bot_get PAY_PROVIDER_TOKEN); cur=$(bot_get PAY_CURRENCY); [ -z "$cur" ] && cur=RUB
        if bot_running; then st="💚 работает"; elif bot_enabled; then st="🔴 остановлен"; else st="⚪ не настроен"; fi
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  🤖 Telegram-бот"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Статус     : $st"
        echo "  Токен      : $([ -n "$tok" ] && echo "задан (${tok:0:10}…)" || echo "❌ не задан")"
        echo "  Админы     : ${admins:-❌ не заданы}"
        un=$(bot_get BOT_USERNAME)
        echo "  Бот        : $([ -n "$un" ] && echo "@$un" || echo "имя не определено (запустите бота)")"
        echo "  Тарифов    : $(tariff_count 2>/dev/null || echo 0)"
        echo "  Провайдер  : $([ -n "$prov" ] && echo "настроен, валюта $cur" || echo "не настроен (доступны Telegram Stars)")"
        echo "  ЮMoney     : $(ym_enabled && echo "кошелёк $(bot_get YM_WALLET), комиссия $(ym_fee) %, $([ "$(ym_type)" = PC ] && echo "кошелёк ЮMoney" || echo "карта")" || echo "не настроен")"
        echo "  Оплат всего: $(grep -c '^' "$PAYMENTS_LOG" 2>/dev/null | tr -dc '0-9' || echo 0)"
        echo "  Модули     : $(for m in sales notify admin; do bot_mod_on "$m" && printf '%s ' "$m"; done)"
        echo ""
        echo "  1. 🔑 Задать токен бота (из @BotFather)"
        echo "  2. 👑 Задать админов (chat ID через запятую; свой ID — команда /id боту)"
        echo "  3. $(bot_running && echo "⏹  Остановить бота" || echo "▶  Запустить бота")"
        echo "  4. 💰 Тарифы (просмотр/добавление/удаление)"
        echo "  5. 💳 Платёжный провайдер (токен BotFather Payments + валюта)"
        echo "  6. 🔗 Привязки Telegram (список/отвязать)"
        echo "  7. 🎫 Выдать код привязки пользователю"
        echo "  8. 📨 Тест: сообщение всем админам"
        echo "  9. 📜 Логи бота (последние 25 строк)"
        echo " 10. 🪙 ЮMoney: приём рублей на личный кошелёк (без провайдера)"
        echo " 11. 🧩 Модули бота (продажа / уведомления / админ-панель)"
        echo "  0. ↩  Назад"
        echo ""
        local ch; ask ch "  Выберите: "
        case "$ch" in
            1)
                echo ""
                echo "  Создайте бота у @BotFather (/newbot) и вставьте токен вида 123456:AA..."
                local t; ask t "  Токен: "
                t=$(printf '%s' "$t" | tr -d '[:space:]')
                if [[ "$t" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
                    bot_set BOT_TOKEN "$t"
                    # Сразу проверяем токен запросом getMe.
                    BOT_TOKEN="$t"
                    getme=$(tg_api getMe)
                    un=$(echo "$getme" | jq -r '.result.username // empty' 2>/dev/null)
                    if [ -n "$un" ]; then
                        bot_set BOT_USERNAME "$un"
                        echo "  ✅ Токен работает: @$un"
                        bot_restart
                    else
                        echo "  ⚠️  Токен сохранён, но Telegram не ответил (сеть? токен?)."
                    fi
                elif [ -n "$t" ]; then
                    echo "  ❌ Не похоже на токен BotFather."
                fi
                pause ;;
            2)
                echo ""
                echo "  Узнать свой ID: напишите боту /id (или @userinfobot)."
                local ids; ask ids "  ID админов через запятую [${admins}]: "
                if [ -n "$ids" ]; then
                    if [[ "$ids" =~ ^[0-9,[:space:]-]+$ ]]; then
                        bot_set ADMIN_IDS "$(printf '%s' "$ids" | tr -d '[:space:]')"
                        echo "  ✅ Сохранено."
                        bot_restart
                    else
                        echo "  ❌ Только цифры и запятые."
                    fi
                fi
                pause ;;
            3)
                if bot_running; then
                    bot_stop
                    echo "  ⏹ Бот остановлен (юнит hy2-bot отключён)."
                else
                    if [ -z "$(bot_token)" ]; then
                        echo "  ❌ Сначала задайте токен (пункт 1)."
                    elif [ -z "$(bot_get ADMIN_IDS)" ]; then
                        echo "  ❌ Сначала задайте админов (пункт 2) — иначе ботом никто не управляет."
                    else
                        if bot_start; then
                            echo "  ✅ Бот запущен (systemd: hy2-bot.service, автозапуск включён)."
                            echo "     Напишите боту /start."
                        else
                            echo "  ❌ Бот не стартовал — journalctl -u hy2-bot -e и логи (пункт 9)."
                        fi
                    fi
                fi
                pause ;;
            4)
                bot_tariffs_menu ;;
            5)
                echo ""
                echo "  Оплата возможна двумя способами:"
                echo "   • Telegram Stars (валюта XTR) — работает СРАЗУ, настройка не нужна;"
                echo "   • Карты/СБП через провайдера BotFather: @BotFather → /mybots → ваш бот →"
                echo "     Payments → выберите провайдера (ЮKassa, Stripe и др.) → получите токен."
                local pt pc
                ask pt "  Токен провайдера (Enter — не менять, '-' — убрать): "
                if [ "$pt" = "-" ]; then
                    bot_set PAY_PROVIDER_TOKEN ""
                    echo "  ✅ Провайдер убран (останутся только Stars-тарифы)."
                elif [ -n "$pt" ]; then
                    bot_set PAY_PROVIDER_TOKEN "$(printf '%s' "$pt" | tr -d '[:space:]')"
                    echo "  ✅ Токен провайдера сохранён."
                fi
                ask pc "  Валюта провайдера (RUB/USD/EUR..., сейчас $cur): "
                if [ -n "$pc" ]; then
                    pc=$(printf '%s' "$pc" | tr 'a-z' 'A-Z' | tr -d '[:space:]')
                    [[ "$pc" =~ ^[A-Z]{3}$ ]] && { bot_set PAY_CURRENCY "$pc"; echo "  ✅ Валюта: $pc"; } || echo "  ❌ Код валюты — 3 буквы."
                fi
                bot_restart
                pause ;;
            10)
                echo ""
                echo "  Приём рублей на ЛИЧНЫЙ кошелёк ЮMoney — без юрлица и провайдера."
                echo "  Клиент платит по ссылке, бот сам находит платёж по метке и выдаёт доступ."
                echo "  Нужны две вещи:"
                echo "   • номер кошелька (yoomoney.ru → Настройки);"
                echo "   • OAuth-токен со scope operation-history — им бот читает историю"
                echo "     операций и опознаёт оплату. Как получить: docs/guide/YOOMONEY.md."
                echo "  Тарифы при этом должны иметь цену в валюте RUB (пункт 4)."
                echo ""
                local yw yt yf yp
                ask yw "  Номер кошелька (Enter — не менять, '-' — убрать): "
                if [ "$yw" = "-" ]; then
                    bot_set YM_WALLET ""; echo "  ✅ ЮMoney отключён."
                elif [ -n "$yw" ]; then
                    yw=$(printf '%s' "$yw" | tr -cd '0-9')
                    [ -n "$yw" ] && { bot_set YM_WALLET "$yw"; echo "  ✅ Кошелёк: $yw"; } || echo "  ❌ Номер кошелька — только цифры."
                fi
                ask yt "  Токен operation-history (Enter — не менять): "
                [ -n "$yt" ] && { bot_set YM_TOKEN "$(printf '%s' "$yt" | tr -d '[:space:]')"; echo "  ✅ Токен сохранён."; }
                echo ""
                echo "  Комиссию ЮMoney берёт С ПОЛУЧАТЕЛЯ: карта — 3 %, кошелёк ЮMoney — ~1 %."
                echo "  Указанный процент прибавляется к цене тарифа в счёте, чтобы на кошелёк"
                echo "  пришла ровно цена. Ставьте не меньше реальной комиссии выбранного типа."
                ask yf "  Комиссия сервиса, % (сейчас $(ym_fee)): "
                if [ -n "$yf" ]; then
                    [[ "$yf" =~ ^[0-9]+([.][0-9]+)?$ ]] && { bot_set YM_FEE "$yf"; echo "  ✅ Комиссия: $yf %"; } || echo "  ❌ Процент — число."
                fi
                ask yp "  Способ оплаты по умолчанию: AC — карта, PC — кошелёк ЮMoney (сейчас $(ym_type)): "
                if [ -n "$yp" ]; then
                    yp=$(printf '%s' "$yp" | tr 'a-z' 'A-Z' | tr -d '[:space:]')
                    [ "$yp" = "AC" ] || [ "$yp" = "PC" ] && { bot_set YM_TYPE "$yp"; echo "  ✅ Способ: $yp"; } || echo "  ❌ Только AC или PC."
                fi
                if [ -n "$(bot_get YM_WALLET)" ] && [ -z "$(bot_get YM_TOKEN)" ]; then
                    echo "  ⚠️  Без токена оплату подтвердить нечем — способ останется выключенным."
                fi
                bot_restart
                pause ;;
            11)
                echo ""
                echo "  Бот собран из модулей — выключенный исчезает у клиента, остальное работает."
                echo "  Вне модулей (не выключаются): привязка по коду, приём пополнений мини-аппа,"
                echo "  делегирование /start мини-аппу. Подробнее: docs/design/SALES/README.md."
                echo ""
                echo "   sales  — продажа тарифов ботом: витрина, счета Stars/провайдер/ЮMoney"
                echo "   notify — уведомления: истечение срока, бесплатный тариф, алерты админам"
                echo "   admin  — админ-панель и админ-команды в боте"
                echo ""
                local mod mods x
                for x in sales notify admin; do
                    printf '   %-7s %s\n' "$x" "$(bot_mod_on "$x" && echo "💚 включён" || echo "⚪ выключен")"
                done
                echo ""
                ask mod "  Какой модуль переключить (sales/notify/admin, Enter — назад): "
                mod=$(printf '%s' "$mod" | tr -d '[:space:]' | tr 'A-Z' 'a-z')
                case "$mod" in
                    sales|notify|admin)
                        mods=""
                        for x in sales notify admin; do
                            if [ "$x" = "$mod" ]; then
                                bot_mod_on "$x" && continue      # был включён — выключаем
                            else
                                bot_mod_on "$x" || continue      # чужой выключенный не воскрешаем
                            fi
                            mods="${mods:+$mods,}$x"
                        done
                        # Пустое значение ключа означало бы «включено всё» (так
                        # ведут себя старые конфиги), поэтому «выключено всё» —
                        # это явное none.
                        bot_set BOT_MODULES "${mods:-none}"
                        echo "  ✅ Включены: ${mods:-— (ничего, бот только принимает пополнения и привязки)}"
                        bot_restart ;;
                    "") ;;
                    *) echo "  ❌ Нет такого модуля." ;;
                esac
                pause ;;
            6)
                echo ""
                echo "  Привязки (tg_id → пользователь):"
                local i=0 tgid u ts
                local -a unb_ids=()
                while IFS='|' read -r tgid u ts; do
                    [ -n "$tgid" ] && [ -n "$u" ] || continue   # пропускаем tombstone-отвязки
                    i=$((i+1)); unb_ids[$i]="$tgid"
                    printf "    %d. tg:%s → %s (с %s)\n" "$i" "$tgid" "$u" "$(date -d "@${ts:-0}" '+%Y-%m-%d' 2>/dev/null || echo '?')"
                done < "$TGUSERS_FILE" 2>/dev/null
                [ "$i" -eq 0 ] && echo "    (пусто)"
                echo ""
                local sel; ask sel "  Номер для ОТВЯЗКИ (Enter — назад): "
                if [[ "$sel" =~ ^[0-9]+$ ]] && [ -n "${unb_ids[$sel]:-}" ]; then
                    tg_unbind "${unb_ids[$sel]}"
                    echo "  ✅ Отвязано."
                fi
                pause ;;
            7)
                echo ""
                local u code
                ask u "  Имя пользователя: "
                if db_user_exists "$u" || is_user_disabled "$u"; then
                    code=$(bot_bind_code "$u")
                    un=$(bot_get BOT_USERNAME)
                    echo "  🎫 Код (48 ч): $code"
                    echo "     Клиент отправляет боту: /start $code"
                    [ -n "$un" ] && echo "     Или по ссылке: https://t.me/${un}?start=${code}"
                else
                    echo "  ❌ Пользователь не найден."
                fi
                pause ;;
            8)
                BOT_TOKEN=$(bot_token)
                if [ -n "$BOT_TOKEN" ]; then
                    bot_notify_admins "✅ Тест: менеджер на «$(tg_esc "$(node_name 2>/dev/null || hostname -s)")» видит бота."
                    echo "  📨 Отправлено (если админы верны и бот запущен /start-ом у них)."
                else
                    echo "  ❌ Токен не задан."
                fi
                pause ;;
            9)
                echo ""
                tail -n 25 "$BOT_LOG" 2>/dev/null | sed 's/^/  /' || echo "  (лог пуст)"
                pause ;;
            0) return ;;
            *) echo "  ❌ Неверный выбор!"; sleep 1 ;;
        esac
    done
}

# Подменю тарифов.
bot_tariffs_menu() {
    while true; do
        clear
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  💰 Тарифы бота (что видит клиент в /buy)"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        local i=0 code title days devices price cur topts
        local -a t_codes=()
        while IFS='|' read -r code title days devices price cur topts; do
            [ -n "$code" ] || continue
            i=$((i+1)); t_codes[$i]="$code"
            printf "    %d. [%s] %s — %s дн., устройств: %s, цена: %s%s\n" \
                "$i" "$code" "$title" "$days" "$devices" "$(tariff_price_str "$price" "$cur")" \
                "${topts:+ · $topts}"
        done < <(tariff_list)
        [ "$i" -eq 0 ] && echo "    (тарифов нет — клиенты не смогут купить доступ)"
        echo ""
        echo "  Валюта XTR = Telegram Stars (работают сразу). RUB/USD/… — нужен"
        echo "  платёжный токен провайдера (меню бота, пункт 5). У одного тарифа"
        echo "  можно задать НЕСКОЛЬКО цен (напр. XTR и RUB) — клиент выберет способ."
        echo ""
        echo "  1. ➕ Добавить тариф"
        echo "  2. ✏️  Редактировать тариф (цены/дни/устройства/лимиты трафика/код)"
        echo "  3. ↕️  Переместить тариф (вверх/вниз или на позицию N)"
        echo "  4. ➖ Удалить тариф (по номеру)"
        echo "  5. 🧩 Создать типовые тарифы-примеры (Stars: 30/90/365 дней)"
        echo "  0. ↩  Назад"
        echo ""
        local ch; ask ch "  Выберите: "
        case "$ch" in
            1)
                echo ""
                local c t d dv p cu
                ask c  "  Код (латиница, напр. m1): "
                [[ "$c" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "  ❌ Код: латиница/цифры."; pause; continue; }
                ask t  "  Название (видит клиент, напр. «1 месяц»): "
                [ -n "$t" ] || { echo "  ❌ Название пустое."; pause; continue; }
                t=$(printf '%s' "$t" | tr -d '|')
                ask d  "  Дней доступа: "
                [[ "$d" =~ ^[0-9]+$ ]] && [ "$d" -gt 0 ] || { echo "  ❌ Дни — число > 0."; pause; continue; }
                ask dv "  Лимит устройств (0 — не менять при покупке): "
                [[ "$dv" =~ ^[0-9]+$ ]] || dv=0
                tariff_ask_opts || { pause; continue; }
                tariff_ask_prices "" "" "$([ -n "$(tariff_opt_of "$_TOPTS" free)" ] && echo 1 || echo 0)" \
                    || { pause; continue; }
                if printf '%s' "$_TCUR" | tr '/' '\n' | grep -qvx 'XTR' && [ -z "$(bot_get PAY_PROVIDER_TOKEN)" ]; then
                    echo "  ⚠️  Провайдер не настроен — не-XTR цены не будут продаваться, пока не зададите токен (меню бота → 5) или кошелёк ЮMoney для RUB (пункт 10)."
                fi
                tariff_add "$c" "$t" "$d" "$dv" "$_TPRICE" "$_TCUR" "$_TOPTS"
                echo "  ✅ Тариф [$c] сохранён ($(tariff_price_str "$_TPRICE" "$_TCUR"))."
                bot_restart
                pause ;;
            2)
                local sel; ask sel "  Номер тарифа для редактирования: "
                if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ -z "${t_codes[$sel]:-}" ]; then
                    echo "  ❌ Неверный номер."; pause; continue
                fi
                # 7-е поле (опции) читаем ОБЯЗАТЕЛЬНО: без него «RUB|free=1;…»
                # уезжало в валюту и редактор ругался на «валюту из 3 букв».
                local ocode="${t_codes[$sel]}" ec et ed edv ep ecu eopts
                IFS='|' read -r ec et ed edv ep ecu eopts <<<"$(tariff_get "$ocode")"
                echo ""
                echo "  Редактирование [$ocode]. Enter — оставить текущее значение."
                local nc nt nd ndv np ncu
                ask nc  "  Код [$ec]: ";        nc="${nc:-$ec}"
                [[ "$nc" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "  ❌ Код: латиница/цифры."; pause; continue; }
                if [ "$nc" != "$ec" ] && [ -n "$(tariff_get "$nc")" ]; then
                    echo "  ❌ Код [$nc] уже занят другим тарифом."; pause; continue
                fi
                ask nt  "  Название [$et]: ";   nt="${nt:-$et}"; nt=$(printf '%s' "$nt" | tr -d '|')
                [ -n "$nt" ] || { echo "  ❌ Название пустое."; pause; continue; }
                # У бесплатного тарифа (free=1) срока нет по определению — его
                # строка хранит 0 дней, и запрет «> 0» делал её нередактируемой.
                local zero_ok=0
                [ -n "$(tariff_opt_of "$eopts" free)" ] && zero_ok=1
                ask nd  "  Дней доступа [$ed]$([ "$zero_ok" = 1 ] && echo ' (0 — бесплатный, без срока)'): "; nd="${nd:-$ed}"
                [[ "$nd" =~ ^[0-9]+$ ]] && { [ "$nd" -gt 0 ] || [ "$zero_ok" = 1 ]; } \
                    || { echo "  ❌ Дни — число > 0."; pause; continue; }
                ask ndv "  Лимит устройств [$edv] (0 — не менять при покупке): "; ndv="${ndv:-$edv}"
                [[ "$ndv" =~ ^[0-9]+$ ]] || ndv=0
                tariff_ask_opts "$eopts" || { pause; continue; }
                [ -n "$(tariff_opt_of "$_TOPTS" free)" ] && zero_ok=1 || zero_ok=0
                echo "  Текущие цены: $(tariff_price_str "$ep" "$ecu")"
                tariff_ask_prices "$ecu" "$ep" "$zero_ok" || { pause; continue; }
                if printf '%s' "$_TCUR" | tr '/' '\n' | grep -qvx 'XTR' && [ -z "$(bot_get PAY_PROVIDER_TOKEN)" ]; then
                    echo "  ⚠️  Провайдер не настроен — не-XTR цены не будут продаваться, пока не зададите токен (меню бота → 5) или кошелёк ЮMoney для RUB (пункт 10)."
                fi
                # Опции передаём ВСЕГДА (в т.ч. пустые): иначе tariff_update
                # подставит старые, и снять лимит из меню было бы нельзя.
                tariff_update "$ocode" "$nc" "$nt" "$nd" "$ndv" "$_TPRICE" "$_TCUR" "$_TOPTS" force_opts
                echo "  ✅ Тариф [$nc] обновлён ($(tariff_price_str "$_TPRICE" "$_TCUR"))${_TOPTS:+ · $_TOPTS}."
                bot_restart
                pause ;;
            3)
                local sel; ask sel "  Номер тарифа для перемещения: "
                if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ -z "${t_codes[$sel]:-}" ]; then
                    echo "  ❌ Неверный номер."; pause; continue
                fi
                local dir; ask dir "  Куда: u — вверх, d — вниз, или НОМЕР позиции (напр. 1): "
                if [[ "$dir" =~ ^[0-9]+$ ]]; then
                    if tariff_move_to "${t_codes[$sel]}" "$dir"; then echo "  ✅ Тариф на позиции $dir."; bot_restart; else echo "  ❌ Не удалось переместить."; fi
                elif [[ "$dir" =~ ^(u|U|up|вверх)$ ]]; then
                    if tariff_move "${t_codes[$sel]}" up;   then echo "  ✅ Перемещён вверх."; bot_restart; else echo "  ⚠️  Тариф уже первый."; fi
                elif [[ "$dir" =~ ^(d|D|down|вниз)$ ]]; then
                    if tariff_move "${t_codes[$sel]}" down; then echo "  ✅ Перемещён вниз.";  bot_restart; else echo "  ⚠️  Тариф уже последний."; fi
                else
                    echo "  ❌ Введите u, d или номер позиции."
                fi
                pause ;;
            4)
                local sel; ask sel "  Номер тарифа для удаления: "
                if [[ "$sel" =~ ^[0-9]+$ ]] && [ -n "${t_codes[$sel]:-}" ]; then
                    tariff_del "${t_codes[$sel]}"
                    echo "  ✅ Удалён."
                    bot_restart
                else
                    echo "  ❌ Неверный номер."
                fi
                pause ;;
            5)
                tariff_add m1  "1 месяц"   30  0 100  XTR
                tariff_add m3  "3 месяца"  90  0 250  XTR
                tariff_add y1  "1 год"     365 0 800  XTR
                echo "  ✅ Созданы примеры (Stars): m1/m3/y1. Отредактируйте цены под себя."
                bot_restart
                pause ;;
            0) return ;;
            *) echo "  ❌ Неверный выбор!"; sleep 1 ;;
        esac
    done
}
