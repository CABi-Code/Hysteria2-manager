#!/bin/bash
# ================================================
# Hysteria 2 — полная установка с нуля
# Устанавливает Hysteria 2, генерирует конфиг,
# сертификаты, firewall и менеджер пользователей
# ================================================

set -e

# === ЦВЕТА ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# === ПРОВЕРКА ROOT ===
if [ "$EUID" -ne 0 ]; then
    error "Запустите скрипт от root: sudo bash install.sh"
    exit 1
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         Установка Hysteria 2 + Manager v2.0                ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ================================================================
# 1. СИСТЕМНЫЕ ПАКЕТЫ
# ================================================================
info "Обновление системы и установка пакетов..."
apt update -qq && apt upgrade -y -qq
apt install -y -qq curl wget git unzip sudo ufw nftables openssl pwgen jq
ok "Пакеты установлены"

# ================================================================
# 2. BBR (ускорение TCP)
# ================================================================
if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    info "Включаю BBR..."
    grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
    ok "BBR включён"
else
    ok "BBR уже активен"
fi

# ================================================================
# 3. ПАРАМЕТРЫ УСТАНОВКИ (интерактивно)
# ================================================================
echo ""
info "Настройка параметров..."
echo ""

# Порт
DEFAULT_PORT=$(( RANDOM % 55000 + 10000 ))
read -p "  Порт Hysteria 2 [$DEFAULT_PORT]: " HY_PORT
HY_PORT=${HY_PORT:-$DEFAULT_PORT}

# SNI / маскировка
read -p "  Домен для маскировки [www.microsoft.com]: " HY_SNI
HY_SNI=${HY_SNI:-www.microsoft.com}

# OBFS пароль
DEFAULT_OBFS=$(pwgen -s 32 1)
read -p "  OBFS-пароль (Salamander) [$DEFAULT_OBFS]: " HY_OBFS
HY_OBFS=${HY_OBFS:-$DEFAULT_OBFS}

# Первый пользователь
read -p "  Имя первого пользователя [admin]: " FIRST_USER
FIRST_USER=${FIRST_USER:-admin}
FIRST_PASS=$(pwgen -s 64 1)

# trafficStats секрет
API_SECRET=$(pwgen -s 32 1)

echo ""
info "Конфигурация:"
echo "  Порт:       $HY_PORT"
echo "  SNI:        $HY_SNI"
echo "  OBFS:       ${HY_OBFS:0:20}..."
echo "  Пользователь: $FIRST_USER"
echo ""
read -p "  Продолжить установку? [Y/n]: " CONFIRM
CONFIRM=${CONFIRM:-Y}
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Отменено."
    exit 0
fi

# ================================================================
# 4. FIREWALL (nftables)
# ================================================================
info "Настройка firewall..."
ufw disable 2>/dev/null || true
systemctl stop ufw 2>/dev/null || true

# Добавляем правило для порта Hysteria (UDP)
if command -v nft &>/dev/null; then
    nft add rule ip filter INPUT udp dport "$HY_PORT" accept 2>/dev/null || true
    nft list ruleset > /etc/nftables.conf 2>/dev/null || true
    ok "nftables: порт $HY_PORT/udp открыт"
else
    warn "nftables не найден, убедитесь что порт $HY_PORT/udp открыт"
fi

