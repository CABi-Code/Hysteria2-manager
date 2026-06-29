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
    # Синхронизация ключей с пирами кластера + пересборка подписок.
    if ! echo "$current_cron" | grep -q "hy2-manager.*--cluster-sync"; then
        (echo "$current_cron"; echo "*/5 * * * * /bin/bash \"$script_path\" --cluster-sync >/dev/null 2>&1") | crontab -
    fi
}
