#!/bin/bash
# ================================================
# Hysteria 2 — полная установка с нуля (curl|bash)
# Устанавливает Hysteria 2, генерирует конфиг,
# сертификаты, firewall и менеджер пользователей
# ================================================

set -euo pipefail

# === РЕПОЗИТОРИЙ ИСХОДНИКОВ ===
# Откуда скачиваются файлы менеджера. Можно переопределить:
#   REPO_URL=https://raw.githubusercontent.com/USER/REPO/BRANCH bash <(curl ...)
REPO_URL="${REPO_URL:-https://raw.githubusercontent.com/CABi-Code/Hysteria2-manager/main}"

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
die()   { error "$1"; exit 1; }

# === ПРОВЕРКА ROOT ===
if [ "$EUID" -ne 0 ]; then
    die "Запустите скрипт от root: sudo bash <(curl -fsSL ...)"
fi

# === ПРОВЕРКА: интерактивный TTY (нужен для read) ===
# Если запущено через `curl|bash`, stdin занят пайпом — read не сработает.
if [ ! -t 0 ]; then
    if [ -e /dev/tty ]; then
        exec </dev/tty
    else
        die "Нет интерактивного терминала. Используйте: bash <(curl -fsSL ...) вместо curl|bash"
    fi
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         Установка Hysteria 2 + Manager v2.1                ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ================================================================
# 1. СИСТЕМНЫЕ ПАКЕТЫ
# ================================================================
info "Обновление системы и установка пакетов..."
export DEBIAN_FRONTEND=noninteractive
apt update -qq
apt install -y -qq curl wget unzip sudo ufw openssl pwgen jq ca-certificates cron
ok "Пакеты установлены"

# ================================================================
# 2. BBR (ускорение TCP)
# ================================================================
if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    info "Включаю BBR..."
    grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1 || true
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
if ! [[ "$HY_PORT" =~ ^[0-9]+$ ]] || [ "$HY_PORT" -lt 1 ] || [ "$HY_PORT" -gt 65535 ]; then
    die "Порт должен быть целым числом 1-65535"
fi

# SNI / маскировка
read -p "  Домен для маскировки [www.twitch.tv]: " HY_SNI
HY_SNI=${HY_SNI:-www.twitch.tv}

# OBFS пароль (генерируется только из [A-Za-z0-9] для URL-safe)
DEFAULT_OBFS=$(pwgen -s 32 1)
read -p "  OBFS-пароль (Salamander) [$DEFAULT_OBFS]: " HY_OBFS
HY_OBFS=${HY_OBFS:-$DEFAULT_OBFS}
# защита от спецсимволов в YAML/URL — разрешаем только [A-Za-z0-9_-]
if [[ ! "$HY_OBFS" =~ ^[A-Za-z0-9_-]+$ ]]; then
    die "OBFS-пароль должен содержать только латиницу/цифры/_/-"
fi

