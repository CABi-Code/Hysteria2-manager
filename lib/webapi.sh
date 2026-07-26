#!/bin/bash
# ================================================
# Web API для внешних приложений (mini-app, биллинги сторонних разработчиков).
#
# Демон: webapi/hy2-webapi.py (python3 stdlib, systemd-юнит hy2-webapi.service),
# слушает 127.0.0.1:8787; наружу — через Caddy (handle /api/* → reverse_proxy,
# блок добавляет setup_caddy, когда API включён). Мутации демон делает через
# webapi/dispatch.sh. Документация для разработчиков: docs/guide/API.md.
#
# Файлы в $DATA_DIR:
#   webapi.conf   ENABLED / BIND / PORT / RATE_RPM (KEY=VALUE)
#   webapi.keys   ключи доступа: «name|sha256(key)|scopes|created_ts» —
#                 хранится ТОЛЬКО хэш; открытый ключ показывается один раз
#   webapi_access.log   аудит запросов: «ts|key|method|path|status|ms»
# ================================================

WEBAPI_CONF="$DATA_DIR/webapi.conf"
WEBAPI_KEYS="$DATA_DIR/webapi.keys"
WEBAPI_UNIT="/etc/systemd/system/hy2-webapi.service"
WEBAPI_DEFAULT_PORT=8787

webapi_get() { [ -f "$WEBAPI_CONF" ] && grep "^${1}=" "$WEBAPI_CONF" 2>/dev/null | head -1 | cut -d= -f2-; }
webapi_set() {   # key value  (та же схема, что node_set/bot_set — без sed по значению)
    local key="$1" val="$2" tmp
    mkdir -p "$DATA_DIR"; touch "$WEBAPI_CONF"; chmod 600 "$WEBAPI_CONF" 2>/dev/null
    tmp=$(mktemp) || return 1
    grep -v "^${key}=" "$WEBAPI_CONF" > "$tmp" 2>/dev/null
    printf '%s=%s\n' "$key" "$val" >> "$tmp"
    cat "$tmp" > "$WEBAPI_CONF"
    rm -f "$tmp"
}

webapi_enabled() { [ "$(webapi_get ENABLED)" = "1" ]; }
webapi_port()    { local p; p=$(webapi_get PORT); [[ "$p" =~ ^[0-9]+$ ]] && echo "$p" || echo "$WEBAPI_DEFAULT_PORT"; }
webapi_running() { systemctl is-active --quiet hy2-webapi.service 2>/dev/null; }

# ---------- ключи доступа ----------

