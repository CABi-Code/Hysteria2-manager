# 08. Мультипротокол: VLESS+REALITY+XHTTP, Shadowsocks-2022, TUIC v5

Нода перестаёт быть «только Hysteria». Тот же пользователь из `users.db`
раздаётся сразу несколькими протоколами, и все они попадают в его подписку.
Клиент (Throne / Hiddify) при импорте видит один сервер как несколько
конфигов на выбор и подключается тем протоколом, который в его сети не
задушен цензором.

## Какие движки и почему

| Протокол | Движок | Причина |
|---|---|---|
| Hysteria 2 (obfs salamander) | `hysteria` (как было) | базовый, не трогаем |
| VLESS + REALITY + XHTTP | **Xray-core** | XHTTP — изобретение Xray; sing-box его как сервер не умеет |
| Shadowsocks-2022 (+ gRPC API) | **Xray-core** | тот же процесс, hot-add юзеров через `xray api` без рестарта |
| TUIC v5 | **sing-box** | единственная живая серверная реализация TUIC в 2026 |

Итого рядом с `hysteria-server.service` появляются два опциональных сервиса:
`hy2-xray.service` (VLESS+SS) и `hy2-singbox.service` (TUIC). Каждый включается
независимо; если ни один не включён — менеджер работает ровно как раньше.

## Единый источник правды по юзерам

База остаётся одна — `users.db` (`user:pass`). Ни один протокол не заводит
свой список пользователей руками: все креды **детерминированно выводятся** из
`user`, `pass` и узлового секрета `proto.secret`. Это даёт три важных свойства:

* подписка, манифест кластера и конфиги серверов всегда согласованы —
  пересчитать креды можно в любом месте, дополнительное состояние не хранится;
* добавление/удаление юзера в Hysteria (мгновенное, через `auth.type: command`)
  тем же хуком `sub_refresh` синхронизирует Xray и sing-box;
* кластер уже реплицирует `users.db`/roster — новые протоколы едут по тем же
  рельсам без изменений формата обмена.

Деривация (см. `proto_uuid` / `proto_upsk` в `lib/protocols.sh`):

```
UUID(user)  = uuidv5-подобный из sha1(proto_secret | user | pass)   # VLESS, TUIC
uPSK(user)  = base64( sha256(proto_secret | "ss" | user | pass)[:keylen] )  # SS-2022
iPSK(node)  = base64( sha256(proto_secret | "ipsk")[:keylen] )       # общий ключ инбаунда SS
TUIC-pass   = pass                                                    # пароль из users.db
```

`keylen` = 16 для `2022-blake3-aes-128-gcm` (дефолт), 32 для `-aes-256-gcm`.

## Параметры узла (`$DATA_DIR/protocols.conf`)

Отдельный от `node.conf` файл, чтобы не смешивать с кластерными настройками:

```
PROTO_VLESS_ENABLED=1
PROTO_SS_ENABLED=1
PROTO_TUIC_ENABLED=1
PROTO_VLESS_PORT=8443            # TCP
PROTO_SS_PORT=8388               # TCP
PROTO_TUIC_PORT=2053             # UDP
PROTO_SS_METHOD=2022-blake3-aes-128-gcm
PROTO_REALITY_DEST=www.microsoft.com:443
PROTO_REALITY_SNI=www.microsoft.com
PROTO_REALITY_PRIVKEY=...        # генерится xray x25519 при установке
PROTO_REALITY_PUBKEY=...         # pbk в подписку
PROTO_REALITY_SHORTID=...        # sid в подписку
PROTO_XHTTP_PATH=/               # path XHTTP
```

Порты по умолчанию не 443 — 443/80 заняты Caddy под HTTPS-подписку. REALITY
не требует именно 443; порт настраивается в UI.

## TLS

