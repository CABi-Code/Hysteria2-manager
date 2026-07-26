# Демо-ключи: `demo_create()` и таблица `DEMOS_DB`

Реализация менеджерской части воронки из идеи 13
(`cibpn-webapp/идейник/идеи/13-демо-ключ-и-публичная-главная/`).

Демо-ключ — одноразовый рабочий профиль, который выдаётся анонимному гостю с
публичной главной **до регистрации и оплаты**. Максимально урезан по скорости,
трафику и сроку, живёт в **отдельной таблице**, после истечения ещё сутки виден
в UI, затем удаляется с сервера и из таблицы. Отображается на всём кластере.

---

## 1. Жёсткие ограничения (иначе демо = дыра)

- **Только Hysteria (или Xray).** На **TUIC демо создавать нельзя**: sing-box не
  отдаёт юзера в API + CGNAT → трафик к юзеру не привязать → лимит не навесить
  (см. память `tuic-no-per-user-attribution`). Демо строим только там, где есть
  per-user учёт трафика.
- **Кап по всем осям сразу:** скорость (`DEMO_RATE_MBPS`), трафик
  (`DEMO_TRAFFIC_CAP`), срок (`DEMO_TTL_SEC`), `devices=1`. Экономика фарма
  ломается capом, а не неломаемым фингерпринтом — это 90% защиты.
- **Одна нода-приёмник.** Все демо создаются и терминируются на одной выбранной
  ноде кластера (`DEMO_NODE`). Остальные ноды демо **не обслуживают**, только
  **показывают** (read-only). Так проба не размазывается по боевым локациям.

> ⚠️ **Нативного per-user трафик-капа в менеджере нет.** `lib/limits.sh` умеет
> только скорость (`set_user_rate`) и число устройств; `lib/expiry.sh` — срок.
> Поэтому лимит трафика демо **сторожится кроном**: периодический прогон читает
> съеденное через `get_user_traffic` (`lib/traffic.sh:155`) и гасит профиль при
> превышении. Это тот же приём, что `check_expired_users` для срока — не
> изобретаем новый механизм.

---

## 2. Таблица `DEMOS_DB`

Отдельный файл, по образцу `USERS_DB` (`lib/config.sh:75`). Объявить в
`lib/config.sh` рядом с остальными базами:

```bash
DEMOS_DB="$DATA_DIR/demos.db"      # одноразовые демо-профили (отдельно от боевых)
```

**Почему отдельная таблица, а не флаг в `USERS_DB`:** у демо свой жизненный цикл
(грейс-сутки + авто-purge), своя статистика и свой раздел в UI. Смешение с
боевыми клиентами замусорило бы и базу, и все `sed`/`grep` по `USERS_DB`.

### Формат строки

```
name:pass:created_ts:expiry_ts:node:cap_bytes:state
```

| Поле | Пример | Смысл |
|---|---|---|
| `name` | `demo-a1b2c3d4` | логин профиля, префикс `demo-` |
| `pass` | `<64 симв.>` | пароль, из `bot_gen_pass` (`lib/tgbot_client.sh`, `bot_gen_pass`) |
| `created_ts` | `1721500000` | когда выдан (unix) |
| `expiry_ts` | `1721503600` | когда доступ кончается (`created + DEMO_TTL_SEC`) |
| `node` | `fin2` | нода-приёмник (`DEMO_NODE`), куда коннектится клиент |
| `cap_bytes` | `1073741824` | трафик-кап; профиль гасится при превышении |
| `state` | `active` | `active` → `expired` → (через сутки) удаляется |

Purge-момент **не хранится отдельным полем** — он производный:
`purge_ts = expiry_ts + DEMO_GRACE_SEC` (сутки). Меньше полей — меньше рассинхрона.

> Отпечаток устройства (кто получил демо) — **не здесь.** Он живёт в веб-аппе
> (модель `WebAccessToken`: `device_secret` + `hash(IP+UA)`), т.к. это про
> браузер, а не про профиль. `DEMOS_DB` хранит только сам профиль.

---

## 3. `demo_create()`

Новая функция в `lib/users.sh`, рядом с `bot_provision_user` (`lib/tgbot_client.sh`),
которую и берём за образец (та же генерация пароля и `db_add_user`).