# Создать ключ. Печатает ОТКРЫТЫЙ ключ (единственный раз!); в файле — sha256.
webapi_gen_key() {   # name scopes -> key
    local name="$1" scopes="${2:-*}" key hash
    [[ "$name" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || { echo ""; return 1; }
    key="hyk_$(pwgen -s 40 1 2>/dev/null || head -c 60 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 40)"
    hash=$(printf '%s' "$key" | sha256sum | cut -d' ' -f1)
    touch "$WEBAPI_KEYS"; chmod 600 "$WEBAPI_KEYS" 2>/dev/null
    sed -i "/^${name}|/d" "$WEBAPI_KEYS" 2>/dev/null
    printf '%s|%s|%s|%s\n' "$name" "$hash" "$scopes" "$(date +%s)" >> "$WEBAPI_KEYS"
    printf '%s' "$key"
}

webapi_revoke_key() { sed -i "/^${1}|/d" "$WEBAPI_KEYS" 2>/dev/null; }

webapi_list_keys() {
    [ -f "$WEBAPI_KEYS" ] || return 0
    awk -F'|' 'NF>=4 {printf "  %-20s scopes: %-28s создан: %s\n", $1, $3, strftime("%Y-%m-%d", $4)}' "$WEBAPI_KEYS" 2>/dev/null
}

# ---------- systemd ----------

webapi_install_unit() {
    cat > "$WEBAPI_UNIT" <<EOF
[Unit]
Description=hy2-manager Web API (JSON API for external apps)
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${SCRIPT_DIR}/webapi/hy2-webapi.py
Restart=always
RestartSec=3
UMask=0077
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload 2>/dev/null
}

webapi_enable() {
    command -v python3 >/dev/null 2>&1 || { echo "  ❌ Нужен python3 (apt install python3)"; return 1; }
    webapi_set ENABLED 1
    webapi_set PORT "$(webapi_port)"
    webapi_install_unit
    systemctl enable --now hy2-webapi.service &>/dev/null
    # Пересобрать Caddyfile с блоком /api/* (наружный HTTPS-доступ). Без подписки
    # (нет домена/Caddy) API остаётся доступен только с localhost — тоже валидно.
    if sub_enabled; then setup_caddy >/dev/null 2>&1 || true; fi
    webapi_running
}

webapi_disable() {
    webapi_set ENABLED 0
    systemctl disable --now hy2-webapi.service &>/dev/null
    if sub_enabled; then setup_caddy >/dev/null 2>&1 || true; fi
    return 0
}

# ---------- меню ----------

webapi_menu() {
    local choice name scopes key
    while true; do
        clear
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  🌐 Web API для внешних приложений"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        if webapi_enabled; then
            echo "  Статус: 💚 включён · демон: $(webapi_running && echo '💚 работает' || echo '🔴 остановлен')"
            echo "  Локально:  http://127.0.0.1:$(webapi_port)/v1/health"
            if sub_enabled; then
                echo "  Извне:     https://$(node_host)/api/v1/health"
            else
                echo "  Извне:     ⚪ подписка не настроена — только localhost"
            fi
        else
            echo "  Статус: ⚪ выключен"
        fi
        echo "  Документация для разработчиков: docs/guide/API.md"
        echo ""
        echo "  Ключи доступа:"
        local keys; keys=$(webapi_list_keys)
        if [ -n "$keys" ]; then echo "$keys"; else echo "    (нет — создайте, пункт 2)"; fi
        echo ""
        if webapi_enabled; then
            echo "  1. 🔴 Выключить API"
        else
            echo "  1. 💚 Включить API"
        fi
        echo "  2. 🔑 Создать ключ доступа"
        echo "  3. 🗑  Отозвать ключ"
        echo "  4. 🔄 Перезапустить демон"
        echo "  0. ↩  Назад"
        echo ""
        ask choice "  Выбор: "
        case "$choice" in
            1)
                if webapi_enabled; then
                    webapi_disable && echo "  ✅ API выключен"
                else
                    webapi_enable && echo "  ✅ API включён" || echo "  ❌ Демон не стартовал (journalctl -u hy2-webapi)"
                fi
                pause "  Enter для продолжения..."
                ;;
            2)
                ask name "  Имя ключа (латиница/цифры, например надстройка): "
                [[ "$name" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || { echo "  ❌ Недопустимое имя"; pause "  Enter..."; continue; }
                echo "  Scopes: read (чтение) · users (управление) · payments (журнал оплат)"
                echo "          telegram (привязки/коды) · * (все)"
                ask scopes "  Scopes через запятую [read]: "
                [ -z "$scopes" ] && scopes="read"
                [[ "$scopes" =~ ^[a-z*,]+$ ]] || { echo "  ❌ Недопустимые scopes"; pause "  Enter..."; continue; }
                key=$(webapi_gen_key "$name" "$scopes")
                if [ -n "$key" ]; then
                    echo ""
                    echo "  🔑 Ключ (показывается ОДИН раз, в файле хранится только хэш):"
                    echo ""
                    echo "      $key"
                    echo ""
                else
                    echo "  ❌ Не удалось создать ключ"
                fi
                pause "  Enter для продолжения..."
                ;;
            3)
                ask name "  Имя ключа для отзыва: "
                [[ "$name" =~ ^[A-Za-z0-9_-]{1,32}$ ]] && webapi_revoke_key "$name" && echo "  ✅ Отозван (если существовал)"
                pause "  Enter для продолжения..."
                ;;
            4)
                systemctl restart hy2-webapi.service &>/dev/null
                sleep 1
                webapi_running && echo "  ✅ Работает" || echo "  ❌ Не стартовал (journalctl -u hy2-webapi)"
                pause "  Enter для продолжения..."
                ;;
            0|"")
                return 0
                ;;
        esac
    done
}
