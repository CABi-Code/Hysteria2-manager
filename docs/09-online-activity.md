# Онлайн-статус: мультипротокольная активность + live-пуш (SSE)

## Зачем

«Онлайн» в веб-аппе должен значить «юзер реально пользуется VPN прямо сейчас», а
не «есть открытый сокет». Клиент для замера латентности пингует все протоколы
сразу, и каждый движок (Hysteria/Xray/TUIC) видит пинг как «соединение» —
считать онлайн по числу соединений значит множить один пинг на число протоколов.

Устойчивый признак «пользуется, а не пингует» — **движение байтовых счётчиков**:
пинг двигает их на единицы КБ за интервал, реальное использование — на порядки
больше. Этот признак уже считает менеджер (`collect_activity`, флаг `active`).

## Признак `active` (менеджер, все протоколы)

`collect_activity` (`lib/traffic.sh`, крон `--online-sync`, раз в минуту) сводит
КУМУЛЯТИВНЫЙ трафик per-user по ВСЕМ протоколам и по дельте с прошлой минутой
считает скорость; если она ≥ `ACTIVITY_THRESHOLD_BPS` (дефолт 4096 Б/с) — юзер
`active=1`. Источники кумулятива:

- **Hysteria** — `api_get "/traffic"`.
- **Xray** (VLESS/SS/Trojan) — `xray api statsquery -pattern "user>>>"` (без reset).
- **TUIC** (sing-box) — best-effort по `sourceIP`. sing-box (clash_api) НЕ отдаёт
  `metadata.user` (проверено эмпирически), поэтому сумму `upload+download` по
  соединению атрибутируем на юзера с самым свежим `last_seen` на этом IP из
  `ips.dat` (`proto_tuic_activity_lines`). На общем CGNAT-IP изредка попадёт не
  тот юзер — для индикатора онлайн приемлемо; в трафик/квоты это НЕ идёт. Точный
  per-user TUIC невозможен (нет user в API + общие CGNAT-IP), см.
  памятку tuic-no-per-user-attribution.

Xray и TUIC даёт `proto_activity_cum_lines` (`lib/protocols.sh`); всё
складывается в один кумулятив (`awk`). До этой правки активность считалась только
по Hysteria — TUIC/Xray-юзеры показывались оффлайн при реальном использовании.

`active`/`active_since` пишутся в `activity.dat` и уже публикуются в
`peers/*.stats` (поле 7) через `publish_stats` → синхронизируются по кластеру
каждые ~4с (live-механизм, `lib/cluster.sh`). Так статус виден и для юзера на
другой ноде.

Fail-safe: если Hysteria API отдал пусто — `collect_activity` выходит, НЕ трогая
`activity.dat` (без ложных обрезаний). Значит доп-протоколы считаются, только
когда Hysteria API здоров (обычный случай). На первом тике после апгрейда
кумулятив разово подскакивает (в prev лежал Hysteria-only) — один ложный
active-тик, самокорректируется на следующей минуте.

## webapi: поле `online`

`user_payload.online` (`webapi/hy2-webapi.py`) = `is_online(user)`:
- `user_active_raw` читает готовый `active` локально (`activity.dat`) ИЛИ по
  кластеру (`peers/*.stats`, поле индекс 6) — **без пересчёта**, нагрузку не
  добавляем.
- **Гистерезис**: держим «онлайн» ещё `ONLINE_GRACE_SEC` (дефолт 90с) после
  последнего наблюдения `active=1` — статус не мигает на минутных провалах
  (пауза видео) и джиттере синка. Состояние — в памяти демона.

`online_connections` (сырое число соединений, включая пинги) оставлено для
совместимости API, но веб-аппом не показывается.

## Live-пуш (SSE, без поллинга)

Дашборд получает статус живьём одним постоянным соединением:

- **webapi** `GET /v1/stream/online?ticket=…` → `text/event-stream`, шлёт
  `data: {"online": bool, "bps": int}` при изменении + keepalive `: ping`. Общий
  watcher-тред (`_stream_watcher`) раз в `STREAM_POLL_SEC` (5с) пересчитывает
  `is_online` и `user_rate_bps` ТОЛЬКО для юзеров с активными подписчиками и
  будит хендлеры — O(подписанных), не на клиента.
- **Скорость (`bps`)**: байт/с по ВСЕМУ кластеру = локальный `rates.dat` +
  сумма `peers/*.rates`. Считает отдельный тик (см. ниже), а не минутный
  `collect_activity`. Файл старше `HY2M_RATES_MAX_AGE` (60 с) считается
  протухшим и даёт 0 — застывшая скорость хуже честного нуля. Мини-апп рисует
  по этому значению спидометр (см. `cibpn-webapp/docs/DASHBOARD.md`).

## Тик скорости (спидометр, каждые 15 с)

Онлайн — булев и меняется редко, скорость — число и должна быть живой, поэтому
у неё свой контур:

