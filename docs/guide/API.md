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

Во всех примерах: `BASE=https://vpn.example.com/api`,
`H='Authorization: Bearer hyk_...'`.

### GET /v1/health — живость (без аутентификации)

```bash
curl "$BASE/v1/health"
# {"ok":true,"data":{"version":"3.6"}}
```

### GET /v1/info — сводка ноды (scope: read)

```bash
curl -H "$H" "$BASE/v1/info"
```
```json
{"ok":true,"data":{"manager_version":"3.6","node_name":"frankfurt",
 "node_host":"vpn.example.com","users_active":42,"users_disabled":3,
 "cluster_peers":2}}
```

### GET /v1/tariffs — тарифы (scope: read)

Отдаёт `tariffs.conf`. `currency:"XTR"` — Telegram Stars (цена = число звёзд),
иначе фиатная валюта платёжного провайдера в основных единицах. Тариф может
иметь НЕСКОЛЬКО цен в разных валютах — они в массиве `prices[]`; поля `price`/
`currency` дублируют первую (основную) цену для обратной совместимости.

Строка тарифа: `код|название|дни|устройства|цены|валюты|опции`. **7-е поле
опциональное** — конструктор `k=v;k=v`: `free=1` (тариф бесплатный, на него
переводят по истечении платного), `wk=`/`mo=` (лимиты трафика на окно 7 и 30
суток), `start=online|paid` (с чего окна отсчитывать). В API это `free` и
`traffic_limits`. Кто читает строку руками — обязан прочитать и 7-е поле:
`IFS='|' read -r code title days devices price cur opts`, иначе опции уедут в
валюту (ловили в редакторе тарифов 2026-07-22). В меню это пункт
«Редактировать тариф» — вопросы про бесплатность и лимиты идут после устройств.

Блок `pricing` — режим звёздной цены ноды (`fixed` — цена XTR из тарифа,
`rate` — считается из рублёвой по курсу `rub_per_star`, округление вверх).
**Цену пересчитывать не нужно:** в `prices[]` она уже посчитана по режиму, в
`rate` звёздная цена есть даже у тарифа, где её не задавали. Режим и курс
отдаются, чтобы их могла показать и поправить внешняя админка. Подробнее —
[TARIFF-PRICING.md](TARIFF-PRICING.md).

```bash
curl -H "$H" "$BASE/v1/tariffs"
```
```json
{"ok":true,"data":{"tariffs":[
  {"code":"m1","title":"Месяц","days":30,"devices":3,"price":"100","currency":"XTR",
   "prices":[{"currency":"XTR","price":"100"},{"currency":"RUB","price":"199"}]}],
  "pricing":{"stars_mode":"fixed","rub_per_star":1.0}}}
```

### POST /v1/tariffs — создать или заменить тариф (scope: tariffs)

Upsert по коду: существующий тариф правится **на месте** (позиция в витрине
сохраняется), новый дописывается в конец. Так внешняя админка правит каталог,
не заводя своей копии тарифов — менеджер остаётся источником правды по продаже
([design/SALES/](../design/SALES/README.md)).

Тело: `code`, `title`, `days`, `devices`, цены (`prices[{currency,price}]` либо
одиночные `price`+`currency`) и необязательное `options` — 7-е поле
`«free=1;wk=3G;mo=10G;start=online»`. **`options` передаются полностью:** не
прислали — значит опций нет (иначе снять лимиты снаружи было бы нельзя).
Переименование кода не поддерживается — удалите и создайте заново.

```bash
curl -X POST -H "$H" -H 'Content-Type: application/json' "$BASE/v1/tariffs" \
  -d '{"code":"m1","title":"Месяц","days":30,"devices":3,
       "prices":[{"currency":"XTR","price":"100"},{"currency":"RUB","price":"199"}]}'
```
```json
{"ok":true,"data":{"tariff":{"code":"m1","title":"Месяц","days":30,"devices":3,
  "price":"100","currency":"XTR","prices":[{"currency":"XTR","price":"100"},
  {"currency":"RUB","price":"199"}],"free":false,
  "traffic_limits":{"week_bytes":0,"month_bytes":0},"period_start":"paid"}}}
```

Ошибки: `400 invalid_code|invalid_title|invalid_days|invalid_devices|invalid_price|
invalid_currency|duplicate_currency|invalid_options`.

### DELETE /v1/tariffs/{code} — удалить тариф (scope: tariffs)

`404 tariff_not_found`, если тарифа нет. Купленный доступ не трогается —
удаляется только позиция каталога.

```json
{"ok":true,"data":{"code":"m1","deleted":true}}
```

### POST /v1/tariffs/{code}/move — порядок в витрине (scope: tariffs)

Тело: `{"direction":"up"}`, `{"direction":"down"}` или `{"position":1}` (с 1).
Отдаёт весь каталог после перестановки. `409 tariff_at_edge` — тариф уже с краю.