* VLESS+REALITY — сертификат не нужен (REALITY заимствует TLS чужого `dest`).
* SS-2022 — без TLS.
* TUIC (QUIC) — нужен TLS. По умолчанию самоподписанный серт (генерится при
  установке в `$DATA_DIR/proto/tuic.{crt,key}`), клиент идёт с `allow_insecure=1`
  — тот же подход, что у Hysteria (`insecure=1`). Опционально можно подставить
  валидный серт Caddy для домена ноды.

## Точки интеграции с существующим кодом

| Что | Где | Как меняется |
|---|---|---|
| Ссылки в подписке | `regen_subscriptions`, `subscription.sh` | после `hysteria2://` дописываем `proto_user_uris "$user" "$pass" "$ip"` |
| Манифест кластера | `publish_manifest` | те же доп. строки `user \t uri` на каждый включённый протокол |
| Синхронизация юзеров | `sub_refresh` | добавлен вызов `proto_sync_users` (hot-add в Xray, рестарт sing-box) |
| Установка/настройка | новый `lib/protocols.sh` + меню Настройки | скачивание бинарников, ключи, конфиги, systemd, firewall |
| Трафик | `--collect` | `proto_collect_traffic` суммирует байты из Xray StatsService и sing-box в `STATS_FILE` |
| Онлайн | `refresh_online` | `proto_online_merge` добавляет онлайн Xray/sing-box к Hysteria |
| Кик | `proto_kick user` | Xray: rmu+adu (сброс сессии); sing-box: рестарт (сессии рвутся) |
| Firewall | `ensure_proto_ports_open` | открыть TCP 8443/8388, UDP 2053 |

Дедуп в `regen_subscriptions` идёт по `host:port`; у каждого протокола свой
порт, поэтому строки не схлопываются и живут рядом.

## Что переиспользуется как есть

Срок действия, персональные лимиты/тарифы, токены подписки, платежи,
Telegram-привязки, каркас Web API, tc-шейпинг скорости (режет по IP+порт —
добавляются лишь фильтры на новые порты). Им нужно лишь скормить данные новых
протоколов, менять логику не требуется.

## Учёт трафика и онлайна

* **Трафик VLESS/SS-2022** снимается из Xray StatsService штатным CLI
  `xray api statsquery -reset` и докладывается в тот же `STATS_FILE`, что и
  Hysteria (`proto_collect_traffic`, вызывается из `--collect`). Квоты и
  статистика в кабинете учитывают эти байты.
* **Онлайн** сливается в `refresh_online`: Hysteria `/online` + online-статистика
  Xray + активные TUIC-соединения из `clash_api` sing-box (`proto_online_json`,
  best-effort — при сбое основной онлайн не ломается).
* **Кик** для «мягких» сценариев — `proto_kick` (Xray `api rmu`). При
  удалении/отключении/смене пароля юзер и так исчезает из конфига, и
  restart-on-change в `proto_sync_users` роняет его сессии сам.

## Известные ограничения (осознанные, задокументированы)

1. **Побайтный трафик TUIC** (sing-box) в общий учёт пока не входит — `clash_api`
   не даёт устойчивого per-user счётчика. Учитывается только Hysteria + VLESS/SS.
   При необходимости добавляется через `v2ray_api` sing-box (нужен gRPC-клиент).
2. **Онлайн в Web API** (python `hysteria_online`) читает только Hysteria; байты
   трафика в кабинете корректны (из `STATS_FILE`), но число «онлайн» по TUIC/VLESS
   там не отражается. Меню менеджера и плейсхолдер `{online}` — отражают.
3. **Активностный жёсткий лимит устройств** (`enforce_active_node_limit`,
   анти-абуз) строится на активности Hysteria. Отдельного per-протокол kick одного
   устройства нет; лимит на число ссылок подписки и удаление/бан работают для всех
   протоколов (через регенерацию конфига).
4. **Применение изменений состава юзеров** для VLESS/SS/TUIC — перезапуск сервиса
   при реальном изменении конфига (сравнение хеша). Hysteria остаётся горячей;
   доп. протоколы кратко переподнимаются только когда состав/параметры меняются.