- `collect_rates` (`lib/traffic.sh`): один опрос кумулятива всех протоколов
  (Hysteria `/traffic` без `clear=1` + `proto_activity_cum_lines`) и дельта с
  прошлым снимком ОДНИМ проходом awk. В отличие от `collect_activity` здесь нет
  grep на каждого юзера, поэтому цена тика почти не зависит от размера базы —
  это цена опроса API протоколов. Счётчик уменьшился (30-минутный `?clear=1`,
  закрылись TUIC-соединения) → пишем 0, а не дельту от нуля: фантомный всплеск
  на спидометре заметнее, чем один пропущенный тик раз в полчаса.
- Файлы: `rates.dat` «user|bps|ts», `rates_prev.dat` «user|cum|ts».
- `publish_rates` кладёт `rates.dat` в `$WEBROOT/cluster/rates` (Caddy отдаёт
  его пирам за `X-Cluster-Auth`, как и остальную `/cluster/*` статику),
  `cluster_rates_sync` параллельно стягивает то же самое с пиров в
  `peers/<node>.rates`. Недоступный пир → пустой файл (= 0), а не залипшая
  скорость.
- Запускает всё это `hy2-manager.sh --rates-tick` под `flock -n` (тик не
  наслаивается на тик) из systemd-таймера `hy2-rates.timer`. Таймер ставится
  сам — `rates_timer_ensure` вызывается из `--online-sync` и при интерактивном
  старте, поэтому после обновления ноды делать ничего не нужно.
- **Цена**: ~0.5 c wall / ~0.45 c CPU на тик, при 15 с это ~3% одного ядра на
  ноду, круглосуточно. Каденс — `RATES_TICK_SEC` (`lib/config.sh`); при
  изменении `rates_timer_ensure` перегенерирует юнит сам.
- **Свежесть**: своя нода ≤15 с, пир ≤30 с (его тик + наш забор). Спидометр
  мини-аппа сглаживает разрыв анимацией.
- **Тикет**: браузер не хранит ключ менеджера. Laravel (`GET /api/stream-ticket`,
  auth:sanctum) по своему Bearer-ключу берёт у webapi
  (`POST /v1/stream/ticket`) короткоживущий тикет (HMAC секретом процесса,
  TTL `STREAM_TICKET_TTL`=1800с, привязан к username) и отдаёт браузеру.
  `EventSource` открывает поток с `?ticket=`; webapi валидирует.
- **Caddy** (`webapp.cibpn.online`): `handle /api/stream/online` →
  `reverse_proxy 127.0.0.1:8787` c `flush_interval -1` (без буферизации);
  `encode` вынесен в fallback, чтобы gzip не буферил поток.
- **Vue** (`Dashboard.vue`): `EventSource` на маунте, `liveOnline` перекрывает
  снимок из `/me`, `liveBps` кормит спидометр; авто-реконнект со свежим тикетом
  при разрыве; закрытие на unmount.

## Настройки (env на юните webapi / lib/webapi.sh)

- `HY2M_ONLINE_GRACE_SEC` — гистерезис, с (дефолт 90).
- `HY2M_STREAM_POLL_SEC` — период watcher, с (дефолт 5, минимум 2).
- `HY2M_STREAM_PING_SEC` — keepalive, с (дефолт 20).
- `HY2M_STREAM_TICKET_TTL` — TTL тикета, с (дефолт 1800).
- `ACTIVITY_THRESHOLD_BPS` — порог активности менеджера, Б/с (дефолт 4096).

Идлящий, но подключённый юзер (только keepalive, без трафика) считается **не в
сети** — это соответствует смыслу «онлайн = реально пользуется».

## Файлы
- `lib/traffic.sh` — `collect_activity` (мультипротокольный кумулятив),
  `collect_rates` + `get_user_rate` + `rates_timer_ensure` (тик скорости).
- `lib/subscription.sh` — `publish_stats` (минутная статистика), `publish_rates`.
- `lib/cluster.sh` — `cluster_rates_sync` (обмен скоростью с пирами).
- `lib/protocols.sh` — `proto_activity_cum_lines` (Xray + TUIC).
- `webapi/hy2-webapi.py` — `user_active_raw`/`is_online` (гистерезис),
  тикеты + `_stream_watcher` + SSE-хендлеры, маршруты `/v1/stream/*`.
- `cibpn-webapp`: `MeController::streamTicket`, `ManagerClient::streamTicket`,
  роут `/api/stream-ticket`, `Dashboard.vue` (EventSource); `/etc/caddy/Caddyfile`.

## Как дополнять
- **Порог/окно/каденс** — env выше, без правки кода.
- **Новый источник трафика** — добавить разбор в `proto_activity_cum_lines`
  (для активности) и/или `_all_user_totals` уже нет — активность идёт через
  `collect_activity`.
- **Живость кросс-ноды** ограничена синком ~4с + поминутным пересчётом `active`;
  ускорять каденс — только осознанно (нагрузка на ноды).
