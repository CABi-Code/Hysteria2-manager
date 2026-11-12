# Web API менеджера — справочник для разработчиков

Работающий HTTP JSON API поверх hy2-manager: внешние приложения (Telegram
mini-app, биллинг, свой бот, панель) читают состояние пользователей и управляют
ими, не трогая файлы менеджера напрямую. Это **практическая документация** —
в отличие от исследовательских заметок `01…07`, здесь описано то, что уже
работает.

- Демон: `webapi/hy2-webapi.py` (python3, только stdlib) + systemd-юнит
  `hy2-webapi.service`. Слушает `127.0.0.1:8787`.
- Мутации демон выполняет через `webapi/dispatch.sh` — те же lib-функции, что
  меню и Telegram-бот, поэтому кластерная синхронизация, метки времени и
  пересборка подписок происходят штатно. Список модулей `dispatch.sh` читает
  из `_required_libs` в `hy2-manager.sh` (свой список не держит: копия уже
  разъезжалась после разбиения `subscription.sh` — API отвечал `sub_disabled`
  на выдачу демо). Интерактивные `ui*` пропускаются.
- Включение: меню менеджера → пункт **6. 🌐 Web API** → «Включить», там же
  создаются ключи доступа.

## Доступ снаружи

Если на ноде настроена подписка (домен + Caddy), при включении API в Caddyfile
добавляется блок `handle /api/*` → все эндпоинты доступны по
`https://<домен-ноды>/api/v1/...` с авто-HTTPS. Без домена API доступен только
с localhost (например, приложению на этой же машине).

> Никогда не публикуйте порт демона (8787) напрямую наружу — только через
> реверс-прокси с TLS.

## Аутентификация

Каждый запрос (кроме `/v1/health`) требует заголовок:

```
Authorization: Bearer hyk_<40 символов>
```

Ключи создаются в меню (пункт 6 → «Создать ключ»). Открытый ключ показывается
**один раз**; в `webapi.keys` хранится только SHA-256. Ключу назначаются
**scopes**:

| Scope | Даёт право |
|---|---|
| `read` | все GET-эндпоинты (статусы, тарифы, подписки, привязки) |
| `users` | создание/продление/включение/отключение/лимиты пользователей |
| `payments` | чтение журнала оплат `/v1/payments` |
| `telegram` | привязка Telegram-аккаунтов, погашение кодов |
| `tariffs` | правка каталога: создать/изменить/удалить/переставить тариф, режим звёздной цены |
| `*` | всё |

Рекомендация: каждому приложению — свой ключ с минимальными scopes (mini-app
хватает `read,users,payments,telegram`; странице статуса — только `read`).

**Исключение — соседние ноды кластера.** В ветку `/v1/demo*` пускают ещё и по
заголовку `X-Cluster-Auth` с общим секретом кластера: нода, выбранная приёмником
демо, заводит профиль у себя по просьбе выдающей ноды
([DEMO-KEYS.md](DEMO-KEYS.md) §5). Больше этот секрет в API не даёт ничего, и
ключей `webapi.keys` раздавать по нодам не нужно.

## Формат ответов

Всегда JSON, UTF-8:

```json
{"ok": true,  "data": { ... }}
{"ok": false, "error": {"code": "user_not_found", "message": "пользователь не найден"}}
```

Коды HTTP: `200` успех · `400` неверные параметры · `401` нет/неверный ключ ·
`403` не хватает scope · `404` объект не найден · `405` метод не поддерживается ·
`409` конфликт состояния · `413 payload_too_large` тело запроса больше 64 КБ ·
`429` превышен rate limit (заголовок `Retry-After`) ·
`503 busy` менеджер занят другой мутацией (заголовок `Retry-After`, обычно 15 с —
повторите запрос позже) · `504 dispatch_timeout` менеджер не ответил за 60 секунд
(состояние операции неизвестно — перед повтором проверьте его чтением) ·
прочие `5xx` — внутренняя ошибка менеджера.

**Rate limit:** 120 запросов/мин на ключ (RATE_RPM в `webapi.conf`). Все запросы
пишутся в аудит-лог `webapi_access.log` (`ts|key|method|path|status|ms`).

## Версионирование

