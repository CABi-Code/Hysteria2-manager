# Проблемы: Мини-апп и веб-кабинет

`/opt/cibpn-webapp` — потребитель Web API менеджера. Отдельный репозиторий, но
реестр общий: номера `P-NN` сквозные, иначе одна и та же проблема получает два
номера с двух сторон. Проблемы стыка «кто чем владеет» — в
[BILLING.md](BILLING.md#p-09).

Реестр и правила ведения — [README.md](README.md).

| # | Проблема | Статус |
|:--:|---|:--:|
| [P-26](#p-26) | Неавторизованный запрос к `/api/*` отдаёт 500 и стек вместо 401 | ✅ |
| [P-27](#p-27) | Прод работает как `APP_ENV=local` с `APP_DEBUG=true` | ✅ |
| [P-28](#p-28) | Резервный провайдер курсов мёртв: цепочка фактически из одного | 🟡 |
| [P-29](#p-29) | `topup:watch-ton` рапортует о зачислении, которого не было | ✅ |
| [P-30](#p-30) | `laravel.log` без ротации, туда же пишут прогоны тестов | ✅ |
| [P-40](#p-40) | Caddy резал PUT и DELETE: админка не сохранялась, автопродление не менялось | ✅ |

---

<a id="p-26"></a>
## P-26 ✅ Неавторизованный запрос к `/api/*` отдаёт 500 и стек вместо 401

Воспроизведено на боевом хосте 2026-08-02:

```
$ curl -sk --resolve webapp.cibpn.online:443:127.0.0.1 https://webapp.cibpn.online/api/me
{"message":"Route [login] not defined.","exception":"…RouteNotFoundException",
 "file":"…/Illuminate/Routing/UrlGenerator.php","line":540,"trace":[…]}
```

500 приходил на **любой** роут под `auth:sanctum` без токена, на обоих хостах
(`webapp.` и `web.`). В логе — 30 июля, 4 раза.

`bootstrap/app.php` приводит `AuthenticationException` на `api/*` к
`{"ok":false,"error":"unauthenticated"}` с кодом 401, но до этого рендера дело не
доходило. `Illuminate\Foundation\Configuration\ApplicationBuilder:291` по
умолчанию ставит `redirectGuestsTo(fn () => route('login'))`, а роута с именем
`login` у нас нет — страница `/login` существует только как SPA catch-all
`routes/web.php:87`, без имени. `Authenticate::unauthenticated()` зовёт этот
колбэк ещё при сборке исключения, и наружу летит `RouteNotFoundException` —
другой класс, обработчик `api/*` его не ловит.

**Границы, установленные проверкой:** падало только когда
`$request->expectsJson()` ложно (`Authenticate.php:104`). Штатные клиенты шлют
`Accept: application/json` и получали корректный 401 — значит single-flight
ротация refresh-токена (docs/AUTH-SESSION.md) **не** ломалась, а конвенция
`{"ok":false,"error":…}` нарушалась не «на самом частом сценарии», а на прямых
заходах из браузера, курлом и сканерами. Реальный вред — вместе с
[P-27](#p-27): такому гостю отдавался стек с путями и внутренностями
фреймворка. Секретов в теле именно этого ответа не было (проверено `grep` по
`APP_KEY|MANAGER_API_KEY|hyk_|base64:` — 0 совпадений), но исключение другого
типа отдало бы больше.

**Закрыто** (`cibpn-webapp` `e9c5cdb`): одна строка
`$middleware->redirectGuestsTo('/login')` в `bootstrap/app.php` — гость уходит
на существующую страницу, а на `api/*` раньше редиректа срабатывает наш рендер
и отдаёт 401. Проверено на fin2: `/api/me` на обоих хостах с `Accept` `*/*`,
`text/html` и `application/json` — везде `401 {"ok":false,"error":"unauthenticated"}`.
Тесты 170/170.

<a id="p-27"></a>
## P-27 ✅ Прод работает как `APP_ENV=local` с `APP_DEBUG=true`

`/opt/cibpn-webapp/.env` на fin2:

```
APP_ENV=local
APP_DEBUG=true
LOG_LEVEL=debug
APP_URL=https://webapp.cibpn.online
```

И это не «забыли пересобрать кэш» — значения именно такие в
`bootstrap/cache/config.php` (проверено чтением кэша), то есть отдаёт их именно
FPM. `README.md` в шаге 4 предписывает для прода `APP_ENV=production` +
`APP_DEBUG=false`.

При `APP_DEBUG=true` любая 500-ка уходит клиенту вместе со стеком, а на путях с
БД — с текстом запроса. Ближайший живой пример — [P-26](#p-26). `LOG_LEVEL=debug`
дополнительно раздувает лог ([P-30](#p-30)).

**Закрыто** 2026-08-02: в `.env` выставлены `APP_ENV=production` и
`APP_DEBUG=false`, затем `config:cache` + `reload php8.3-fpm`. Проверено чтением
`bootstrap/cache/config.php` (`env=production debug=false`) — отдаёт именно эти
значения FPM, а не только файл.

Кода `.env` не касается: `grep` по `app/`, `config/`, `routes/`, `resources/views/`
не нашёл ни одного `environment()`/`isLocal()`/`isProduction()` — единственный
потребитель `APP_ENV` это `config/app.php:29`. `public/hot` отсутствует, ассеты
идут из собранного `public/build`. Смоук после переключения: лендинг
`cibpn.online`, `webapp.cibpn.online/`, `/up`, `/login` на обоих хостах — 200;
тесты 170/170 (гоняли по правилу «сначала `config:clear`»); боевая sqlite цела
(11 юзеров, 77 транзакций, 578395 коп. — как до прогона).

`LOG_LEVEL=debug` **оставлен** и переехал в [P-30](#p-30): это про шум в логе, а
не про утечку наружу.

<a id="p-28"></a>
## P-28 🟡 Резервный провайдер курсов мёртв: цепочка фактически из одного

`docs/RATES.md` обещает: «Оба отдают ₽ напрямую одним запросом (**без ключа**,
`retry(2)`), поэтому **не зависим от одного сайта**». Проверено 2026-08-02:

```
cryptocompare: 401       (min-api теперь требует ключ)
coingecko:     {"the-open-network":{"rub":110.21},"tether":{"rub":79.21}}
```

`RatesService::fetchCryptoCompare()` (`app/Services/RatesService.php:200`) ходит
на `min-api.cryptocompare.com` без `api_key` — там это больше не бесплатно.
Резерв не срабатывает **никогда**, цепочка вырождается в один CoinGecko, а он на
бесплатном тарифе регулярно отдаёт 429. В логе за 1 августа:

```
rates provider failed {"provider":"coingecko","error":"coingecko http 429"}
rates provider failed {"provider":"cryptocompare","error":"cryptocompare http 401"}
rates: all providers down and last-good too old, using manual
```

— дважды за сутки долетело до ручного курса. Тот же RATES.md отмечает, что
падение на далёкий от рынка ручной курс «раньше приводило к утечке денег»: путь
считается опасным, и он снова достижим, потому что защиты от него (второй
провайдер) на деле нет.

Денег пока не потеряли: ручные курсы в админке (TON 115, USDT 78) близки к рынку
(110.21 / 79.21). Но следит за этим только человек, который вовремя посмотрел в
лог.

Варианты: ключ CryptoCompare в настройки, либо замена резерва на провайдера, всё
ещё бесплатного без ключа. Точка расширения описана в RATES.md («Новый
провайдер» — ветка в `fetchFrom()` + имя в `providerChain()`).

Отрицательный `rates.markup_percent` (в БД `-3`) — **не** проблема: RATES.md
описывает это как бонус.

<a id="p-29"></a>
## P-29 ✅ `topup:watch-ton` рапортует о зачислении, которого не было

Каждый запуск печатает `credited 1 ton/usdt topup(s)`, даже когда не зачислил
ничего. Проверено двумя прогонами подряд: `balance_transactions` как было
77 строк / 578395 коп., так и осталось.

`TonWatcher::processTransfer()` (`app/Services/TonWatcher.php:55`) намеренно
возвращает `true` и для уже зачисленной транзакции («или уже было по этому tx»),
а `poll()` считает эти `true` как `$credited++`. Сама идемпотентность в порядке —
врёт только счётчик, но именно по нему судят, работает ли приём TON.

Рядом: крон `www-data` шлёт вывод `schedule:run` в `/dev/null`, поэтому
периодические падения `topup:watch-ton` и `topup:watch-yoomoney` с exit 1
(25, 26 июля, 1 августа) видны только строкой в `laravel.log`. Само чинится —
крон раз в минуту, — но узнать о серии сбоев можно лишь случайно.

**Закрыто** 2026-08-03: `processTransfer()` возвращает `$tx->wasRecentlyCreated`
вместо безусловного `true` — повторный опрос той же транзакции даёт `false`, и
`poll()` его не считает. `BalanceService::apply()` на уже применённый
`idempotency_key` возвращает существующую строку (`wasRecentlyCreated=false`),
на свежем зачислении — только что созданную. Идемпотентности не касались.
Проверка в `TopupTonWatcherTest::test_repeated_poll_is_idempotent`: первый
`poll()` = 1, второй = 0. Тесты 180/180, боевая sqlite цела (11 юзеров, 77
транзакций, 578395 коп.).

У ЮMoney такого нет: `YooMoneyService::confirm()` отдаёт отдельный статус
`duplicate`, и команда его не считает.

Про крон в `/dev/null` отдельно ничего не делали: падения и так пишутся в
`laravel.log`, который после [P-30](#p-30) ротируется.

<a id="p-30"></a>
## P-30 ✅ `laravel.log` без ротации, туда же пишут прогоны тестов

Один файл, 1.1 МБ на 2026-08-02, стандартный канал `single`. Плюс в нём вперемешку
с боевыми записями лежат прогоны тестов (`testing.*` — 200 строк за 25 июля,
44 за 1 августа), потому что тесты пишут в тот же файл.

Мешает разбору инцидентов: приходится отделять `local.*` от `testing.*` руками,
а `LOG_LEVEL=debug` ([P-27](#p-27)) добавляет шума. Канал `daily` в
`config/logging.php` — одна правка `.env`.

**Закрыто** 2026-08-03, три строки конфига:

- `.env`: `LOG_STACK=daily` (канал `daily` уже был описан в `config/logging.php`,
  `LOG_DAILY_DAYS` по умолчанию 14) и `LOG_LEVEL=info` вместо `debug`;
- `phpunit.xml`: `LOG_CHANNEL=null` — прогоны тестов больше не пишут в боевой лог.

Затем `config:cache` + `reload php8.3-fpm`. Проверено чтением
`bootstrap/cache/config.php` (`stack=daily`, `level=info`) и записью в лог: файл
теперь `storage/logs/laravel-YYYY-MM-DD.log`. Старый `laravel.log` (1.2 МБ)
оставлен как есть — в него больше не пишут, это архив инцидентов до этой даты.

Подводный камень: дневной файл создаёт тот, кто пишет первым. Если это `artisan`
из-под `root`, файл будет root-овым и FPM/крон (`www-data`) в него не запишут —
`chown www-data:www-data storage/logs/laravel-*.log`.

<a id="p-40"></a>
## P-40 ✅ Caddy резал PUT и DELETE: админка не сохранялась

Сохранение настроек в админке отвечало «Не удалось сохранить, попробуйте позже»
и не оставляло следа: ни исключения в `laravel.log`, ни строки в аудите — потому
что запрос **до Laravel не доходил**.

Сниппет `hardening` (`/etc/caddy/extra/00-common.caddy`) пропускал только
`GET HEAD POST OPTIONS`, остальное отдавал пустым 405. Под нож попали три живых
роута:

| Роут | Что не работало |
|---|---|
| `PUT /api/admin/settings` | любое сохранение настроек, включая Telegram Stars |
| `PUT /api/me/autorenew` | переключение автопродления у клиента |
| `DELETE /api/web-access/{id}` | отзыв привязанного браузера |

Проверено курлом на боевом хосте: у 405 от Caddy `content-length: 0`, у 405 от
Laravel — тело `{"ok":false,"error":"http_405"}`. Это и отличает «метод не дошёл»
от «метода нет у роута».

**Закрыто** 2026-08-03: `PUT` и `DELETE` добавлены в список разрешённых методов,
`caddy validate` + `reload`. После правки `PUT /api/admin/settings` без токена
отвечает `401 {"ok":false,"error":"unauthenticated"}` (то есть доходит), а с
токеном админа сохраняет и возвращает новые настройки. `PATCH` по-прежнему
режется — приложение его не использует.

Правило: **завёл роут с новым HTTP-методом — проверь список в сниппете**
(`cibpn-webapp/docs/PERIMETER.md`). Периметр молча съедает метод, которого нет в
списке, и это выглядит как баг приложения.