```bash
# Создать одноразовый демо-профиль на этой ноде.
# Печатает "name pass" в stdout; пустой вывод / ret!=0 = ошибка.
demo_create() {
    # 0. Демо создаёт только выбранная нода-приёмник.
    [ "$(this_node_name)" = "$DEMO_NODE" ] || { echo "not demo node" >&2; return 1; }

    local name pass now exp
    name="demo-$(head -c16 /dev/urandom | md5sum | cut -c1-8)"
    pass=$(bot_gen_pass) || return 1          # без пустого пароля (см. bot_gen_pass)
    now=$(date +%s); exp=$(( now + DEMO_TTL_SEC ))

    # 1. завести юзера в боевой базе Hysteria (иначе не аутентифицируется)
    db_add_user "$name" "$pass"

    # 2. лимиты: 1 устройство, hardcheck=1, демо-скорость
    set_user_limits "$name" 1 1 "" "$DEMO_RATE_MBPS"

    # 3. срок жизни (ts напрямую — expiry.sh хранит и дату, и ts)
    set_user_expiry "$name" "$(days_to_date_from_ts "$exp")" "$exp"

    # 4. запись в отдельную таблицу демо
    printf '%s:%s:%s:%s:%s:%s:active\n' \
        "$name" "$pass" "$now" "$exp" "$DEMO_NODE" "$DEMO_TRAFFIC_CAP" >> "$DEMOS_DB"

    # 5. пересобрать подписку + разнести демо по кластеру для показа
    sub_refresh
    declare -F publish_cluster_demos >/dev/null && publish_cluster_demos

    printf '%s %s' "$name" "$pass"
}
```

Веб-апп зовёт это через `ManagerClient` (новый эндпоинт Web API, см. `API.md`) и
отдаёт гостю ссылку/подписку на `DEMO_NODE`.

---

## 4. Enforcement и жизненный цикл — `demo_sweep()`

Функция в `lib/expiry.sh` (рядом с `check_expired_users`, `:81`), вызывается
кроном часто (демо-TTL меряется минутами):

```bash
demo_sweep() {
    [ -f "$DEMOS_DB" ] || return 0
    local now; now=$(date +%s)
    local grace=$(( DEMO_GRACE_SEC ))     # сутки
    local name pass cts exp node cap state used
    while IFS=: read -r name pass cts exp node cap state _; do
        [ -n "$name" ] || continue
        used=$(get_user_traffic "$name" | awk -F'|' '{print $2+$3}')   # up+down

        # a) истёк по времени ИЛИ выбрал трафик → гасим доступ, метим expired
        if [ "$state" = active ] && { [ "$now" -ge "$exp" ] || [ "${used:-0}" -ge "$cap" ]; }; then
            disable_user "$name" silent          # кик + вон из USERS_DB, сразу
            demo_set_state "$name" expired
        fi

        # b) прошли сутки грейса после истечения → полное удаление
        if [ "$now" -ge $(( exp + grace )) ]; then
            delete_user "$name"                  # чистит все файлы + tombstone в кластер
            sed -i "/^${name}:/d" "$DEMOS_DB"
        fi
    done < "$DEMOS_DB"
    declare -F publish_cluster_demos >/dev/null && publish_cluster_demos
}
```

- **`disable_user … silent`** (`lib/users.sh:85`) уже делает ровно нужное:
  кикает активные сессии через `/kick` и убирает из `USERS_DB` **сразу**, без
  рестарта. Демо мгновенно перестаёт работать.
- **`delete_user`** (`lib/users.sh:121`) чистит `USERS_DB`, `EXPIRY_FILE`,
  `USERLIMITS_FILE`, `STATS_FILE` и ставит кластерный tombstone
  (`cstate_set … deleted` + `publish_cluster_state`) — удаление само разнесётся
  по нодам. Нам остаётся только вычистить строку из `DEMOS_DB`.

### Крон

В `setup_cron` (`lib/cron.sh:6`) добавить ветку по образцу существующих:

```bash
if ! echo "$current_cron" | grep -q "hy2-manager.*--demo-sweep"; then
    (echo "$current_cron"; echo "* * * * * /bin/bash \"$script_path\" --demo-sweep >/dev/null 2>&1") | crontab -
fi
```

Раз в минуту хватает: TTL/кап меряются минутами и мегабайтами, минутная
гранулярность даёт перерасход не больше одной минуты трафика на демо-скорости —
несущественно.