Все пути начинаются с `/v1/`. Гарантии в пределах v1: существующие поля не
переименовываются и не меняют тип; новые поля могут добавляться — парсер
должен игнорировать незнакомые ключи. Ломающие изменения выйдут как `/v2/`.

---

## Эндпоинты

Во всех примерах: `BASE=https://node.example.com/api`,
`H='Authorization: Bearer hyk_...'`.

Справочник разбит на три файла по темам, чтобы ни один не превышал 500 строк.
Указатель — эндпоинт, что делает, где описан:

| Эндпоинт | Что | Файл |
|---|---|---|
| `GET /v1/health` | живость (без аутентификации) | [API-NODE.md](API-NODE.md) |
| `GET /v1/info` | сводка ноды (scope: read) | [API-NODE.md](API-NODE.md) |
| `GET /v1/tariffs` | тарифы (scope: read) | [API-NODE.md](API-NODE.md) |
| `POST /v1/tariffs` | создать или заменить тариф (scope: tariffs) | [API-NODE.md](API-NODE.md) |
| `DELETE /v1/tariffs/{code}` | удалить тариф (scope: tariffs) | [API-NODE.md](API-NODE.md) |
| `POST /v1/tariffs/{code}/move` | порядок в витрине (scope: tariffs) | [API-NODE.md](API-NODE.md) |
| `POST /v1/pricing` | режим звёздной цены (scope: tariffs) | [API-NODE.md](API-NODE.md) |
| `GET /v1/nodes` | ноды кластера (scope: read) | [API-NODE.md](API-NODE.md) |
| `GET /v1/stats` | сводка кластера (scope: read) | [API-NODE.md](API-NODE.md) |
| `GET /v1/users/{name}` | статус пользователя (scope: read) | [API-USERS.md](API-USERS.md) |
| `DELETE /v1/users/{name}/clients` | забыть приложения (scope: users) | [API-USERS.md](API-USERS.md) |
| `GET /v1/users/{name}/devices` | устройства (scope: read) | [API-USERS.md](API-USERS.md) |
| `GET /v1/users/{name}/ips` | адреса пользователя (scope: read) | [API-USERS.md](API-USERS.md) |
| `GET /v1/users/{name}/footprint` | весь след пользователя на узле (scope: read) | [API-USERS.md](API-USERS.md) |
| `DELETE /v1/users/{name}/ips` | забыть адреса (scope: users) | [API-USERS.md](API-USERS.md) |
| `POST /v1/users/{name}/erase` | стереть все следы (scope: users) | [API-USERS.md](API-USERS.md) |
| `POST /v1/users/{name}/devices` | новая ссылка-устройство (scope: users) | [API-USERS.md](API-USERS.md) |
| `DELETE /v1/users/{name}/devices/{token}` | снять ссылку (scope: users) | [API-USERS.md](API-USERS.md) |
| `GET /v1/users/{name}/subscription` | ссылки доступа (scope: read) | [API-USERS.md](API-USERS.md) |
| `GET /v1/users/by-telegram/{tg_id}` | статус по Telegram ID (scope: read) | [API-USERS.md](API-USERS.md) |
| `GET /v1/users/by-subtoken/{token}` | владелец ссылки-подписки (scope: read) | [API-USERS.md](API-USERS.md) |
| `GET /v1/telegram/{tg_id}` | есть ли привязка (scope: read) | [API-USERS.md](API-USERS.md) |
| `POST /v1/users` | создать/восстановить пользователя (scope: users) | [API-USERS.md](API-USERS.md) |
| `POST /v1/users/{name}/extend` | продлить срок (scope: users) | [API-USERS.md](API-USERS.md) |
| `POST /v1/users/{name}/enable · /disable` | вкл/выкл (scope: users) | [API-USERS.md](API-USERS.md) |
| `POST /v1/users/{name}/limits` | лимиты (scope: users) | [API-USERS.md](API-USERS.md) |
| `POST /v1/users/{name}/prefer` | первый ключ подписки (scope: users) | [API-USERS.md](API-USERS.md) |
| `POST /v1/demo` | выдать демо-профиль (scope: users) | [API-OTHER.md](API-OTHER.md) |
| `GET /v1/demo/{name}` | состояние демо (scope: read) | [API-OTHER.md](API-OTHER.md) |
| `POST /v1/demo/{name}/promote` | демо становится платным профилем (scope: users) | [API-OTHER.md](API-OTHER.md) |
| `POST /v1/demo/{name}/refresh` | то же, но пересчитав сейчас (scope: read) | [API-OTHER.md](API-OTHER.md) |
| `POST /v1/telegram/bind` | привязать Telegram (scope: telegram) | [API-OTHER.md](API-OTHER.md) |
| `POST /v1/codes/redeem` | погасить код привязки (scope: telegram) | [API-OTHER.md](API-OTHER.md) |
| `GET /v1/payments` | журнал оплат (scope: payments) | [API-OTHER.md](API-OTHER.md) |
| `POST /v1/stream/ticket` | тикет для SSE-потока онлайна (scope: read) | [API-OTHER.md](API-OTHER.md) |
| `GET /v1/stream/online` | live-статус онлайн и скорость (SSE, по тикету) | [API-OTHER.md](API-OTHER.md) |
| `POST /v1/cluster/nudge · /update` | крючки между нодами (только ноды) | [API-OTHER.md](API-OTHER.md) |