# Первый пользователь
read -p "  Имя первого пользователя [admin]: " FIRST_USER
FIRST_USER=${FIRST_USER:-admin}
if [[ ! "$FIRST_USER" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    die "Имя пользователя должно быть из латиницы/цифр/_/-"
fi
case "$FIRST_USER" in
    type|userpass|password|proxy|url|listen|tls|cert|key|auth|masquerade|obfs|salamander|quic|trafficStats|secret)
        die "Имя '$FIRST_USER' зарезервировано (конфликт с YAML-ключами)"
        ;;
esac
FIRST_PASS=$(pwgen -s 64 1)

# trafficStats секрет (alphanumeric → безопасен в YAML без кавычек)
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
# 4. FIREWALL
# ================================================================
info "Настройка firewall..."

# Если есть ufw и он включён — добавляем правило, не отключая.
if command -v ufw &>/dev/null; then
    if ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${HY_PORT}/udp" >/dev/null 2>&1 || true
        ok "ufw: разрешён ${HY_PORT}/udp"
    else
        ok "ufw неактивен — пропускаю"
    fi
fi

# nftables: добавляем правило корректно (создаём таблицу/цепочку при необходимости)
if command -v nft &>/dev/null; then
    # Проверяем наличие таблицы inet filter
    if ! nft list table inet filter &>/dev/null; then
        nft add table inet filter 2>/dev/null || true
    fi
    # Проверяем наличие цепочки input
    if ! nft list chain inet filter input &>/dev/null; then
        nft 'add chain inet filter input { type filter hook input priority 0 ; policy accept; }' 2>/dev/null || true
    fi
    # Добавляем правило (idempotent: проверяем, нет ли его уже)
    if ! nft list chain inet filter input 2>/dev/null | grep -q "udp dport ${HY_PORT} accept"; then
        nft add rule inet filter input udp dport "$HY_PORT" accept 2>/dev/null || true
    fi
    ok "nftables: ${HY_PORT}/udp разрешён"
fi

# ================================================================
# 5. УСТАНОВКА HYSTERIA 2
# ================================================================
install_hysteria() {
    local tmpfile
    tmpfile=$(mktemp)
    info "Скачиваю официальный установщик Hysteria 2..."
    if ! curl -fsSL --max-time 60 "https://get.hy2.sh/" -o "$tmpfile"; then
        rm -f "$tmpfile"
        die "Не удалось скачать https://get.hy2.sh/ (проверьте сеть)"
    fi
    if [ ! -s "$tmpfile" ]; then
        rm -f "$tmpfile"
        die "Скачанный установщик Hysteria 2 пустой"
    fi
    bash "$tmpfile"
    rm -f "$tmpfile"
}

if command -v hysteria &>/dev/null; then
    ok "Hysteria 2 уже установлен: $(hysteria version 2>/dev/null | head -1)"
    read -p "  Переустановить? [y/N]: " REINSTALL
    if [[ "${REINSTALL:-}" =~ ^[Yy]$ ]]; then
        install_hysteria
    fi
else
    install_hysteria
fi

# Проверяем что бинарник реально появился
if ! command -v hysteria &>/dev/null; then
    die "Hysteria 2 не установился. Проверьте логи выше."
fi
ok "Hysteria 2 установлен: $(hysteria version 2>/dev/null | head -1)"

# Проверяем что пользователь hysteria создан официальным установщиком.
# Если нет — создаём вручную (иначе chown ниже не сработает и сервис не прочитает private.key).
if ! id -u hysteria &>/dev/null; then
    warn "Пользователь hysteria не создан официальным установщиком, создаю..."
    useradd --system --no-create-home --shell /usr/sbin/nologin hysteria || \
        die "Не удалось создать пользователя hysteria"
fi

# ================================================================
# 6. СЕРТИФИКАТЫ (самоподписанные, 10 лет)
# ================================================================
CERT_DIR="/etc/hysteria/certs"
mkdir -p "$CERT_DIR"

GENERATE_CERT=true
if [ -f "$CERT_DIR/cert.crt" ] && [ -f "$CERT_DIR/private.key" ]; then
    ok "Сертификаты уже существуют: $CERT_DIR"
    read -p "  Перегенерировать? [y/N]: " REGEN_CERT
    [[ ! "${REGEN_CERT:-}" =~ ^[Yy]$ ]] && GENERATE_CERT=false
fi

if $GENERATE_CERT; then
    info "Генерирую самоподписанный сертификат (10 лет)..."
    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout "$CERT_DIR/private.key" \
        -out "$CERT_DIR/cert.crt" \
        -subj "/CN=$HY_SNI" -days 3650 2>/dev/null
    ok "Сертификат создан: $CERT_DIR"
fi

# Права: hysteria должна читать оба файла. Проверяем явно.
chown -R hysteria:hysteria "$CERT_DIR" || die "chown на $CERT_DIR не удался"
chmod 600 "$CERT_DIR/private.key"
chmod 644 "$CERT_DIR/cert.crt"

# Sanity-check: hysteria может прочитать private.key?
if ! sudo -u hysteria test -r "$CERT_DIR/private.key"; then
    die "Пользователь hysteria не может прочитать $CERT_DIR/private.key — проверьте права"
fi
ok "Права на сертификаты выставлены корректно"

# ================================================================
# 7. КОНФИГ HYSTERIA 2
# ================================================================
CONFIG="/etc/hysteria/config.yaml"

info "Создаю конфиг: $CONFIG"

# Бэкап старого конфига если есть
if [ -f "$CONFIG" ]; then
    cp -a "$CONFIG" "${CONFIG}.bak.$(date +%s)"
fi

cat > "$CONFIG" << EOF
listen: :${HY_PORT}

tls:
  cert: ${CERT_DIR}/cert.crt
  key: ${CERT_DIR}/private.key

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
  initConnReceiveWindow: 33554432
  maxConnReceiveWindow: 1073741824
  maxIdleTimeout: 30s
  keepAlivePeriod: 10s

trafficStats:
  listen: 127.0.0.1:25580
  secret: ${API_SECRET}
EOF

# Конфиг содержит секреты — закрываем от чужих, но даём прочитать hysteria
chown root:hysteria "$CONFIG"
chmod 640 "$CONFIG"
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

# Каталог логов менеджера
LOG_DIR="/var/log/hy2-manager"
mkdir -p "$LOG_DIR"
touch "$LOG_DIR/error.log"
chmod 750 "$LOG_DIR"
chmod 640 "$LOG_DIR/error.log"
ok "Лог-каталог: $LOG_DIR/error.log"

# ================================================================
# 9. УСТАНОВКА МЕНЕДЖЕРА (скачиваем из REPO_URL)
# ================================================================
INSTALL_DIR="/opt/hy2-manager"
info "Устанавливаю менеджер в $INSTALL_DIR (источник: $REPO_URL)..."
mkdir -p "$INSTALL_DIR/lib"

download_file() {
    local src="$1" dst="$2"
    if ! curl -fsSL --max-time 30 "$src" -o "$dst.tmp"; then
        die "Не удалось скачать $src"
    fi
    if [ ! -s "$dst.tmp" ]; then
        rm -f "$dst.tmp"
        die "Скачанный $src пустой"
    fi
    mv "$dst.tmp" "$dst"
}

download_file "$REPO_URL/hy2-manager.sh" "$INSTALL_DIR/hy2-manager.sh"
for f in config.sh deps.sh api.sh traffic.sh ip_tracking.sh online.sh expiry.sh users.sh cron.sh migration.sh ui.sh; do
    download_file "$REPO_URL/lib/$f" "$INSTALL_DIR/lib/$f"
done

chmod +x "$INSTALL_DIR/hy2-manager.sh"

# Симлинк для удобного запуска
ln -sf "$INSTALL_DIR/hy2-manager.sh" /usr/local/bin/hy2-manager

ok "Менеджер установлен"

# ================================================================
# 10. ЗАПУСК СЕРВИСА
# ================================================================
info "Запускаю Hysteria 2..."
systemctl daemon-reload 2>/dev/null || true
systemctl enable hysteria-server.service 2>/dev/null || true
systemctl restart hysteria-server.service
sleep 3

if systemctl is-active --quiet hysteria-server.service; then
    ok "Сервис запущен и работает"
else
    error "Сервис НЕ запустился! Последние строки лога:"
    journalctl -u hysteria-server.service -n 30 --no-pager 2>/dev/null || true
    die "Установка прервана: hysteria-server не запущен"
fi

# Проверяем, что порт реально слушается
if command -v ss &>/dev/null; then
    if ss -unlp 2>/dev/null | grep -q ":${HY_PORT} "; then
        ok "UDP-порт ${HY_PORT} прослушивается"
    else
        warn "UDP-порт ${HY_PORT} не виден в ss (возможно, всё ок, но проверьте вручную)"
    fi
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
