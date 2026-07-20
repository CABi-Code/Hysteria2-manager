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
  `data: {"online": bool}` при изменении + keepalive `: ping`. Общий watcher-тред
  (`_stream_watcher`) раз в `STREAM_POLL_SEC` (5с) пересчитывает `is_online`
  ТОЛЬКО для юзеров с активными подписчиками и будит хендлеры — O(подписанных),
  не на клиента.
- **Тикет**: браузер не хранит ключ менеджера. Laravel (`GET /api/stream-ticket`,
  auth:sanctum) по своему Bearer-ключу берёт у webapi
  (`POST /v1/stream/ticket`) короткоживущий тикет (HMAC секретом процесса,
  TTL `STREAM_TICKET_TTL`=1800с, привязан к username) и отдаёт браузеру.
  `EventSource` открывает поток с `?ticket=`; webapi валидирует.
- **Caddy** (`домен-надстройки`): `handle /api/stream/online` →
  `reverse_proxy 127.0.0.1:8787` c `flush_interval -1` (без буферизации);
  `encode` вынесен в fallback, чтобы gzip не буферил поток.
- **Vue** (`Dashboard.vue`): `EventSource` на маунте, `liveOnline` перекрывает
  снимок из `/me`; авто-реконнект со свежим тикетом при разрыве; закрытие на
  unmount.

## Настройки (env на юните webapi / lib/webapi.sh)

- `HY2M_ONLINE_GRACE_SEC` — гистерезис, с (дефолт 90).
- `HY2M_STREAM_POLL_SEC` — период watcher, с (дефолт 5, минимум 2).
- `HY2M_STREAM_PING_SEC` — keepalive, с (дефолт 20).
- `HY2M_STREAM_TICKET_TTL` — TTL тикета, с (дефолт 1800).
- `ACTIVITY_THRESHOLD_BPS` — порог активности менеджера, Б/с (дефолт 4096).

Идлящий, но подключённый юзер (только keepalive, без трафика) считается **не в
сети** — это соответствует смыслу «онлайн = реально пользуется».

## Файлы
- `lib/traffic.sh` — `collect_activity` (мультипротокольный кумулятив).
- `lib/protocols.sh` — `proto_activity_cum_lines` (Xray + TUIC).
- `webapi/hy2-webapi.py` — `user_active_raw`/`is_online` (гистерезис),
  тикеты + `_stream_watcher` + SSE-хендлеры, маршруты `/v1/stream/*`.
- `надстройка`: `MeController::streamTicket`, `ManagerClient::streamTicket`,
  роут `/api/stream-ticket`, `Dashboard.vue` (EventSource); `/etc/caddy/Caddyfile`.

## Как дополнять
- **Порог/окно/каденс** — env выше, без правки кода.
- **Новый источник трафика** — добавить разбор в `proto_activity_cum_lines`
  (для активности) и/или `_all_user_totals` уже нет — активность идёт через
  `collect_activity`.
- **Живость кросс-ноды** ограничена синком ~4с + поминутным пересчётом `active`;
  ускорять каденс — только осознанно (нагрузка на ноды).