### POST /v1/pricing — режим звёздной цены (scope: tariffs)

Тело: `stars_mode` (`fixed`|`rate`) и `rub_per_star` (для `rate`). Смысл режимов
— [TARIFF-PRICING.md](TARIFF-PRICING.md). Не переданное поле остаётся прежним.

```bash
curl -X POST -H "$H" -H 'Content-Type: application/json' "$BASE/v1/pricing" \
  -d '{"stars_mode":"rate","rub_per_star":1.5}'
```
```json
{"ok":true,"data":{"pricing":{"stars_mode":"rate","rub_per_star":1.5}}}
```

### GET /v1/nodes — ноды кластера (scope: read)

```json
{"ok":true,"data":{"nodes":[
  {"name":"frankfurt","host":"vpn.example.com","label":"🇩🇪 Frankfurt","self":true},
  {"name":"tokyo","host":"jp.example.com","label":"tokyo","self":false}]}}
```

### GET /v1/users/{name} — статус пользователя (scope: read)

Трафик и онлайн — **по всему кластеру** (локальные данные + кэши пиров,
свежесть кэшей 1–5 мин). `expiry:null` = бессрочный. `days_left` может быть
отрицательным (просрочен, но ещё не отключён кроном).

`online` — «реально пользуется прямо сейчас»: считается по движению байтовых
счётчиков (скорость ≥ `HY2M_ONLINE_RATE_BPS`, дефолт 2 КБ/с, окно
`HY2M_ONLINE_SAMPLE_SEC`, дефолт 15 с), поэтому пинги клиента к разным
протоколам его не накручивают. `online_connections` — сырое число соединений
всех движков (Hysteria/Xray/TUIC), **включая пинги**; оставлено для
совместимости, для индикатора «онлайн» используйте `online`. Детали:
[docs/guide/ONLINE.md](ONLINE.md).

```bash
curl -H "$H" "$BASE/v1/users/alice"
```
```json
{"ok":true,"data":{
  "username":"alice","status":"active",
  "expiry":"2026-08-15","days_left":30,"unlimited":false,
  "limits":{"devices":3,"hardcheck":false,"rate_mbps":200},
  "traffic":{"tx_bytes":1000500,"rx_bytes":5000600,"total_bytes":6001100},
  "online_connections":2,"online":true,"devices_seen":2}}
```

Поле `free` — `null` у того, кто не на бесплатном тарифе. Состояние демо-ключа
живёт отдельно, см. `GET /v1/demo/{name}`.

### GET /v1/users/{name}/subscription — ссылки доступа (scope: read)

`subscription_url` — основная ссылка-подписка (все серверы кластера,
автообновление в клиенте). Прямые ключи (для клиентов без подписок) отдаются
двумя видами:

- `links` — плоский список строк-URI; теперь по **всем протоколам и всем нодам
  кластера** (не только `hysteria2://` этой ноды), тот же контент, что в подписке;
- `direct_links` — те же ключи в разобранном виде: `{url, protocol,
  protocol_name, host, port, label}`. `host`/`port` — для группировки по серверам,
  `label` — подпись ключа (метка ноды из `SUB_TAG_TMPL`), `protocol` — схема URI
  (`hysteria2`/`vless`/`ss`/`tuic`/`trojan`).

```json
{"ok":true,"data":{"username":"alice",
  "subscription_url":"https://vpn.example.com/sub/tok...",
  "subscription_urls":["https://vpn.example.com/sub/tok..."],
  "links":["hysteria2://alice:pass@fin2:443/?...#Фин-2 | HY2",
           "vless://uuid@fin2:8443?...#Фин-2 | VLESS", "..."],
  "direct_links":[
    {"url":"hysteria2://...","protocol":"hysteria2","protocol_name":"Hysteria2",
     "host":"fin2.example.com","port":"443","label":"Фин-2 | HY2"},
    {"url":"vless://...","protocol":"vless","protocol_name":"VLESS",
     "host":"fin2.example.com","port":"8443","label":"Фин-2 | VLESS"}]}}
```

> Содержимое `data` включает секреты (токен подписки). Не логируйте его и не
> показывайте чужим пользователям.

### GET /v1/users/by-telegram/{tg_id} — статус по Telegram ID (scope: read)

То же тело, что `/v1/users/{name}`. `404 not_linked` — аккаунт не привязан.

### GET /v1/telegram/{tg_id} — есть ли привязка (scope: read)

```json
{"ok":true,"data":{"tg_id":"123456789","bound":true,"username":"alice"}}
```

### POST /v1/users — создать/восстановить пользователя (scope: users)

Идемпотентен: существующему активному вернёт его текущий пароль
(`created:false`), отключённого — включит.

