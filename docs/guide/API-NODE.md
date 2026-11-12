# Web API: нода, тарифы, сводка

Часть справочника [API.md](API.md) — там доступ, аутентификация, формат ответов и
ошибок, полный указатель эндпоинтов. Во всех примерах:
`BASE=https://node.example.com/api`, `H='Authorization: Bearer hyk_...'`.

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
 "node_host":"node.example.com","users_active":42,"users_disabled":3,
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
([SALES.md](SALES.md)).

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
  {"name":"frankfurt","host":"node.example.com","label":"🇩🇪 Frankfurt","self":true},
  {"name":"tokyo","host":"jp.example.com","label":"tokyo","self":false}]}}
```

### GET /v1/stats — сводка кластера (scope: read)

Для витрин и статусных страниц: одним запросом — сколько человек в сети прямо
сейчас (любых: платных, бесплатных, демо) и сколько трафика прокачано за всё
время всеми пользователями.

```json
{"ok":true,"data":{"online":12,"traffic_bytes":184739201553}}
```

`online` здесь — **подключённые к любой ноде** (колонка «online» из своей
`self.stats` и кэшей пиров, протухшие кэши не читаются), а не «двигают трафик
прямо сейчас», как в `GET /v1/online`. Витрине нужен человек с включённым
клиентом, даже если он ничего не качает; счёт по именам, поэтому клиент,
висящий на всех нодах подписки сразу, — это один человек. `traffic_bytes` —
сумма tx+rx по локальным счётчикам и кэшам пиров; счётчики кумулятивны, но
удалённый пользователь уносит свои байты с собой (это витринная цифра, а не
бухгалтерия).
