# hy2-manager

Bash-менеджер VPN-нод: Hysteria2 + VLESS/REALITY, SS-2022, Trojan/WS (Xray), TUIC v5 (sing-box).
Точка входа — `hy2-manager.sh` (TUI-меню), вся логика в `lib/*.sh` (~10k строк).

## Где что искать

| Тема | Файл |
|---|---|
| протоколы, конфиги ядер, рестарты | `lib/protocols.sh` |
| пользователи (создание/удаление/список) | `lib/users.sh` |
| подписка, ссылки, subscription_url | `lib/subscription.sh` |
| трафик, счётчики | `lib/traffic.sh` |
| лимиты устройств/скорости | `lib/limits.sh` |
| онлайн-активность, SSE | `lib/online.sh` |
| срок действия, продление | `lib/expiry.sh` |
| free-план, конструктор тарифов | `lib/freeplan.sh` (+ `tariffs.conf`) |
| Telegram-бот менеджера | `lib/tgbot.sh` |
| уведомления | `lib/notify.sh` |
| антиабуз, трекинг IP | `lib/antiabuse.sh`, `lib/ip_tracking.sh` |
| мультинода / кластер | `lib/cluster.sh` |
| HTTP API (обвязка) | `lib/api.sh`, `lib/webapi.sh` |
| TUI: меню, цвета, спиннеры | `lib/ui.sh` |
| обновление менеджера | `lib/update.sh`, `install.sh` |

HTTP API-демон: `webapi/hy2-webapi.py` (systemd `hy2-webapi`), запускается **из /opt**.
Контракт эндпоинтов — `docs/API.md`. Потребитель API — `/opt/надстройка`.

## Документация

`docs/` — по документу на функцию (`08-multiprotocol.md`, `09-online-activity.md`,
`10-multiprotocol-limits.md`, `API.md`, `NOTIFICATIONS.md`, ...).
Читай доку темы перед правкой её кода; новая фича = новый документ в `docs/`.

## Правила

- После правок в `webapi/` — `systemctl restart hy2-webapi`.
- Тесты: `tests/test-*.sh`, запускаются напрямую bash.
- Индикатор «работает» в UI — 💚, не 🟢.
- Коммит после каждого изменения; пуш пачкой при 7+ коммитах. Не форс-пушить `main`.
- Эта машина — нода **node-a**: webapp/webapi/caddy и все протоколы локальные,
  остальные ноды — отдельные VPS, обновляются с GitHub `main`.