Диспетчер флага `--demo-sweep` → `demo_sweep` добавить туда же, где обрабатываются
`--check-expiry` / `--notify-sweep`.

---

## 5. Раздача по кластеру (показ на всех нодах)

Демо обслуживает **только** `DEMO_NODE`, но **видят** его все ноды. Это чистый
показ, поэтому — легче, чем полноценный roster: другие ноды **не заводят** демо в
свой `USERS_DB`, только держат read-only кэш для UI.

По образцу пары `publish_cluster_userlimits` / `cluster_apply_userlimits`
(`lib/cluster.sh:590,611`):

- **`publish_cluster_demos`** (на `DEMO_NODE`): кладёт снимок `DEMOS_DB` (без
  паролей — их пирам знать незачем) в `PEERS_DIR` как `.demos`, пиры забирают при
  `cluster_sync`.
- **`cluster_apply_demos`** (на остальных нодах): пишет полученный список в
  локальный кэш `DEMOS_CACHE` (только для отображения). **Не** трогает `USERS_DB`,
  **не** заводит юзеров, **не** создаёт подписок.

Настройка `DEMO_NODE` и капы раздаются существующим механизмом настроек
`publish_cluster_settings` / `cluster_apply_settings` (`lib/cluster.sh:492,505`).

---

## 6. Отображение в UI (как у обычных клиентов)

Отдельный раздел/фильтр «Демо» в списке (`lib/ui_users.sh`), тот же снапшот
`build_user_stats_snapshot` (`:22`): онлайн, съеденный трафик из
`get_user_traffic`, остаток времени (`format_remaining`, `expiry.sh:52`), нода,
`state` (`active`/`expired`). На `DEMO_NODE` данные живые из своих файлов, на
остальных — из `DEMOS_CACHE`. Кнопки управления (продлить/сбросить) для демо не
нужны — они одноразовые.

---

## 7. Конфиг (`lib/config.sh`)

```bash
DEMOS_DB="$DATA_DIR/demos.db"
DEMO_NODE=""                       # имя ноды-приёмника; пусто = демо выключены
DEMO_TTL_SEC=3600                  # срок демо, сек (1 ч — стартовое значение)
DEMO_GRACE_SEC=86400               # сутки показа после истечения, затем purge
DEMO_RATE_MBPS=5                   # потолок скорости
DEMO_TRAFFIC_CAP=$((1024*1024*1024))  # 1 ГБ трафика на профиль
```

Цифры стартовые, подбираются по ощущению «проба рабочая, фарм бессмысленный».
Выбор `DEMO_NODE` — в меню настроек менеджера, значение публикуется в кластер.

---

## 8. Что где трогать (сводка)

| Файл | Что добавить |
|---|---|
| `lib/config.sh` | `DEMOS_DB` + `DEMO_*` переменные |
| `lib/users.sh` | `demo_create()`, `demo_set_state()` |
| `lib/expiry.sh` | `demo_sweep()` + `days_to_date_from_ts` (обёртка над `days_to_date`) |
| `lib/cron.sh` | ветка `--demo-sweep` (раз в минуту) |
| `lib/cluster.sh` | `publish_cluster_demos` / `cluster_apply_demos` + раздача `DEMO_NODE` через настройки |
| `lib/ui_users.sh` | раздел «Демо» в списке + выбор `DEMO_NODE` в настройках |
| `hy2-manager.sh` | диспетчер флага `--demo-sweep` |
| `lib/webapi.sh` / `API.md` | эндпоинт «выдать демо» для веб-аппа |

## 9. Как расширять

- **Второй протокол (Xray).** `demo_create` заводит юзера в общей базе — ключи
  всех включённых протоколов производны от пароля (`lib/protocols.sh`), так что
  демо уже мультипротокольно на `DEMO_NODE`. Ограничить набор протоколов для
  демо — фильтром в сборке подписки.
- **Пул демо-нод вместо одной.** `DEMO_NODE` → список; `demo_create` выбирает
  наименее нагруженную. До реальной нагрузки не нужно (YAGNI).
- **Анти-фарм сверх капа** (капча/PoW) — на стороне веб-аппа, только если в
  `--demo-sweep`-статистике видно ботовый вал. Не в менеджере.
