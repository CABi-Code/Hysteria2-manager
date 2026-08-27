#!/bin/bash
# ================================================
# Настройка cron-задач для автосбора статистики
# ================================================

# Один живой прогон на режим. Предыдущий ещё не закончил — молча выходим
# (тик ПРОПУСКАЕМ, в очередь не ставим): периодической задаче нужен свежий
# прогон, а не отложенный. Без этого cron-режимы наслаивались друг на друга
# (--online-sync живёт дольше своей минуты) и нода уходила в 100% sy на форках.
# Замок внутри скрипта, а не в crontab: работает и при ручном запуске, и на
# нодах со старым crontab. См. docs/guide/CRON.md.
# Дескриптор берём динамический ({fd} -> 10+), а не «9»: fd 9 занимает
# _stats_lock (lib/traffic.sh), и его `exec 9>&-` закрыл бы наш замок посреди
# прогона. Скобки вокруг exec обязательны: `exec ... 2>/dev/null` без них
# перенаправляет stderr ВСЕГО процесса в /dev/null — лог ошибок замолкает.
cron_lock() {   # mode
    local fd
    { exec {fd}>"$DATA_DIR/.$1.lock"; } 2>/dev/null || return 0
    flock -n "$fd" && return 0
    # stderr уходит в /var/log/hy2-manager/error.log — хронический пропуск
    # виден там, а не выглядит как «cron не работает».
    echo "[$(date '+%F %T')] $1: предыдущий прогон ещё жив, тик пропущен" >&2
    exit 0
}

setup_cron() {
    # Используем стабильный путь установки. Это исключает ситуацию,
    # когда cron указывает на временный путь, из которого был запущен скрипт.
    local script_path="/opt/hy2-manager/hy2-manager.sh"
    if [ ! -x "$script_path" ]; then
        # Fallback: текущий путь, если менеджер запущен не из стандартной локации
        script_path=$(realpath "$0" 2>/dev/null || readlink -f "$0" 2>/dev/null || echo "$0")
    fi

    # cron не всегда установлен/запущен — не падаем, если так
    if ! command -v crontab &>/dev/null; then
        return 0
    fi

    local current_cron
    current_cron=$(crontab -l 2>/dev/null || true)

    if ! echo "$current_cron" | grep -q "hy2-manager.*--collect"; then
        (echo "$current_cron"; echo "*/30 * * * * /bin/bash \"$script_path\" --collect >/dev/null 2>&1") | crontab -
        current_cron=$(crontab -l 2>/dev/null || true)
    fi
    if ! echo "$current_cron" | grep -q "hy2-manager.*--check-expiry"; then
        (echo "$current_cron"; echo "0 */6 * * * /bin/bash \"$script_path\" --check-expiry >/dev/null 2>&1") | crontab -
        current_cron=$(crontab -l 2>/dev/null || true)
    fi
    # Частые ступенчатые напоминания об истечении (пороги 30мин/1ч ловятся только
    # при частом прогоне). См. lib/notify.sh и docs/guide/NOTIFICATIONS.md.
    if ! echo "$current_cron" | grep -q "hy2-manager.*--notify-sweep"; then
        (echo "$current_cron"; echo "*/5 * * * * /bin/bash \"$script_path\" --notify-sweep >/dev/null 2>&1") | crontab -
        current_cron=$(crontab -l 2>/dev/null || true)
    fi
    # Синхронизация ключей с пирами кластера + пересборка подписок.
    if ! echo "$current_cron" | grep -q "hy2-manager.*--cluster-sync"; then
        (echo "$current_cron"; echo "*/5 * * * * /bin/bash \"$script_path\" --cluster-sync >/dev/null 2>&1") | crontab -
        current_cron=$(crontab -l 2>/dev/null || true)
    fi
    # Каденс --online-sync поднят с 1 минуты до 2 (P-119). На 1 vCPU минутный тик
    # в свою минуту не укладывался и всё равно пропускался по cron_lock — до 120
    # раз в сутки, то есть фактическая частота давно не была минутной. Проверки
    # ниже только ДОБАВЛЯЮТ недостающие строки, поэтому уже установленную минутную
    # переписываем отдельно — иначе она осталась бы минутной навсегда.
    if echo "$current_cron" | grep -q '^\* \* \* \* \* .*hy2-manager.*--online-sync'; then
        printf '%s\n' "$current_cron" \
            | sed 's|^\* \* \* \* \* \(.*--online-sync.*\)$|*/2 * * * * \1|' | crontab -
        current_cron=$(crontab -l 2>/dev/null || true)
    fi
    # Частый обмен онлайном + лимит устройств по кластеру (раз в 2 минуты).
    if ! echo "$current_cron" | grep -q "hy2-manager.*--online-sync"; then
        (echo "$current_cron"; echo "*/2 * * * * /bin/bash \"$script_path\" --online-sync >/dev/null 2>&1") | crontab -
        current_cron=$(crontab -l 2>/dev/null || true)
    fi
    # Оплаты ЮMoney (если настроены): опрос истории по меткам ждущих счетов —
    # доступ выдаётся сам, даже если клиент закрыл чат (см. lib/yoomoney.sh).
    if ! echo "$current_cron" | grep -q "hy2-manager.*--ym-poll"; then
        (echo "$current_cron"; echo "* * * * * /bin/bash \"$script_path\" --ym-poll >/dev/null 2>&1") | crontab -
        current_cron=$(crontab -l 2>/dev/null || true)
    fi
    # Часовая коррекция анти-абуза (балл шаринга + авто-жёсткая проверка).
    if ! echo "$current_cron" | grep -q "hy2-manager.*--antiabuse"; then
        (echo "$current_cron"; echo "0 * * * * /bin/bash \"$script_path\" --antiabuse >/dev/null 2>&1") | crontab -
    fi
}
