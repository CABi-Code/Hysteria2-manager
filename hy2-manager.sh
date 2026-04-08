#!/bin/bash
# ================================================
# Hysteria 2 Manager — полноценная программа
# для создания пользователей, генерации 64-символьных паролей
# и мгновенной выдачи готовых ссылок
# Работает на Debian 13 (апрель 2026)
# Автоматически читает ВСЕ данные из /etc/hysteria/config.yaml
# ================================================

CONFIG="/etc/hysteria/config.yaml"
SERVICE="hysteria-server.service"

# ====================== ПРОВЕРКА ЗАВИСИМОСТЕЙ ======================
if ! command -v pwgen &> /dev/null; then
    echo "📦 Устанавливаю pwgen (генератор паролей)..."
    apt update -qq && apt install -y pwgen
fi

# ====================== ФУНКЦИИ ЧТЕНИЯ ИЗ КОНФИГА ======================
get_ip() {
    # Пытаемся получить публичный IP автоматически
    curl -4s --max-time 5 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}'
}

get_port() {
    grep -oP '(?<=listen: :)\d+' "$CONFIG" || echo "11478"
}

get_obfs_pass() {
    # Читаем obfs.salamander.password
    grep -oP '(?<=password: ")[^"]+' <(grep -A 5 "salamander:" "$CONFIG") | head -1
}

get_sni() {
    # Читаем домен из masquerade.proxy.url
    grep -oP '(?<=url: https://)[^/]+' "$CONFIG" | head -1 || echo "www.microsoft.com"
}

get_user_password() {
    # Ищем пароль конкретного пользователя (4 пробела отступ)
    grep -oP "^    ${1}:\s*\"\K[^\"]*" "$CONFIG"
}

# ====================== АВТОПЕРЕКЛЮЧЕНИЕ НА userpass ======================
if grep -q 'type: password' "$CONFIG"; then
    echo "⚠️  Обнаружен старый тип auth: password"
    echo "   Автоматически переключаю на userpass (много пользователей)..."
    
    # Меняем тип
    sed -i 's/type: password/type: userpass/' "$CONFIG"
    
    # Удаляем старую строку password:
    sed -i '/^  password:/d' "$CONFIG"
    
    # Добавляем блок userpass, если его ещё нет
    if ! grep -q '^  userpass:' "$CONFIG"; then
        sed -i '/^auth:/a \  userpass:' "$CONFIG"
    fi
    
    echo "✅ Переключено на userpass. Теперь можно добавлять пользователей."
    echo ""
fi

# ====================== ГЛАВНОЕ МЕНЮ ======================
while true; do
    clear
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║           Hysteria 2 Manager (полноценная программа)         ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║ IP сервера     : $(get_ip)                                   ║"
    echo "║ Порт           : $(get_port)                                 ║"
    echo "║ SNI / Маскировка : $(get_sni)                               ║"
    echo "║ OBFS-пароль    : $(get_obfs_pass | cut -c1-20)...           ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "1. ➕ Добавить нового пользователя (64-символьный пароль)"
    echo "2. 📋 Показать список всех пользователей"
    echo "3. 🔗 Получить готовую ссылку для конкретного пользователя"
    echo "4. 🚪 Выход"
    echo ""
    read -p "Выберите действие (1-4): " choice

    case $choice in
        1)
            read -p "Введите имя пользователя (только латиница и _, например: ivan_mts): " USERNAME
            [ -z "$USERNAME" ] && echo "❌ Имя не может быть пустым!" && sleep 2 && continue

            if grep -q "^    $USERNAME:" "$CONFIG"; then
                echo "❌ Пользователь $USERNAME уже существует!"
                sleep 2
                continue
            fi

            PASSWORD=$(pwgen -s 64 1)
            echo "🔑 Сгенерирован 64-символьный пароль"

            # Добавляем пользователя в конфиг с правильным отступом (4 пробела)
            sed -i "/^  userpass:/a \    $USERNAME: \"$PASSWORD\"" "$CONFIG"

            echo "✅ Пользователь $USERNAME успешно добавлен в config.yaml"

            # Перезапускаем сервис
            echo "🔄 Перезапускаю Hysteria 2..."
            systemctl restart "$SERVICE"
            sleep 2

            if systemctl is-active --quiet "$SERVICE"; then
                echo "✅ Сервис запущен успешно"
            else
                echo "⚠️  Сервис НЕ запустился! Проверьте: journalctl -u $SERVICE -e"
            fi

            # Формируем и выводим готовую ссылку
            IP=$(get_ip)
            PORT=$(get_port)
            OBFS=$(get_obfs_pass)
            SNI=$(get_sni)
            LINK="hysteria2://${USERNAME}:${PASSWORD}@${IP}:${PORT}/?obfs=salamander&obfs-password=${OBFS}&sni=${SNI}&insecure=1#${USERNAME}"

            echo ""
            echo "🔗 ГОТОВАЯ ССЫЛКА (скопируйте):"
            echo "$LINK"
            echo ""
            echo "💡 Вставляйте в Hiddify, Nekobox, Streisand и т.д."
            echo "   QR-код можно сделать на qr-code-generator.com"
            read -p "Нажмите Enter для возврата в меню..."
            ;;

        2)
            echo "📋 Список всех пользователей:"
            USERS=$(grep -A 100 "^  userpass:" "$CONFIG" | grep -E '^\s{4}[a-zA-Z0-9_-]+:' | sed 's/^\s*//; s/:.*//')
            if [ -z "$USERS" ]; then
                echo "   Пока нет ни одного пользователя."
            else
                echo "$USERS"
            fi
            echo ""
            read -p "Нажмите Enter для возврата в меню..."
            ;;

        3)
            read -p "Введите имя пользователя: " USERNAME
            PASSWORD=$(get_user_password "$USERNAME")

            if [ -z "$PASSWORD" ]; then
                echo "❌ Пользователь $USERNAME не найден!"
                sleep 2
                continue
            fi

            IP=$(get_ip)
            PORT=$(get_port)
            OBFS=$(get_obfs_pass)
            SNI=$(get_sni)

            LINK="hysteria2://${USERNAME}:${PASSWORD}@${IP}:${PORT}/?obfs=salamander&obfs-password=${OBFS}&sni=${SNI}&insecure=1#${USERNAME}"

            echo ""
            echo "🔗 ГОТОВАЯ ССЫЛКА:"
            echo "$LINK"
            echo ""
            read -p "Нажмите Enter для возврата в меню..."
            ;;

        4)
            echo "👋 Выход из программы..."
            exit 0
            ;;

        *)
            echo "❌ Неверный выбор! Введите число от 1 до 4."
            sleep 1.5
            ;;
    esac
done
