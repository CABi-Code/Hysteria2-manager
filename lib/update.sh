#!/bin/bash
# ================================================
# Проверка и установка обновлений менеджера с GitHub.
# Источник версии — файл VERSION в репозитории (MANAGER_REPO_RAW из config.sh).
# Проверка кэшируется (MANAGER_VERSION_CACHE), чтобы не дёргать сеть на каждый
# перерисов меню. Само обновление запускает install.sh (режим «только менеджер»),
# который не трогает Hysteria/пользователей/настройки.
# ================================================

UPDATE_CHECK_TTL="${UPDATE_CHECK_TTL:-3600}"   # как часто реально ходить в сеть, сек

manager_local_version() { printf '%s' "${MANAGER_VERSION:-unknown}"; }

# Похоже ли на версию. Нужен всем, кто СРАВНИВАЕТ версии, потому что `sort -V`
# на мусоре не ошибается, а уверенно врёт: «unknown» она ставит ВЫШЕ любых цифр.
# Пустая или нечитаемая VERSION даёт ровно «unknown» (hy2-manager.sh), и такая
# строка, разосланная соседям как просьба обновиться, гнала бы их в бесконечные
# попытки догнать несуществующее. Поэтому не сравниваем то, что не версия.
_ver_ok() { [[ "$1" =~ ^[0-9]+(\.[0-9]+)*$ ]]; }

# Сравнение версий вида «4.2», «4.10», «4.2.1». Возврат 0, если $1 СТРОГО больше $2.
_ver_gt() {   # a b
    [ "$1" = "$2" ] && return 1
    local hi
    hi=$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)
    [ "$hi" = "$1" ]
}

# Сетевой запрос версии из репо (блокирующий). Обновляет кэш. Внутренний.
_manager_fetch_remote_version() {
    local ver; ver=$(curl -fsSL --max-time 12 "$MANAGER_REPO_RAW/VERSION" 2>/dev/null | head -1 | tr -d '[:space:]')
    [ -n "$ver" ] || return 1
    printf '%s|%s\n' "$ver" "$(date +%s)" > "$MANAGER_VERSION_CACHE" 2>/dev/null
    printf '%s' "$ver"
}

# Версия в репозитории.
#   force — синхронно сходить в сеть (для явной проверки «обновить менеджер»).
#   без аргумента — ТОЛЬКО из кэша (не блокирует перерисовку меню). Если кэш
#   протух, в фоне запускаем обновление кэша, а сейчас отдаём что есть (может
#   быть пусто при самой первой проверке). Так меню никогда не висит на сети.
manager_remote_version() {   # [force]
    local now cached cts
    now=$(date +%s)
    if [ "$1" = "force" ]; then
        _manager_fetch_remote_version && return 0
        # Сеть недоступна — отдаём кэш, если есть.
        [ -f "$MANAGER_VERSION_CACHE" ] && { IFS='|' read -r cached _ < "$MANAGER_VERSION_CACHE"; printf '%s' "$cached"; }
        return 0
    fi
    [ -f "$MANAGER_VERSION_CACHE" ] && IFS='|' read -r cached cts < "$MANAGER_VERSION_CACHE" 2>/dev/null
    # Кэш протух (или пуст) — освежаем в фоне, не блокируя вызывающего. Лок не даёт
    # плодить фоновые проверки чаще раза в минуту.
    if ! { [[ "$cts" =~ ^[0-9]+$ ]] && [ $((now - cts)) -lt "$UPDATE_CHECK_TTL" ]; }; then
        local lock="${MANAGER_VERSION_CACHE}.lock"
        if ! [ -f "$lock" ] || [ $((now - $(stat -c %Y "$lock" 2>/dev/null || echo 0))) -ge 60 ]; then
            touch "$lock" 2>/dev/null
            ( _manager_fetch_remote_version >/dev/null 2>&1; rm -f "$lock" 2>/dev/null ) &
        fi
    fi
    printf '%s' "$cached"
}

# Есть ли обновление. Печатает удалённую версию и возвращает 0, если она новее.
manager_update_available() {   # [force]
    local loc rem; loc=$(manager_local_version); rem=$(manager_remote_version "$1")
    [ -n "$rem" ] || return 1
    if _ver_gt "$rem" "$loc"; then printf '%s' "$rem"; return 0; fi
    return 1
}

# Короткая строка-баннер для меню (пусто, если обновлений нет / нет данных).
manager_update_banner() {   # [force]
    local rem; rem=$(manager_update_available "$1") || return 1
    printf '⬆ доступно обновление менеджера: v%s (у вас v%s)' "$rem" "$(manager_local_version)"
}

# Неинтерактивное обновление менеджера — для кластерного крючка «обнови соседа»
# и для запуска из крона. Ставит ТОЛЬКО файлы менеджера: install.sh в режиме
# manager_only не трогает Hysteria, конфиг, сертификаты, пользователей и
# статистику, а полную переустановку без человека за клавиатурой он запустить
# не даст в принципе (см. HY2M_MANAGER_ONLY в install.sh).
#
# Работа уходит в отвязанный процесс: установщик перезапускает hy2-webapi и
# hy2-bot, а вызов сюда, как правило, ПРИШЁЛ через один из них — иначе
# обновление убило бы само себя на середине, оставив половину модулей старыми.
# Возврат: 0 — запущено (результат смотреть в логе), 1 — установщик не скачался.
manager_update_silent() {
    local up_tmp log
    log="${LOG_DIR:-/var/log/hy2-manager}/update.log"
    mkdir -p "$(dirname "$log")" 2>/dev/null
    up_tmp=$(mktemp /tmp/hy2m-update.XXXXXX) || return 1
    if ! curl -fsSL --max-time 30 "$MANAGER_REPO_RAW/install.sh" -o "$up_tmp" || [ ! -s "$up_tmp" ]; then
        rm -f "$up_tmp"
        echo "$(date '+%F %T') обновление: не удалось скачать install.sh" >> "$log"
        return 1
    fi
    setsid nohup bash -c '
        {
            echo "=== $(date "+%F %T") обновление менеджера (только менеджер) ==="
            HY2M_MANAGER_ONLY=1 bash "'"$up_tmp"'"
            rc=$?
            rm -f "'"$up_tmp"'"
            # Перезапускаем только то, что реально крутится: демоны держат
            # старый код в памяти, пока их не тронешь.
            for svc in hy2-webapi hy2-bot; do
                systemctl is-active --quiet "$svc" && systemctl restart "$svc"
            done
            echo "=== $(date "+%F %T") готово, код $rc, версия $(cat /opt/hy2-manager/VERSION 2>/dev/null) ==="
        } >>"'"$log"'" 2>&1
    ' >/dev/null 2>&1 &
    return 0
}

# Запуск установщика с GitHub (режим «только менеджер»). Заменяет процесс.
manager_do_update() {
    local up_tmp; up_tmp=$(mktemp)
    if curl -fsSL --max-time 30 "$MANAGER_REPO_RAW/install.sh" -o "$up_tmp"; then
        echo "  ⏳ Запускаю установщик (выберите пункт 1 — обновить только менеджер)..."
        # stderr менеджера уходит в лог-файл — вернём его на терминал, чтобы
        # сообщения установщика были видны. exec заменяет процесс.
        exec 2>/dev/tty
        exec bash "$up_tmp"
    else
        rm -f "$up_tmp"
        echo "  ❌ Не удалось скачать install.sh (проверьте сеть)."
        return 1
    fi
}