**Новый пользователь сразу становится кластерным**: попадает в ростер и в
`cluster_state`, публикуется пирам, и те заводят его у себя на своей
синхронизации (~5 мин). Раньше это была ручная кнопка в меню, и каждый профиль,
созданный через API или бота, оставался на одной ноде — подписка собирала ключи
только с неё. Обход пиров при этом НЕ делается: он ничего не ускорит (забирают
данные всё равно они сами), а ответ клиенту задержит.

Существующему пользователю ручка отвечает мгновенно; создание нового занимает
~15–20 с (перегенерация конфигов протоколов и рестарт Xray/sing-box), это
нормально — закладывайте таймаут с запасом.

```bash
curl -X POST -H "$H" -H 'Content-Type: application/json' \
     -d '{"username":"alice"}' "$BASE/v1/users"
```
```json
{"ok":true,"data":{"username":"alice","created":true,
  "password":"...","subscription_url":"https://vpn.example.com/sub/..."}}
```

### POST /v1/users/{name}/extend — продлить срок (scope: users)

`days`: целое 1..3650. Продление от максимума(сегодня, текущий срок) — та же
логика, что у оплат бота.

```bash
curl -X POST -H "$H" -H 'Content-Type: application/json' \
     -d '{"days":30}' "$BASE/v1/users/alice/extend"
# {"ok":true,"data":{"username":"alice","expiry":"2026-09-14","days_left":60}}
```

### POST /v1/users/{name}/enable · /disable — вкл/выкл (scope: users)

Идемпотентны. Отключение применяется мгновенно (пользователь кикается со всех
активных сессий), подписка пересобирается пустой.

```bash
curl -X POST -H "$H" "$BASE/v1/users/alice/disable"
# {"ok":true,"data":{"username":"alice","status":"disabled"}}
```

### POST /v1/users/{name}/limits — лимиты (scope: users)

`devices` (0 = глобальный лимит пула), `rate_mbps` (0 = без личного тарифа
скорости). Непереданные поля сохраняют текущее значение; `hardcheck` через API
не меняется (только в меню).

```bash
curl -X POST -H "$H" -H 'Content-Type: application/json' \
     -d '{"devices":5,"rate_mbps":300}' "$BASE/v1/users/alice/limits"
```

### POST /v1/demo — выдать демо-профиль (scope: users)

Рабочий доступ гостю **до регистрации и оплаты** (idea 13 веб-аппа): обычный
пользователь, но закапанный сразу по скорости, трафику и сроку, и живущий
только на этой ноде. Кого пускать, решает веб-апп — менеджер просто выдаёт.
Ответ: `username`, `subscription_url`, `expires_at`, `cap_bytes`, `rate_mbps`.

### GET /v1/demo/{name} — состояние демо (scope: read)

```json
{"ok":true,"data":{
  "username":"demo-0tnqekep","state":"active","alive":true,"online":false,
  "created_at":1784741346,"expires_at":1784744946,
  "used_bytes":1048576,"limit_bytes":524288000,"left_bytes":523239424,
  "refreshed":false}}
```

Отдельно от `/v1/users/{name}` намеренно: когда лимит исчерпан или время вышло,
**пользователя уже нет** (доступ отбирают целиком), а строка в `demos.db` живёт
ещё сутки — гостю надо показать, что именно случилось. `alive` — жив ли ещё
доступ; `state` — `active`/`expired`; `used_bytes` считается ровно как в
`demo_tick` (трафик минус база на момент выдачи), у отобранного — как записано
в строке.

### POST /v1/demo/{name}/refresh — то же, но пересчитав сейчас (scope: read)

Перед сборкой ответа менеджер пересчитывает трафик и активность
(`collect_activity`), не дожидаясь минутного тика: для живых индикаторов —
шкала лимита и «в сети» на публичной главной обновляются в такт миганию.

Ничего не меняет, поэтому scope `read`. Пересчёт **глобальный, с кулдауном**
`TRAFFIC_REFRESH_MIN_SEC` (по умолчанию 3 с) и неблокирующим локом: недавно
считали или занята другая мутация — мгновенный ответ с `refreshed:false`,
данные всё равно максимально свежие. Частый опрос упирается в кулдаун ноды:
десяти спросившим подряд хватает одного прогона. Реальный пересчёт стоит
~1–3 с (доминируют Xray statsquery и TUIC), поэтому ниже пары секунд кулдаун
опускать не стоит.

### POST /v1/telegram/bind — привязать Telegram (scope: telegram)

`409 already_bound`, если `tg_id` уже привязан к другому пользователю.

```bash
curl -X POST -H "$H" -H 'Content-Type: application/json' \
     -d '{"tg_id":"123456789","username":"alice"}' "$BASE/v1/telegram/bind"
```

### POST /v1/codes/redeem — погасить код привязки (scope: telegram)

