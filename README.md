# Hysteria 2 Manager v2.0

Интерактивный менеджер пользователей для [Hysteria 2](https://hysteria.network/) VPN-сервера.

## Возможности

- **Управление пользователями** — добавление, отключение, включение, удаление, смена пароля
- **Генерация ссылок** — готовые `hysteria2://` URI для клиентов (Hiddify, Nekobox, Streisand и др.)
- **Статистика трафика** — учёт отправленного/полученного трафика через Hysteria API
- **IP-трекинг** — отслеживание уникальных IP-адресов, обнаружение утечки/шаринга аккаунтов
- **Сроки действия** — автоматическое отключение пользователей по истечении срока
- **Автомиграция** — переключение `auth: password` на `auth: userpass` при первом запуске
- **Cron-задачи** — автосбор статистики каждые 30 минут, проверка сроков каждые 6 часов

## Требования

- Debian / Ubuntu (тестировалось на Debian 13)
- root-доступ
- Все зависимости устанавливаются автоматически

## Установка с нуля (рекомендуется)

Полная установка одной командой — без `git clone`:

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/CABi-Code/Hysteria2-manager/main/install.sh)
```

> ⚠️ Используйте именно `bash <(curl ...)`, а не `curl ... | bash` — установщику нужен интерактивный TTY для запроса параметров (порт, SNI, имя пользователя). Скрипт сам определит подмену stdin и попытается переключиться на `/dev/tty`, но `bash <(...)` гарантированно работает.

Скрипт интерактивно спросит:
- **Порт** — UDP-порт для Hysteria (по умолчанию случайный 10000-65000)
- **Домен для маскировки** — SNI для TLS (по умолчанию `www.microsoft.com`)
- **OBFS-пароль** — пароль обфускации Salamander (генерируется автоматически)
- **Имя первого пользователя** — будет создан с 64-символьным паролем

После установки менеджер доступен командой `hy2-manager`.

### Альтернативные источники

Если форкнули репозиторий, можно указать свой URL через переменную окружения:

```bash
sudo REPO_URL="https://raw.githubusercontent.com/USERNAME/REPO/BRANCH" \
    bash <(curl -fsSL https://raw.githubusercontent.com/USERNAME/REPO/BRANCH/install.sh)
```

### Что делает install.sh

1. Обновляет систему, ставит зависимости (`curl`, `jq`, `pwgen`, `openssl`, `cron`)
2. Включает BBR (ускорение TCP)
3. Открывает UDP-порт (`ufw allow` если активен, либо корректное правило nftables)
4. Скачивает и устанавливает Hysteria 2 (с проверкой успешности загрузки)
5. Гарантирует наличие пользователя `hysteria` и проверяет, что приватный ключ читается
6. Генерирует самоподписанный сертификат (10 лет)
7. Создаёт `config.yaml` с обфускацией Salamander, QUIC-тюнингом и trafficStats API (mode 640)
8. Скачивает менеджер из репозитория в `/opt/hy2-manager`, создаёт симлинк `/usr/local/bin/hy2-manager`
9. Запускает `hysteria-server.service`, проверяет что он `active` и слушает UDP-порт
10. Выводит готовую `hysteria2://` ссылку для клиента

## Установка только менеджера (Hysteria 2 уже стоит)

```bash
sudo mkdir -p /opt/hy2-manager/lib
BASE="https://raw.githubusercontent.com/CABi-Code/Hysteria2-manager/main"
sudo curl -fsSL "$BASE/hy2-manager.sh" -o /opt/hy2-manager/hy2-manager.sh
for f in config.sh deps.sh api.sh traffic.sh ip_tracking.sh online.sh \
         expiry.sh users.sh cron.sh migration.sh ui.sh; do
    sudo curl -fsSL "$BASE/lib/$f" -o "/opt/hy2-manager/lib/$f"
done
sudo chmod +x /opt/hy2-manager/hy2-manager.sh
sudo ln -sf /opt/hy2-manager/hy2-manager.sh /usr/local/bin/hy2-manager
sudo hy2-manager
```

## Структура проекта

```
install.sh               # Полная установка: Hysteria 2 + конфиг + менеджер
hy2-manager.sh           # Точка входа: CLI-аргументы, инициализация, главное меню
lib/
  config.sh              # Конфигурация, пути к файлам, чтение config.yaml
  deps.sh                # Проверка и установка зависимостей
  api.sh                 # Работа с Hysteria trafficStats API
  traffic.sh             # Сбор и форматирование статистики трафика
  ip_tracking.sh         # Сбор и анализ IP-адресов пользователей
  online.sh              # Онлайн-статус через API
  expiry.sh              # Управление сроками действия
  users.sh               # CRUD-операции над пользователями
  cron.sh                # Настройка cron-задач
  migration.sh           # Автомиграция auth: password -> userpass
  ui.sh                  # Интерфейс: таблицы, подменю, меню ссылок
```

## Использование

### Интерактивный режим

```bash
sudo hy2-manager
```

Откроется главное меню:

```
╔══════════════════════════════════════════════════════════════╗
║              Hysteria 2 Manager v2.0                       ║
╠══════════════════════════════════════════════════════════════╣
║ IP сервера      : 203.0.113.1
║ Порт            : 11478
║ SNI / Маскировка: www.twitch.tv
║ OBFS-пароль     : abc123def456ghij7890...
║ Пользователей   : 5 (активных: 3, онлайн: 1)
╚══════════════════════════════════════════════════════════════╝

  1. ➕ Добавить нового пользователя
  2. 👥 Пользователи (статистика, IP, действия)
  3. 🔗 Получить ссылку
  4. 🚪 Выход
```

### CLI-режим (для cron)

```bash
# Сбор трафика и IP-адресов
sudo hy2-manager --collect

# Проверка и отключение просроченных пользователей
sudo hy2-manager --check-expiry
```

Cron-задачи настраиваются автоматически при первом запуске.

## Данные

Все данные хранятся в `/etc/hysteria/manager/`:

| Файл | Описание |
|------|----------|
| `stats.dat` | Статистика трафика (user\|tx\|rx) |
| `ips.dat` | IP-адреса (user\|ip\|first_seen\|last_seen\|count) |
| `expiry.dat` | Сроки действия (user\|YYYY-MM-DD) |
| `disabled.dat` | Отключённые пользователи (user\|password) |
| `api_secret` | Секрет trafficStats API |

## Дополнительно

Вы можете использовать любые клиенты для ключей подключения, которые поддерживают протокол `hysteria2`

**Например:**
- [Hiddify](https://github.com/hiddify/hiddify-app/releases/latest)

## Лицензия

MIT
