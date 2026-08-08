#!/bin/bash
# ================================================
# Меню подписки/кластера и выдача ссылок (см. lib/sub_links.sh)
# Часть UI (см. lib/ui.sh — снимок статистики и примитивы таблицы).
# ================================================

# ====================== ПОДПИСКА / КЛАСТЕР ======================
# Единая подписка: клиент добавляет одну ссылку https://<домен>/sub/<token>, а
# нода отдаёт ключи юзера со ВСЕХ серверов кластера (статику раздаёт Caddy).
subscription_menu() {
    while true; do
        clear
        local host caddy_st cert_st
        host=$(node_host)
        if ! command -v caddy &>/dev/null; then
            caddy_st="не установлен"
        elif systemctl is-active --quiet caddy 2>/dev/null; then
            caddy_st="💚 работает$(systemctl is-enabled --quiet caddy 2>/dev/null && echo ', автозапуск вкл')"
        else
            caddy_st="🔴 остановлен"
        fi

        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  🌐 Подписка / Кластер"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        if sub_enabled; then
            echo "  Состояние : 💚 включена"
            echo "  Нода      : $(node_name)  ($host)"
            # Живой статус сертификата — подтверждает, что домен реально привязан.
            if cert_ready "$host"; then
                cert_st="💚 валиден до $(cert_expiry "$host") (автопродление)"
            else
                cert_st="🔴 не подтверждён (HTTPS не работает — см. пункт 1)"
            fi
            echo "  Сертификат: $cert_st"
            local conn; conn=$(node_get CONN_HOST)
            if [ -n "$conn" ]; then
                echo "  В ссылке  : домен подключения $conn (вместо IP)"
            else
                echo "  В ссылке  : IP ноды $(node_ip) (домен не задан — пункт 9)"
            fi
        else
            echo "  Состояние : ⚪ не настроена"
        fi
        echo "  Caddy     : $caddy_st"
        echo "  Нод в кластере: $(grep -c '^' "$CLUSTER_CONF" 2>/dev/null | tr -dc '0-9' || echo 0)"
        local dlim nlim; dlim=$(get_device_limit); nlim=$(get_node_limit)
        echo "  Глоб. лимит на пул (кластер): $([ "$dlim" -gt 0 ] 2>/dev/null && echo "$dlim" || echo "∞ (выкл)")"
        echo "  Глоб. лимит на ноду         : $([ "$nlim" -gt 0 ] 2>/dev/null && echo "$nlim" || echo "∞ (выкл)")"
        echo ""
        echo "  1. 🌐 Настроить домен и включить подписку"
        echo "  2. 🔗 Создать кластер (получить join-токен)"
        echo "  3. 🔌 Подключиться к кластеру по токену"
        echo "  4. ➕ Добавить пир вручную (домен ноды)"
        echo "  5. 📋 Ноды кластера (просмотр и удаление)"
        echo "  6. 🔄 Получить синхронизацию (локально)"
        echo "  7. 🔢 Глобальные лимиты (пул + нода, синхронно)"
        echo "  8. 🩺 Диагностика подписки"
        echo "  9. 🛡  Домен подключения в ссылке (скрыть голый IP)"
        echo " 10. 🛰  Релей (реально спрятать IP ноды через фронт-VPS)"
        echo " 11. 🔢 Выбрать IP ноды (если у сервера несколько IP)"
        echo " 12. 🎨 Оформление подписки (название, метки серверов)"
        local _sm; _sm=$(node_get SYNC_MODE); [ -z "$_sm" ] && _sm=ask
        echo " 13. ⚙  Режим синхронизации после изменений (сейчас: $_sm)"
        echo "  0. ↩  Назад"
        echo ""
        local choice
        ask choice "  Выберите: "

        case "$choice" in
            1)
                echo ""
                local domain name dph rc
                ask domain "  Домен этой ноды (A-запись на её IP, напр. node1.example.com): "
                domain=$(printf '%s' "$domain" | tr -d '[:space:]' | tr 'A-Z' 'a-z')
                if ! valid_domain "$domain"; then
                    echo "  ❌ «$domain» не похоже на домен. Нужен FQDN, напр. node1.example.com"
                    echo "     Сертификат на произвольную строку выдать невозможно."
                    pause; continue
                fi
                # Проверяем, что домен реально указывает на этот сервер — иначе
                # Let's Encrypt не подтвердит владение и сертификата не будет.
                echo "  ⏳ Проверяю DNS для $domain ..."
                domain_points_here "$domain"; rc=$?
                local _locals; _locals=$(list_local_ips | tr '\n' ' ')
                if [ "$rc" -eq 0 ]; then
                    echo "  ✅ DNS: $domain → $(resolve_domain "$domain" | tr '\n' ' ')(этот сервер)"
                elif [ "$rc" -eq 2 ]; then
                    echo "  ❌ Домен $domain не резолвится."
                    echo "     Создайте A-запись $domain → один из IP: ${_locals}"
                    local c; ask c "  Всё равно продолжить (сертификат пока не выпустится)? (да/нет): "
                    is_yes "$c" || { echo "  Отменено."; pause; continue; }
                else
                    echo "  ⚠️  $domain резолвится НЕ на этот сервер."
                    echo "     Адрес(а) домена: $(resolve_domain "$domain" | tr '\n' ' ')"
                    echo "     Локальные IP сервера: ${_locals}"
                    echo "     Let's Encrypt не выдаст сертификат, пока A-запись не указывает на один из них."
                    local c; ask c "  Всё равно продолжить? (да/нет): "
                    is_yes "$c" || { echo "  Отменено."; pause; continue; }
                fi
                ask name "  Имя ноды (метка в клиенте, Enter — $(hostname -s 2>/dev/null || echo node)): "
                [ -z "$name" ] && name=$(hostname -s 2>/dev/null || echo node)
                echo "  ⏳ Открываю порты 80/443 в firewall (если активен)..."
                ensure_ports_open
                echo "  ⏳ Проверяю/устанавливаю Caddy..."
                if ! ensure_caddy; then
                    echo "  ❌ Не удалось установить Caddy. Установите вручную и повторите."
                    pause; continue
                fi
                node_configure "$domain" "$name"
                cluster_add_peer "$name" "$domain"
                echo "  ⏳ Настраиваю Caddy..."
                if ! setup_caddy "$domain"; then
                    echo "  ❌ Caddy не запустился с новым конфигом (откатил)."
                    echo "     Диагностика: journalctl -u caddy -e | tail -n 30"
                    pause; continue
                fi
                sub_refresh
                publish_peers_list
                # Подтверждаем РЕАЛЬНЫЙ выпуск доверенного сертификата, а не просто
                # «записали домен». Без этого подписка по HTTPS не работает.
                echo "  ⏳ Запрашиваю TLS-сертификат (Let's Encrypt), до ~45 сек..."
                if wait_cert "$domain" 15; then
                    echo "  ✅ Сертификат выдан и доверенный — подписка активна."
                    echo "     Домен      : $domain"
                    echo "     Действителен до: $(cert_expiry "$domain")"
                    echo "     🔄 Caddy продлевает сертификат автоматически (бессрочно),"
                    echo "        пока сервис caddy включён и открыт порт 80/tcp."
                else
                    echo "  ⚠️  Сертификат пока НЕ подтверждён — HTTPS-подписка ещё не работает."
                    echo "     Частые причины: A-запись не на этот сервер; закрыт 80/tcp;"
                    echo "     DNS не распространился. Диагностика:"
                    echo "        journalctl -u caddy -e | tail -n 40"
                    echo "     Когда поправите — Caddy выпустит сертификат сам, либо повторите пункт 1."
                fi
                pause
                ;;
            2)
                if ! sub_enabled; then echo "  ❌ Сначала настройте домен (пункт 1)"; sleep 2; continue; fi
                echo ""
                echo "  🔗 JOIN-ТОКЕН (вставьте его на других нодах, пункт 3):"
                echo ""
                echo "  $(cluster_init)"
                echo ""
                echo "  ℹ️  После подключения новой ноды добавьте её домен здесь (пункт 4)."
                pause
                ;;
            3)
                if ! sub_enabled; then echo "  ❌ Сначала настройте домен (пункт 1)"; sleep 2; continue; fi
                echo ""
                local token
                ask token "  Вставьте join-токен: "
                [ -z "$token" ] && { echo "  Отменено."; sleep 1; continue; }
                cluster_join "$token"
                pause
                ;;
            4)
                echo ""
                local phost
                ask phost "  Домен пира (напр. node2.example.com): "
                if [ -n "$phost" ]; then
                    cluster_add_peer "$phost" "$phost"
                    publish_peers_list
                    cluster_sync_now
                    echo "  ✅ Пир $phost добавлен."
                fi
                pause
                ;;
            5)
                while true; do
                    clear
                    echo "  📋 Ноды кластера"
                    echo "  Эта нода: «$(node_name)»  ($(node_host)) · v$(manager_local_version)"
                    echo "  ────────────────────────────────────────────────────────────────"
                    printf "    %-2s %-16s %-24s %-13s %s\n" "#" "имя" "домен" "статус" "версия"
                    local -a node_hosts=() node_names=()
                    local i=0 st self lver ver vmark
                    self=$(node_host); lver=$(manager_local_version)
                    if [ -s "$CLUSTER_CONF" ]; then
                        while IFS='|' read -r pn ph; do
                            [ -n "$ph" ] || continue
                            i=$((i+1)); node_names[$i]="$pn"; node_hosts[$i]="$ph"
                            if [ "$ph" = "$self" ]; then
                                st="(эта нода)"; ver="$lver"
                            elif cluster_call "$ph" "/cluster/manifest" >/dev/null 2>&1; then
                                st="💚 на связи"
                                # Версию берём из кэша синка, а нет — тянем вживую.
                                ver=$(peer_version "$pn")
                                [ -z "$ver" ] && ver=$(cluster_call "$ph" "/cluster/version" 4 2>/dev/null | cut -d'|' -f1)
                                [ -z "$ver" ] && ver="?"
                            else
                                st="🔴 недоступна"; ver=$(peer_version "$pn"); [ -z "$ver" ] && ver="?"
                            fi
                            # Пометка: старее этой ноды → пора обновить; «?» → старый код без обмена версиями.
                            vmark=""
                            if [ "$ver" = "?" ]; then vmark=" ⚠ старая"
                            elif [ "$ph" != "$self" ] && _ver_gt "$lver" "$ver"; then vmark=" ⬆ обновить"
                            fi
                            printf "    %-2d %-16s %-24s %-13s v%s%s\n" "$i" "$pn" "$ph" "$st" "$ver" "$vmark"
                        done < "$CLUSTER_CONF"
                    fi
                    [ "$i" -eq 0 ] && echo "    (пусто — кластер не настроен)"
                    echo ""
                    echo "    «?» — нода на старой версии без обмена версиями (обновите её)."
                    echo "    Номер — удалить ноду из реестра  |  0 — назад"
                    local sel
                    ask sel "  Выберите: "
                    [ "$sel" = "0" ] || [ -z "$sel" ] && break
                    if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "$i" ]; then
                        local dh="${node_hosts[$sel]}" dn="${node_names[$sel]}"
                        if [ "$dh" = "$self" ]; then
                            echo "  ❌ Нельзя удалить саму эту ноду здесь."; sleep 2; continue
                        fi
                        local c; ask c "  Удалить «$dn» ($dh) из реестра? (да/нет): "
                        if is_yes "$c"; then
                            cluster_remove_peer "$dh"
                            echo "  ✅ Удалено. ⚠️ Если пир ещё «живой» и есть в реестрах других нод —"
                            echo "     удалите его и там, иначе вернётся через gossip."
                            sleep 3
                        fi
                    else
                        echo "  ❌ Неверный номер."; sleep 1
                    fi
                done
                ;;
            6)
                cluster_sync_now
                pause
                ;;
            7)
                echo ""
                echo "  Глобальные лимиты подключений на ОДНУ подписку (общие для кластера,"
                echo "  синхронизируются автоматически). Персональное «кол-во устройств»"
                echo "  у юзера ПРИОРИТЕТНЕЕ этих значений."
                echo "    • Пул  — максимум одновременных подключений СУММАРНО по всем нодам."
                echo "    • Нода — максимум на ОДНУ ноду (страхует от багов синхронизации)."
                echo "  Пример: нода = 1, пул = 2. Лишние сессии отключаются (~1 мин)."
                echo ""
                echo "  Сейчас: пул $(get_device_limit) · нода $(get_node_limit)  (0 = без лимита)"
                local nlim nnode changed7=0
                ask nlim "  Лимит на пул (число, 0 — выкл, Enter — не менять): "
                if [ -n "$nlim" ]; then
                    if [[ "$nlim" =~ ^[0-9]+$ ]]; then set_device_limit "$nlim"; changed7=1
                    else echo "  ❌ Пул: нужно число — пропущено."; fi
                fi
                ask nnode "  Лимит на ноду (число, 0 — выкл, Enter — не менять): "
                if [ -n "$nnode" ]; then
                    if [[ "$nnode" =~ ^[0-9]+$ ]]; then set_node_limit "$nnode"; changed7=1
                    else echo "  ❌ Нода: нужно число — пропущено."; fi
                fi
                if [ "$changed7" = 1 ]; then
                    echo "  ✅ Лимиты: пул $(get_device_limit) · нода $(get_node_limit)."
                    publish_cluster_settings
                    [ -n "$(cluster_peers 2>/dev/null)" ] && cluster_sync_now
                    echo "     Применяются в течение ~1 мин (cron --online-sync) на каждой ноде."
                fi
                pause
                ;;
            8)
                clear
                subscription_diagnose
                # Если Caddy не поднялся из-за занятого порта — предлагаем освободить.
                if [ -n "$DIAG_CONFLICT_UNIT" ]; then
                    echo ""
                    echo "  Порт $DIAG_CONFLICT_PORT занимает сервис «$DIAG_CONFLICT_UNIT»."
                    local c
                    ask c "  Остановить его и запустить Caddy? (да/нет): "
                    if is_yes "$c"; then
                        systemctl stop "$DIAG_CONFLICT_UNIT" 2>/dev/null
                        ask c "  Отключить «$DIAG_CONFLICT_UNIT» из автозапуска (чтобы не вернулся после ребута)? (да/нет): "
                        is_yes "$c" && systemctl disable "$DIAG_CONFLICT_UNIT" 2>/dev/null
                        ensure_ports_open
                        setup_caddy >/dev/null 2>&1
                        sleep 2
                        if systemctl is-active --quiet caddy 2>/dev/null; then
                            echo "  ✅ Caddy запущен. Жду сертификат..."
                            if wait_cert "$(node_host)" 15; then
                                echo "  ✅ Сертификат выдан (до $(cert_expiry "$(node_host)")). Подписка работает."
                            else
                                echo "  ⚠️  Caddy поднялся, но сертификат пока не подтверждён — проверьте DNS/порт 80."
                            fi
                        else
                            echo "  ❌ Caddy всё ещё не запускается — journalctl -u caddy -e | tail -n 30"
                        fi
                    fi
                fi
                pause
                ;;
            9)
                echo ""
                local cur_conn; cur_conn=$(node_get CONN_HOST)
                [ -z "$cur_conn" ] && cur_conn="нет, используется IP $(get_ip)"
                echo "  Домен подключения подставляется в ссылку вместо голого IP"
                echo "  (host у hysteria2://...@host:port). Текущий: $cur_conn"
                echo ""
                echo "  ⚠️ ВАЖНО: домен должен быть DNS-only (A-запись прямо на IP ноды),"
                echo "     БЕЗ оранжевого облака Cloudflare — Hysteria работает по UDP,"
                echo "     а CF-прокси UDP не пропускает, и подключение сломается."
                echo ""
                local nd
                ask nd "  Домен подключения (Enter — оставить, '-' — убрать и вернуть IP): "
                if [ "$nd" = "-" ]; then
                    node_set CONN_HOST ""
                    sed -i '/^CONN_HOST=$/d' "$NODE_CONF" 2>/dev/null
                    echo "  ✅ Убрано — в ссылке снова IP $(get_ip)."
                    sub_refresh
                elif [ -z "$nd" ]; then
                    echo "  Без изменений."
                elif ! valid_domain "$nd"; then
                    echo "  ❌ «$nd» не похоже на домен."
                else
                    local ph
                    ph=$(resolve_domain "$nd")
                    if domain_points_here "$nd"; then
                        echo "  ✅ DNS: $nd → $(printf '%s' "$ph" | tr '\n' ' ')(этот сервер, DNS-only — то, что нужно)."
                    elif [ -z "$ph" ]; then
                        echo "  ⚠️ $nd пока не резолвится. Создайте A-запись $nd → один из: $(list_local_ips | tr '\n' ' ')(DNS-only)."
                    else
                        echo "  ⚠️ $nd резолвится на $(printf '%s' "$ph" | tr '\n' ' ')— НЕ на этот сервер."
                        echo "     Локальные IP: $(list_local_ips | tr '\n' ' '). Если это IP Cloudflare (оранжевое облако) — клиент не подключится."
                    fi
                    node_set CONN_HOST "$nd"
                    sub_refresh
                    echo "  ✅ В ссылках теперь домен $nd. Раздайте пользователям новую подписку/ссылку."
                fi
                pause
                ;;
            10)
                clear
                echo "  🛰  РЕЛЕЙ — реально прячет IP ноды"
                echo "  ──────────────────────────────────────────────────────"
                echo "  Релей — отдельный дешёвый VPS. Клиенты видят IP РЕЛЕЯ, он"
                echo "  форвардит трафик на эту (скрытую) ноду $(node_ip)."
                echo "  В ссылке будет адрес релея; dig покажет релей, не ноду."
                echo ""
                echo "  ⚠️ Минус: нода будет видеть всех клиентов с одного IP (релея) —"
                echo "     детектор утечки по IP перестанет различать устройства."
                echo ""
                local rh
                ask rh "  Адрес релея (IP или домен, который видит клиент; '-' убрать): "
                if [ "$rh" = "-" ]; then
                    node_set RELAY_HOST ""
                    sed -i '/^RELAY_HOST=$/d' "$NODE_CONF" 2>/dev/null
                    node_set CONN_HOST ""
                    sed -i '/^CONN_HOST=$/d' "$NODE_CONF" 2>/dev/null
                    sub_refresh
                    echo "  ✅ Релей убран — в ссылке снова прямой адрес ноды."
                    pause; continue
                fi
                [ -z "$rh" ] && { echo "  Отменено."; pause; continue; }
                node_set RELAY_HOST "$rh"
                node_set CONN_HOST "$rh"     # ссылки указывают на релей
                local rscript
                rscript=$(generate_relay_script)
                sub_refresh
                echo ""
                echo "  ✅ Ссылки теперь указывают на релей «$rh»."
                echo ""
                echo "  📋 ДАЛЬШЕ — НА РЕЛЕЙ-СЕРВЕРЕ (от root) выполните скрипт:"
                echo "  Скрипт сохранён здесь: $rscript"
                echo "  Скопируйте его на релей и запустите, например:"
                echo "     scp $rscript root@$rh:/root/relay-setup.sh"
                echo "     ssh root@$rh 'bash /root/relay-setup.sh'"
                echo ""
                echo "  Затем направьте DNS:"
                echo "    • домен подключения  → IP релея (A-запись, DNS-only)"
                echo "    • домен подписки ($(node_host)) → IP релея (если хотите спрятать IP и для подписки)"
                echo ""
                echo "  Показать содержимое скрипта сейчас? (да/нет): "
                local sc; ask sc ""
                if is_yes "$sc"; then echo ""; sed 's/^/    /' "$rscript"; fi
                pause
                ;;
            11)
                clear
                echo "  🔢 Выбор IP ноды (Caddy сядет на него)"
                echo "  ──────────────────────────────────────────────────────"
                echo "  Если у сервера несколько IP и на одном из них заняты порты"
                echo "  (nginx и т.п.), укажите свободный — Caddy привяжется к нему."
                echo ""
                local -a ips_arr=(); local k=0 cur
                cur=$(node_ip)
                while IFS= read -r oneip; do
                    [ -n "$oneip" ] || continue
                    k=$((k+1)); ips_arr[$k]="$oneip"
                    local mark=""; [ "$oneip" = "$cur" ] && mark="  ← сейчас"
                    local ph; ph=$(port_holder 443 "$oneip"); ph=${ph%%|*}
                    printf "    %d. %-18s %s%s\n" "$k" "$oneip" "${ph:+занят 443: $ph}" "$mark"
                done < <(list_local_ips)
                [ "$k" -eq 0 ] && { echo "    Не удалось определить локальные IP."; pause; continue; }
                echo "    0. Авто (отвязать от конкретного IP)"
                echo ""
                local pick; ask pick "  Выберите IP: "
                if [ "$pick" = "0" ]; then
                    node_set NODE_IP ""
                    sed -i '/^NODE_IP=$/d' "$NODE_CONF" 2>/dev/null
                    echo "  ✅ Авто-режим."
                elif [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "$k" ]; then
                    node_set NODE_IP "${ips_arr[$pick]}"
                    echo "  ✅ IP ноды: ${ips_arr[$pick]}"
                else
                    echo "  ❌ Неверный выбор."; pause; continue
                fi
                echo "  ⏳ Пересобираю Caddy на выбранном IP..."
                ensure_ports_open
                if setup_caddy >/dev/null 2>&1; then
                    echo "  ✅ Caddy перезапущен. Жду сертификат..."
                    if wait_cert "$(node_host)" 15; then
                        echo "  ✅ Сертификат выдан (до $(cert_expiry "$(node_host)")). Подписка работает."
                    else
                        echo "  ⚠️  Сертификат пока не подтверждён — проверьте DNS на этот IP и порт 80."
                    fi
                else
                    echo "  ❌ Caddy не поднялся — Диагностика (пункт 8) покажет причину."
                fi
                sub_refresh
                pause
                ;;
            12)
                while true; do
                    clear
                    echo "  🎨 Оформление подписки (что видит пользователь)"
                    echo "  ──────────────────────────────────────────────────────"
                    echo "  Название профиля : $(sub_title)   (плейсхолдеры: {label} {user} {name} {online})"
                    echo "  Метка этой ноды  : $(node_label)"
                    echo "  Шаблон подписи   : $(sub_tag_tmpl)   (плейсхолдеры: {label} {user} {name} {online} {protocol})"
                    echo "  Интервал обновл. : каждые $(sub_update_hours) ч"
                    local _sup _annu _hdrs
                    _sup=$(sub_support_url); _annu=$(sub_announce_url); _hdrs=$(sub_headers_extra)
                    echo "  Поддержка        : ${_sup:-—}"
                    echo "  Страница подписки: $(sub_page_url)"
                    echo "  Клик по анонсу   : ${_annu:-—}"
                    echo "  Доп. заголовки   : ${_hdrs//|/ · }"
                    echo ""
                    echo "  Пример названия профиля      : $(render_title 'username')"
                    echo "  Пример подписи ключа этой ноды: $(render_tag 'username')"
                    echo ""
                    echo "  1. Название профиля"
                    echo "  2. Метка ноды (можно с эмодзи/флагом, напр. «🇩🇪 Германия-1»)"
                    echo "  3. Шаблон подписи ключа"
                    echo "  4. Интервал обновления (часы)"
                    echo "  5. Тексты анонса (демо / бесплатный / платный)"
                    echo "  6. Ссылки в клиенте (поддержка, страница, клик по анонсу)"
                    echo "  7. Доп. заголовки (любой параметр клиента)"
                    echo "  8. 🔄 Получить синхронизацию (локально)"
                    echo "  0. Назад"
                    echo "  ℹ️ Всё, кроме метки ноды, — ОБЩЕЕ для кластера (синхронизируется)."
                    echo "     Расход и срок клиент показывает сам: их отдаём всегда (subscription-userinfo)."
                    local ed glob_changed=0; ask ed "  Выберите: "
                    # Перед правкой ОБЩЕЙ настройки стягиваем свежие настройки пиров,
                    # чтобы ts правки (max+1) гарантированно превысил максимум по
                    # кластеру и синхронизация не откатила её (LWW при разных часах).
                    case "$ed" in 1|3|4|5|6|7) cluster_pull_settings ;; esac
                    case "$ed" in
                        1) echo "    Плейсхолдеры: {user} имя юзера · {label} метка ноды · {name} имя ноды · {online} онлайн сервера"
                           echo "    Примеры: Доступ   |   Доступ · {user}   |   {user} — {label}"
                           echo "    ℹ️ С {user} название профиля у каждого юзера своё."
                           local v; ask v "  Название профиля: "; [ -n "$v" ] && { setting_set SUB_TITLE "$v"; glob_changed=1; } ;;
                        2) local v; ask v "  Метка ноды (Enter — сбросить к «$(node_name)»): "; node_set NODE_LABEL "$v"; [ -z "$v" ] && sed -i '/^NODE_LABEL=$/d' "$NODE_CONF" 2>/dev/null ;;
                        3) echo "    Плейсхолдеры: {label} метка ноды · {user} имя · {name} имя ноды · {online} онлайн сервера · {protocol} протокол ключа"
                           echo "    Примеры: {label}   |   {label} · {user}   |   {label} [💚 {online}]   |   {label} · {protocol}"
                           echo "    ℹ️ {online} — сколько юзеров сейчас онлайн на КОНКРЕТНОМ сервере (индикатор"
                           echo "       загрузки: клиент видит, к какому серверу лучше подключиться). У ключа каждой"
                           echo "       ноды — онлайн своей ноды. Обновляется ~1 мин; видно после обновления подписки."
                           echo "    ℹ️ {protocol} — метка протокола этого ключа: HY2 / VLESS / SS22 / TUIC."
                           local v; ask v "  Шаблон (Enter — по умолчанию {label}): "; setting_set SUB_TAG_TMPL "$v"; glob_changed=1 ;;
                        4) local v; ask v "  Интервал обновления, часов (напр. 12): "; if [[ "$v" =~ ^[0-9]+$ ]]; then setting_set SUB_UPDATE_HOURS "$v"; glob_changed=1; else echo "  ❌ Нужно число"; fi ;;
                        5) echo "    Анонс — строка поверх ключей в клиенте (Happ, v2RayTun). Свой текст на каждый"
                           echo "    план: демо, бесплатный, платный. До ~200 символов, дальше клиент обрежет."
                           echo "    Плейсхолдеры: {plan} тип плана · {expire} дата конца · {left} сколько осталось"
                           echo "                  {used} израсходовано · {total} лимит трафика · {devices} устройств"
                           echo "                  {rate} тариф скорости · плюс {user} {label} {name} {online}"
                           echo "    Enter — оставить как есть · «-» — не показывать анонс этому плану"
                           echo ""
                           echo "    Демо      : $(sub_ann_demo)"
                           echo "    Бесплатный: $(sub_ann_free)"
                           echo "    Платный   : $(sub_ann_paid)"
                           echo ""
                           local w v
                           ask w "  Какой план менять (1 демо / 2 бесплатный / 3 платный): "
                           case "$w" in
                               1) ask v "  Текст для демо: ";       [ -n "$v" ] && { setting_set SUB_ANN_DEMO "$v"; glob_changed=1; } ;;
                               2) ask v "  Текст для бесплатного: "; [ -n "$v" ] && { setting_set SUB_ANN_FREE "$v"; glob_changed=1; } ;;
                               3) ask v "  Текст для платного: ";    [ -n "$v" ] && { setting_set SUB_ANN_PAID "$v"; glob_changed=1; } ;;
                               *) echo "  ❌ Неверный выбор"; sleep 1; continue ;;
                           esac ;;
                        6) echo "    Кнопки и ссылки, которые клиент рисует рядом с подпиской."
                           echo "    Enter — оставить как есть · «-» — убрать."
                           local v
                           ask v "  Поддержка (ссылка на бота/чат): "
                           case "$v" in '') ;; '-') setting_set SUB_SUPPORT_URL ''; glob_changed=1 ;; *) setting_set SUB_SUPPORT_URL "$v"; glob_changed=1 ;; esac
                           ask v "  Страница подписки (Enter — корень домена ноды): "
                           case "$v" in '') ;; '-') setting_set SUB_PAGE_URL ''; glob_changed=1 ;; *) setting_set SUB_PAGE_URL "$v"; glob_changed=1 ;; esac
                           ask v "  Куда ведёт клик по анонсу: "
                           case "$v" in '') ;; '-') setting_set SUB_ANN_URL ''; glob_changed=1 ;; *) setting_set SUB_ANN_URL "$v"; glob_changed=1 ;; esac ;;
                        7) echo "    Любые прочие параметры клиента — списком «имя: значение», через «|»."
                           echo "    Список того, что понимают клиенты — docs/guide/SUB-HEADERS.md. Примеры:"
                           echo "      update-always: true|subscriptions-sort-type: ping|subscription-pin: true"
                           echo "      hide-vpn-icon: true|notification-subs-expire: 1"
                           echo "    Сейчас: $(sub_headers_extra)"
                           echo "    Enter — оставить как есть · «-» — очистить список."
                           local v; ask v "  Список: "
                           case "$v" in '') ;; '-') setting_set SUB_HEADERS ''; glob_changed=1 ;; *) setting_set SUB_HEADERS "$v"; glob_changed=1 ;; esac ;;
                        8) cluster_sync_now; pause; continue ;;
                        0) break ;;
                        *) echo "  ❌ Неверный выбор"; sleep 1; continue ;;
                    esac
                    # Применяем: метки → пересборка подписок; заголовки → перенастройка Caddy.
                    sub_refresh
                    setup_caddy >/dev/null 2>&1
                    # Общие настройки — публикуем и разносим по кластеру через ЕДИНУЮ синхронизацию.
                    if [ "$glob_changed" = 1 ]; then
                        publish_cluster_settings
                        echo "  ✅ Применено."
                        if [ -n "$(cluster_peers 2>/dev/null)" ]; then cluster_sync_now; pause; else sleep 1; fi
                    else
                        echo "  ✅ Применено."; sleep 1
                    fi
                done
                ;;
            13)
                clear
                echo "  ⚙  Режим синхронизации после любых изменений"
                echo "  ──────────────────────────────────────────────────────"
                echo "  Текущий: $(node_get SYNC_MODE || echo ask)"
                echo ""
                echo "  1. ask  — спрашивать каждый раз (сразу или по расписанию)"
                echo "  2. auto — синхронизировать сразу, без вопроса"
                echo "  3. cron — только по расписанию (каждые 5 мин), не спрашивать"
                local sm; ask sm "  Выберите (1/2/3): "
                case "$sm" in
                    1) node_set SYNC_MODE ask;  echo "  ✅ Спрашивать каждый раз." ;;
                    2) node_set SYNC_MODE auto; echo "  ✅ Синхронизировать сразу." ;;
                    3) node_set SYNC_MODE cron; echo "  ✅ Только по расписанию." ;;
                    *) echo "  Без изменений." ;;
                esac
                pause
                ;;
            0) return ;;
            *)
                echo "  ❌ Неверный выбор!"
                sleep 1
                ;;
        esac
    done
}

