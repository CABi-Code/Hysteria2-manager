#!/bin/bash
# ================================================
# Настройка cron-задач для автосбора статистики
# ================================================

setup_cron() {
    local script_path
    script_path=$(realpath "$0" 2>/dev/null || readlink -f "$0" 2>/dev/null || echo "$0")
    if ! crontab -l 2>/dev/null | grep -q "hy2-manager.*--collect"; then
        (crontab -l 2>/dev/null; echo "*/30 * * * * /bin/bash \"$script_path\" --collect >/dev/null 2>&1") | crontab -
    fi
    if ! crontab -l 2>/dev/null | grep -q "hy2-manager.*--check-expiry"; then
        (crontab -l 2>/dev/null; echo "0 */6 * * * /bin/bash \"$script_path\" --check-expiry >/dev/null 2>&1") | crontab -
    fi
}