Одноразовые коды выдаёт админ (`/code` в боте или меню). Код **гасится при
успехе**; с `tg_id` — сразу привязывает.

```bash
curl -X POST -H "$H" -H 'Content-Type: application/json' \
     -d '{"code":"AbCd1234","tg_id":"123456789"}' "$BASE/v1/codes/redeem"
# {"ok":true,"data":{"username":"alice","bound":true}}
```

### GET /v1/payments — журнал оплат (scope: payments)

Курсорная пагинация по `charge_id` (уникален у Telegram; `datetime` не
монотонен — не используйте его как курсор). Параметры: `since_charge`
(отдать записи ПОСЛЕ этого charge_id), `limit` (default 200, max 500).
Храните `next_since_charge` и передавайте его в следующий запрос — так
строится надёжный поллинг новых оплат (например, для реферальных бонусов).

> **Неизвестный курсор.** Если переданный `since_charge` в журнале не найден
> (например, лог ротирован или курсор с другой ноды), API отдаёт журнал
> **с самого начала**, а не ошибку. Клиент обязан дедуплицировать записи по
> `charge_id` на своей стороне — иначе после ротации лога оплаты обработаются
> повторно.

```bash
curl -H "$H" "$BASE/v1/payments?since_charge=ch_001&limit=100"
```
```json
{"ok":true,"data":{"payments":[
  {"paid_at":"2026-07-02 11:00:00","tg_id":"222","username":"bob",
   "tariff_code":"m1","amount":"100","currency":"XTR","charge_id":"ch_002"}],
 "next_since_charge":"ch_002"}}
```

### POST /v1/stream/ticket — тикет для SSE-потока онлайна (scope: read)

Выдаёт короткоживущий тикет для потока статуса онлайн. Нужен, потому что браузер
не может слать `Authorization` в `EventSource` — сервер (напр. Laravel) берёт
тикет по Bearer-ключу и передаёт его в браузер. Тикет подписан секретом процесса
webapi (ротация на рестарте), TTL 1800с, привязан к username.

```bash
curl -H "$H" -X POST "$BASE/v1/stream/ticket" -d '{"username":"alice"}'
```
```json
{"ok":true,"data":{"ticket":"<opaque>","expires_in":1800}}
```

### GET /v1/stream/online — live-статус онлайн и скорость (SSE, по тикету)

`text/event-stream`. Аутентификация — параметром `?ticket=` (не Bearer). Шлёт
`data: {"online": bool, "bps": int, "samples": [{"t": ms, "bps": int}, …]}` при
подключении и при КАЖДОМ изменении, плюс keepalive-комментарии `: ping`.
Семантика `online` — «реально пользуется сейчас» (см. `online` в статусе
пользователя). `bps` — последняя текущая скорость в байтах/с по ВСЕМУ кластеру
(локальный `rates.dat` + `peers/*.rates`).

`samples` (идея 17) — ряд последних выборок скорости `{t: мс-эпоха, bps}` за
окно наблюдения (по возрастанию `t`), чтобы клиент проигрывал стрелку спидометра
по таймлайну в реальном времени, а не телепортировал её на новое число. Каждая
нода пересчитывает свою скорость раз в `RATES_TICK_SEC` (5 с), межнодовые
значения свежее ~15 с. Окно ограничено `HY2M_STREAM_SAMPLES_WINDOW` (дефолт 8).
Клиент дедупит выборки по `t` (окно отдаётся целиком при каждом пуше) и держит
одно соединение; при разрыве берёт свежий тикет и переоткрывает. Старые клиенты
читают `bps`, игнорируя `samples`.

`nodes` — разбивка по нодам, через которые юзер СЕЙЧАС гонит трафик:
`[{label, conns, down, up}]`. `label` — метка ноды (с флагом, напр. `🇩🇪 Герм-1`;
NODE_LABEL по кластеру не синхронизируется, поэтому каждая нода печатает свою метку
в заголовок своего `rates` — до обновления пира вместо метки его hostname). `down`/`up` —
скорость байт/с раздельно (↓ скачивание / ↑ отдача), живая (rates, 5 с). `conns` —
число подключений на этой ноде, из минутной cluster-статистики (`HY2M_STATS_MAX_AGE`,
дефолт 180 с), меняется медленно. Нода в списке, если есть трафик ИЛИ подключения;
сортировка по сумме скорости.

```bash
curl -N "$BASE/v1/stream/online?ticket=<opaque>"
# data: {"online": false, "bps": 0, "samples": [{"t": 1737630000000, "bps": 0}], "nodes": []}
# data: {"online": true, "bps": 1240576, "samples": [{"t": 1737630010000, "bps": 1240576}], "nodes": [{"label": "🇩🇪 Герм-1", "conns": 2, "down": 155000, "up": 2400}]}
```

---

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
