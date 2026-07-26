#!/bin/bash
# ================================================
# Настройка cron-задач для автосбора статистики
# ================================================

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
    # Частый обмен онлайном + лимит устройств по кластеру (раз в минуту).
    if ! echo "$current_cron" | grep -q "hy2-manager.*--online-sync"; then
        (echo "$current_cron"; echo "* * * * * /bin/bash \"$script_path\" --online-sync >/dev/null 2>&1") | crontab -
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