## Приём платежей Telegram Stars из своего приложения

Фулфилмент оплат уже реализован в боте менеджера (`hy2-bot.service`), и внешнее
приложение может переиспользовать его **целиком**, не написав ни строчки
логики выдачи:

1. Возьмите тарифы из `GET /v1/tariffs` (для Stars — `currency:"XTR"`).
2. Создайте инвойс через Bot API **тем же токеном бота**, что настроен в
   менеджере: `createInvoiceLink` с `currency:"XTR"`,
   `prices:[{"label":"<Название>","amount":<price>}]` (для XTR цена — как есть,
   БЕЗ умножения на 100) и **payload строго вида** `pay:<код_тарифа>:<username>`
   (`username` — имя в менеджере; если неизвестно — `-`, бот сам возьмёт
   привязку или создаст `tg<ID>`).
3. Покажите ссылку пользователю (в mini-app — `Telegram.WebApp.openInvoice`).
4. `pre_checkout_query` и `successful_payment` придут **бот-демону менеджера**
   через long-polling — он сам подтвердит оплату, создаст/продлит пользователя,
   привяжет Telegram, запишет строку в `payments.log` и уведомит клиента.
5. Приложению остаётся поллить `GET /v1/users/by-telegram/{tg_id}` до
   обновления `expiry` (обычно 1–5 секунд) и/или читать `GET /v1/payments`.

> ⚠️ **Никогда не вызывайте `setWebhook` и `getUpdates` токеном бота
> менеджера.** Установка вебхука мгновенно отключает long-polling — бот и весь
> приём платежей на ноде встанут. Внешнему приложению разрешены только методы
> вида `createInvoiceLink`, `sendMessage` и т.п., не затрагивающие доставку
> апдейтов. Если бот-демон временно лежал — Telegram хранит апдейты ~24 часа,
> оплата будет обработана после его старта.

## Ограничения и заметки

- **Согласованность.** Кластерные цифры собираются из кэшей пиров
  (`cluster_sync` 1–5 мин) — это eventually consistent данные, как и весь
  кластер менеджера.
- **Гонки с меню.** API-мутации сериализованы между собой (flock), но
  интерактивное меню менеджера блокировок не знает: не редактируйте одного
  пользователя одновременно из меню и через API.
- **Пользователи per-node.** API отвечает данными своей ноды (+кэши пиров).
  Пользователь, заведённый только на другой ноде и не синхронизированный
  кластером, ноде не виден. Для отказоустойчивости заведите ключ на второй
  ноде и переключайтесь при недоступности (`/v1/health`).
- **Тестовый запуск на фикстурах.** Демон и dispatch уважают env
  `HY2M_DATA_DIR`, `HY2M_WEBROOT`, `HY2M_CONFIG` — можно поднять API на копии
  данных, не трогая боевые файлы:
  `HY2M_DATA_DIR=/tmp/fx HY2M_WEBROOT=/tmp/fxweb python3 webapi/hy2-webapi.py`.

## Changelog

- **v1 (менеджер 3.6+)** — первый выпуск: health/info/tariffs/nodes, статусы и
  подписки пользователей, provision/extend/enable/disable/limits, привязки
  Telegram и коды, журнал оплат.
