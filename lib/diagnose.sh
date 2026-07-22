#!/bin/bash
# ================================================
# Диагностика: полная проверка подписки и отладка конкретного пользователя.
# DNS → порты → Caddy → сертификат → пиры → содержимое подписки.
# ================================================

# Полная диагностика подписки: DNS→сервер, порты, Caddy, сертификат, пиры и
# содержимое подписки. Печатает отчёт с ✅/❌ и подсказками.
subscription_diagnose() {
    local host myip ips
    echo "  ══ Диагностика подписки ══════════════════════════════"
    if ! sub_enabled; then
        echo "  ⚪ Подписка не настроена (Настройки → Подписка → 1)."
        return 0
    fi
    autoset_node_ip 2>/dev/null || true
    host=$(node_host); myip=$(node_ip)
    local alllocal; alllocal=$(list_local_ips | tr '\n' ' ')
    echo "  Нода «$(node_name)» · домен $host"
    echo "  IP ноды (Caddy): $myip   ·   Все IP сервера: ${alllocal:-?}"
    echo ""

    # 1. DNS — принимаем ЛЮБОЙ локальный IP (у сервера их может быть несколько).
    ips=$(resolve_domain "$host")
    if [ -z "$ips" ]; then
        echo "  ❌ DNS: $host не резолвится. Нужна A-запись $host → один из: ${alllocal}"
    elif domain_points_here "$host"; then
        echo "  ✅ DNS: $host → $(printf '%s' "$ips" | tr '\n' ' ')(этот сервер)"
    else
        echo "  ❌ DNS: $host → $(printf '%s' "$ips" | tr '\n' ' ')(НЕ этот сервер)"
        echo "        Локальные IP сервера: ${alllocal}"
        echo "        Нужна ПРЯМАЯ A-запись на один из них, без CDN/прокси (Akamai/Cloudflare)."
    fi

    # 2. Caddy: проверяем, при необходимости включаем/запускаем, объясняем сбой.
    echo "  ── Caddy ──"
    caddy_start_report

    # 3. Порты — проверяем ИМЕННО на IP ноды (на другом IP может сидеть nginx — это ок).
    echo "  ── Порты (на IP ноды $myip) ──"
    local p
    for p in 80 443; do
        if port_listening "$p" "$myip"; then
            local h proc unit
            h=$(port_holder "$p" "$myip"); proc=${h%%|*}; unit=${h##*|}
            if printf '%s' "$proc" | grep -qi caddy; then
                echo "  ✅ Порт ${myip}:$p слушает Caddy"
            else
                echo "  ⚠️  Порт ${myip}:$p занят НЕ Caddy: ${proc:-неизвестно}${unit:+ (сервис $unit)}"
            fi
        else
            echo "  ⚠️  Порт ${myip}:$p никто не слушает$( [ "$p" = 80 ] && echo " (нужен для выпуска сертификата)" )"
        fi
    done

    # 4. Сертификат
    if cert_ready "$host"; then
        echo "  ✅ Сертификат валиден (до $(cert_expiry "$host")) — Caddy продлевает сам"
    else
        echo "  ❌ Сертификат не подтверждён — HTTPS-подписка не работает."
        echo "        Причины: DNS не на этот сервер; закрыт 80/tcp; Caddy лёг; DNS не распространился."
    fi

    # 5. Пиры
    echo "  ── Пиры кластера ──"
    local total=0 okp=0 ph pn
    while IFS='|' read -r pn ph; do
        [ -n "$ph" ] || continue
        [ "$ph" = "$host" ] && continue
        total=$((total + 1))
        if cluster_call "$ph" "/cluster/manifest" >/dev/null 2>&1; then
            echo "  ✅ $pn ($ph) — на связи"; okp=$((okp + 1))
        else
            echo "  ❌ $pn ($ph) — недоступен (DNS/сертификат/секрет/файрвол пира)"
        fi
    done < "$CLUSTER_CONF"
    [ "$total" -eq 0 ] && echo "  ℹ️  Пиров нет (одиночная нода)." \
        || echo "  Итого пиров: $okp из $total на связи"

    # 6. Содержимое подписки (на примере первого юзера)
    local u tok keys
    u=$(head -1 "$USERS_DB" 2>/dev/null | cut -d: -f1)
    if [ -n "$u" ]; then
        tok=$(sub_token_for "$u")
        echo "  ── Подписка юзера «$u» ──"
        if [ -f "$WEBROOT/sub/$tok" ]; then
            keys=$(base64 -d < "$WEBROOT/sub/$tok" 2>/dev/null | grep -c '^hysteria2')
            echo "  Ключей в подписке (со всех нод): ${keys:-0}"
            echo "  Ссылка: $(subscription_url "$u")"
            if [ "$total" -gt 0 ] && [ "${keys:-0}" -le 1 ]; then
                echo "  ⚠️  В подписке только свой ключ при наличии пиров — ключи пиров не подтянулись."
                echo "       Обычно из-за недоступных пиров выше. Почините их и нажмите «Синхронизировать»."
            fi
        else
            echo "  ⚠️  Файл подписки ещё не сгенерирован — нажмите «Синхронизировать»."
        fi
    fi
    echo "  ══════════════════════════════════════════════════════"
}

# Диагностика КОНКРЕТНОГО профиля по кластеру: где есть, онлайн по нодам, токены,
# срок, доступность пиров. Помогает понять, почему профиль где-то не работает.
user_debug() {
    local user="$1"
    echo "  🩺 Диагностика профиля «$user»"
    echo "  ──────────────────────────────────────────────────────"
    if db_user_exists "$user"; then
        echo "  ✅ На этой ноде ($(node_name)): активен"
    elif is_user_disabled "$user"; then
        echo "  ⏸  На этой ноде: ОТКЛЮЧЁН"
    else
        echo "  ❌ На этой ноде: отсутствует"
    fi
    if sub_enabled && is_cluster_user "$user"; then
        echo "  🌐 Тип: кластерный (должен быть на всех нодах)"
    else
        echo "  🔒 Тип: локальный (только эта нода)"
    fi
    local e; e=$(get_user_expiry "$user")
    if [ -n "$e" ]; then echo "  ⏰ Срок: $e ($(format_remaining "$e"))"; else echo "  ⏰ Срок: не задан"; fi

    if ! sub_enabled; then echo "  ⚪ Подписка не настроена."; return 0; fi

    echo "  🔗 Ссылка-подписка: $(subscription_url "$user")"
    local toks
    toks=$( { awk -F: -v u="$user" '$1==u{print $2}' "$SUBTOKENS_DB" 2>/dev/null
              [ -d "$PEERS_DIR" ] && awk -F: -v u="$user" '$1==u{print $2}' "$PEERS_DIR"/*.subtokens 2>/dev/null; } \
            | grep -v '^$' | sort -u )
    echo "  🎫 Токенов в кластере: $(printf '%s\n' "$toks" | grep -c .) (любой работает на любой ноде)"

    echo "  📡 По нодам (онлайн · трафик):"
    local bn bo btx brx
    while IFS=$'\t' read -r bn bo btx brx _ _; do
        echo "     • $bn: онлайн ${bo:-0} · ↑$(format_bytes "$btx")/↓$(format_bytes "$brx")"
    done < <(cluster_user_breakdown "$user")

    if cert_ready "$(node_host)"; then
        echo "  ✅ HTTPS этой ноды работает (сертификат валиден)"
    else
        echo "  ❌ HTTPS этой ноды НЕ работает — подписка по этой ссылке не отдаётся!"
        echo "     Запустите общую Диагностику (Подписка → 8)."
    fi
    local pn ph total=0 bad=0
    while IFS='|' read -r pn ph; do
        [ -n "$ph" ] || continue; [ "$ph" = "$(node_host)" ] && continue
        total=$((total+1))
        if ! cluster_call "$ph" "/cluster/manifest" 3 >/dev/null 2>&1; then
            echo "  ⚠️  Пир «$pn» ($ph) недоступен — его ключ может не попасть в подписку."
            bad=$((bad+1))
        fi
    done < "$CLUSTER_CONF"
    [ "$total" -gt 0 ] && [ "$bad" -eq 0 ] && echo "  ✅ Все пиры на связи."
    [ "$total" -eq 0 ] && echo "  ℹ️  Пиров нет (одиночная нода)."
}