# ================================================================
# 5. УСТАНОВКА HYSTERIA 2
# ================================================================
if command -v hysteria &>/dev/null; then
    ok "Hysteria 2 уже установлен: $(hysteria version 2>/dev/null | head -1)"
    read -p "  Переустановить? [y/N]: " REINSTALL
    if [[ "$REINSTALL" =~ ^[Yy]$ ]]; then
        info "Переустанавливаю Hysteria 2..."
        bash <(curl -fsSL https://get.hy2.sh/)
    fi
else
    info "Устанавливаю Hysteria 2..."
    bash <(curl -fsSL https://get.hy2.sh/)
fi
ok "Hysteria 2 установлен"

# ================================================================
# 6. СЕРТИФИКАТЫ (самоподписанные, 10 лет)
# ================================================================
CERT_DIR="/etc/hysteria/certs"
if [ -f "$CERT_DIR/cert.crt" ] && [ -f "$CERT_DIR/private.key" ]; then
    ok "Сертификаты уже существуют: $CERT_DIR"
    read -p "  Перегенерировать? [y/N]: " REGEN_CERT
    if [[ "$REGEN_CERT" =~ ^[Yy]$ ]]; then
        GENERATE_CERT=true
    else
        GENERATE_CERT=false
    fi
else
    GENERATE_CERT=true
fi

if $GENERATE_CERT; then
    info "Генерирую самоподписанный сертификат (10 лет)..."
    mkdir -p "$CERT_DIR"
    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout "$CERT_DIR/private.key" \
        -out "$CERT_DIR/cert.crt" \
        -subj "/CN=$HY_SNI" -days 3650 2>/dev/null
    chown -R hysteria:hysteria "$CERT_DIR" 2>/dev/null || true
    chmod 600 "$CERT_DIR/private.key"
    chmod 644 "$CERT_DIR/cert.crt"
    ok "Сертификат создан: $CERT_DIR"
fi

# ================================================================
# 7. КОНФИГ HYSTERIA 2
# ================================================================
CONFIG="/etc/hysteria/config.yaml"

info "Создаю конфиг: $CONFIG"

cat > "$CONFIG" << EOF
listen: :${HY_PORT}

tls:
  cert: /etc/hysteria/certs/cert.crt
  key: /etc/hysteria/certs/private.key

auth:
  type: userpass
  userpass:
    ${FIRST_USER}: "${FIRST_PASS}"

masquerade:
  type: proxy
  proxy:
    url: https://${HY_SNI}/
    rewriteHost: true

obfs:
  type: salamander
  salamander:
    password: "${HY_OBFS}"

quic:
  initStreamReceiveWindow: 16777216
  maxStreamReceiveWindow: 1073741824
  maxConnectionReceiveWindow: 1073741824
  maxIdleTimeout: 30s
  keepAlivePeriod: 10s

trafficStats:
  listen: 127.0.0.1:25580
  secret: ${API_SECRET}
EOF

ok "Конфиг создан"

# ================================================================
# 8. ДАННЫЕ МЕНЕДЖЕРА
# ================================================================
DATA_DIR="/etc/hysteria/manager"
mkdir -p "$DATA_DIR"
echo "$API_SECRET" > "$DATA_DIR/api_secret"
chmod 600 "$DATA_DIR/api_secret"
for f in stats.dat ips.dat expiry.dat disabled.dat; do
    [ -f "$DATA_DIR/$f" ] || touch "$DATA_DIR/$f"
done
ok "Директория менеджера: $DATA_DIR"

# ================================================================
# 9. УСТАНОВКА МЕНЕДЖЕРА
# ================================================================
INSTALL_DIR="/opt/hy2-manager"
info "Устанавливаю менеджер в $INSTALL_DIR..."

mkdir -p "$INSTALL_DIR/lib"

# Определяем откуда копировать (из текущей директории)
SCRIPT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cp "$SCRIPT_SRC/hy2-manager.sh" "$INSTALL_DIR/hy2-manager.sh"
cp "$SCRIPT_SRC"/lib/*.sh "$INSTALL_DIR/lib/"
chmod +x "$INSTALL_DIR/hy2-manager.sh"

# Симлинк для удобного запуска
ln -sf "$INSTALL_DIR/hy2-manager.sh" /usr/local/bin/hy2-manager

ok "Менеджер установлен"
ok "Запуск: hy2-manager"

# ================================================================
# 10. ЗАПУСК СЕРВИСА
# ================================================================
info "Запускаю Hysteria 2..."
systemctl enable hysteria-server.service 2>/dev/null || true
systemctl restart hysteria-server.service
sleep 2

if systemctl is-active --quiet hysteria-server.service; then
    ok "Сервис запущен и работает"
else
    error "Сервис НЕ запустился! Проверьте:"
    echo "  journalctl -u hysteria-server.service -e"
fi

# ================================================================
# 11. ИТОГ
# ================================================================
SERVER_IP=$(curl -4s --max-time 5 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
LINK="hysteria2://${FIRST_USER}:${FIRST_PASS}@${SERVER_IP}:${HY_PORT}/?obfs=salamander&obfs-password=${HY_OBFS}&sni=${HY_SNI}&insecure=1#${FIRST_USER}"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║              Установка завершена!                           ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║ IP сервера      : $SERVER_IP"
echo "║ Порт            : $HY_PORT"
echo "║ SNI             : $HY_SNI"
echo "║ OBFS-пароль     : ${HY_OBFS:0:20}..."
echo "║ Пользователь    : $FIRST_USER"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║ Менеджер        : hy2-manager"
echo "║ Конфиг          : $CONFIG"
echo "║ Сертификаты     : $CERT_DIR"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "🔗 ССЫЛКА ДЛЯ КЛИЕНТА:"
echo "$LINK"
echo ""
echo "💡 Вставьте в Hiddify, Nekobox, Streisand и т.д."
echo ""
echo "📌 Управление пользователями: hy2-manager"
echo ""