# ====================== ПОЛУЧЕНИЕ ССЫЛКИ ======================

get_link_menu() {
    local page=1 need_clear=1
    while true; do
        refresh_online
        load_user_list

        if [ "$USER_LIST_TOTAL" -eq 0 ]; then
            clear
            echo "  Нет пользователей."
            echo ""
            pause "  Enter для возврата..."
            return
        fi

        [ "$page" -gt "$USER_LIST_PAGES" ] && page=$USER_LIST_PAGES
        [ "$page" -lt 1 ] && page=1

        local frame
        frame=$(
            render_user_table "$page" "Выберите пользователя для получения ссылки"
            echo ""
            if [ "$USER_LIST_PAGES" -gt 1 ]; then
                echo "  [1-${USER_LIST_TOTAL}] ссылка  |  ←/→ страницы  |  [0] назад"
            else
                echo "  [1-${USER_LIST_TOTAL}] ссылка  |  [0] назад"
            fi
        )
        [ "$need_clear" = 1 ] && { clear; need_clear=0; }
        render_frame "$frame"

        printf '  Номер (← / → — страницы): '
        local key
        key=$(read_key "")

        case "$key" in
            TIMEOUT|ENTER|ESC) ;;
            LEFT|UP)    ((page--)); [ "$page" -lt 1 ] && page=1 ;;
            RIGHT|DOWN) ((page++)); [ "$page" -gt "$USER_LIST_PAGES" ] && page=$USER_LIST_PAGES ;;
            0) return ;;
            [1-9])
                printf '%s' "$key"
                local rest input
                read -r rest
                input="${key}${rest}"
                if [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 1 ] && [ "$input" -le "$USER_LIST_TOTAL" ] 2>/dev/null; then
                    local sel_user="${USER_LIST_ARRAY[$((input - 1))]}"
                    local pass
                    if is_user_disabled "$sel_user"; then
                        pass=$(get_disabled_password "$sel_user")
                        echo ""
                        echo "  ⚠️  $sel_user отключён! Ссылка не будет работать."
                    else
                        pass=$(get_user_password "$sel_user")
                    fi
                    if [ -n "$pass" ]; then
                        # Единый генератор ссылки (учитывает домен подключения/релей).
                        local link
                        link=$(build_user_link "$sel_user" "$pass" "$(link_host)" "$CACHED_PORT" "$CACHED_OBFS" "$CACHED_SNI")
                        echo ""
                        echo "  🔗 ССЫЛКА для $sel_user:"
                        echo "  $link"
                        echo ""
                        echo "  💡 Hiddify, Nekobox, Streisand и т.д."
                    else
                        echo "  ❌ Ошибка получения пароля"
                    fi
                    pause
                fi
                need_clear=1
                ;;
        esac
    done
}
