# Реестр проблем

Живой список того, что **известно и не починено**. Отдельно от [guide/](../guide/):
там написано, как работает то, что работает; здесь — что не работает, работает не
до конца или работает не так, как обещает соседний документ.

## Как вести реестр

- **Нашёл проблему — сразу запись сюда**, даже если чинить не собираешься.
  Ненаписанная проблема через месяц находится заново и стоит те же часы.
- Запись живёт в файле своей темы (таблица ниже), строка — в этой сводке.
- **Починил — правь на месте:** статус `✅`, одна строка «чем закрыто» и номер
  коммита. Запись **не удалять** — она объясняет, почему код выглядит так, а
  не иначе.
- Номер `P-NN` сквозной по всем файлам темы, стабильный, не переиспользуется.
  Следующий свободный — см. конец сводки. Счётчик общий с реестром надстройки:
  пропуски в нумерации — её номера, а не потерянные записи.
- **Здесь только проблемы менеджера.** Репозиторий публичный: проблемы
  надстройки-потребителя API живут в её собственном (приватном) реестре, вместе
  с хостами, суммами и внутренностями периметра. Проблема на стыке остаётся
  здесь, если чинится кодом менеджера, — и описывается без чужих хостов и путей.
- Проверенное отличать от предполагаемого. Если проблема выведена из чтения
  кода, но не воспроизведена — так и писать.
- Проблема, у которой есть проект решения, ссылается на него, а не пересказывает.

Статусы: 🔴 ломает работу · 🟡 мешает, но живём · 🟢 мелочь · ✅ закрыто.

## Темы

| Тема | О чём | Открыто | Закрыто (архив) |
|---|---|:--:|---|
| [PROTOCOLS.md](PROTOCOLS.md) | Движки, их API, учёт трафика и онлайна по протоколам | 13 | [CLOSED](PROTOCOLS-CLOSED.md) — 10 |
| [CLUSTER.md](CLUSTER.md) | Обмен между нодами, жизненный цикл профиля, подписка | 13 | [CLOSED-1](CLUSTER-CLOSED-1.md), [CLOSED-2](CLUSTER-CLOSED-2.md) — 17 |
| [LIMITS.md](LIMITS.md) | Лимит устройств, жёсткая проверка, анти-абуз, скорость | 5 | [CLOSED](LIMITS-CLOSED.md) — 12 |
| [BILLING.md](BILLING.md) | Оплаты, тарифы, разделение ролей издателя и оператора | 2 | в том же файле — 4 |
| [OPS.md](OPS.md) | Гонки кронов, отдача данных наружу, мелочи | 17 | [CLOSED-1](OPS-CLOSED-1.md), [CLOSED-2](OPS-CLOSED-2.md) — 28 |

**Ни один файл реестра не длиннее 500 строк.** Тема разрослась — закрытые записи
уезжают в `ТЕМА-CLOSED.md` (или `-CLOSED-N.md`), открытые остаются; строка сводки
ниже всегда ведёт на актуальный файл. Закрыл запись в файле открытых — перенеси
её в архив в том же заходе.

## Сводка

Отсортировано по тяжести. «Где» — файл кода, с которого начинать разбор.

| # | Проблема | Где | Тема | Статус |
|:--:|---|---|---|:--:|
| [P-165](PROTOCOLS-CLOSED.md#p-165) | Корень 443 и dest REALITY отдают текст про клиентов подписки (P-129 только в доке) | `lib/caddy.sh` | [protocols](PROTOCOLS.md) | ✅ |
| [P-138](CLUSTER-CLOSED-2.md#p-138) | Токен подписки из данных пира становится путём записи от root | `lib/sub_links.sh` | [cluster](CLUSTER.md) | ✅ |
| [P-139](CLUSTER-CLOSED-2.md#p-139) | Имя профиля из кластерного состояния уходит в `sed` без экранирования | `lib/cluster.sh` | [cluster](CLUSTER.md) | ✅ |
| [P-166](PROTOCOLS.md#p-166) | Основной VLESS — raw TCP + Vision, связка, которую ТСПУ ловит по поведению | `lib/protocols.sh` | [protocols](PROTOCOLS.md) | 🟡 |
| [P-167](PROTOCOLS.md#p-167) | TUIC — голый QUIC, SNI ноды виден в Initial | `lib/protocols.sh` | [protocols](PROTOCOLS.md) | 🟡 |
| [P-168](PROTOCOLS.md#p-168) | Hysteria на одном UDP-порту без hopping (маскарад закрыт) | `lib/perf.sh` | [protocols](PROTOCOLS.md) | 🟡 |
| [P-171](PROTOCOLS.md#p-171) | Hysteria на мобильной сети: сессия умирает через ~30 с, переподключения без конца | `lib/protocols.sh` | [protocols](PROTOCOLS.md) | 🟡 |
| [P-172](LIMITS.md#p-172) | Кик «2 устройства» при одном известном адресе — после P-163 | `lib/publish.sh` | [limits](LIMITS.md) | 🟡 |
| [P-173](PROTOCOLS.md#p-173) | `geoip:ru` режет anycast-адрес зарубежного CDN | `lib/rublock.sh` | [protocols](PROTOCOLS.md) | 🟡 |
| [P-170](PROTOCOLS.md#p-170) | Все ноды — поддомены одного домена сервиса; вход и выход на одном адресе | — | [protocols](PROTOCOLS.md) | 🟡 |
| [P-147](OPS.md#p-147) | Все ноды кластера в одной подсети одного хостера, доступность из РФ никто не меряет | — | [ops](OPS.md) | 🟡 |
| [P-145](OPS.md#p-145) | Длинный опрос Telegram зависает несколько раз в сутки: бот молчит до минуты | `lib/tgbot_daemon.sh` | [ops](OPS.md) | 🟡 |
| [P-141](OPS.md#p-141) | Демон бота держит код с момента запуска: правка `lib/` без рестарта не доезжает | `lib/tgbot_daemon.sh` | [ops](OPS.md) | 🟡 |
| [P-140](OPS-CLOSED-2.md#p-140) | Неудачная аутентификация Web API ничем не ограничена по частоте | `webapi/hy2-webapi.py` | [ops](OPS.md) | ✅ |
| [P-115](OPS.md#p-115) | `POST /v1/users` отдаёт 504, хотя профиль создан: обрыв оставляет бессрочный профиль | `webapi/wa_dispatch.py` | [ops](OPS.md) | 🔴 |
| [P-113](CLUSTER.md#p-113) | Устройства и приложения видит только та нода, с которой качали | `lib/ip_tracking.sh` | [cluster](CLUSTER.md) | 🟡 |
| [P-96](OPS.md#p-96) | Удаление профиля оставляет адреса и привязку Telegram (стирает `erase_user`) | `lib/users.sh` | [ops](OPS.md) | 🟡 |
| [P-112](CLUSTER-CLOSED-1.md#p-112) | Токены подписки не уезжали к соседям: `/cluster/subtokens` отдавал 403 | `lib/sub_links.sh` | [cluster](CLUSTER.md) | ✅ |
| [P-97](CLUSTER-CLOSED-1.md#p-97) | `total=0` в подписке клиент показывал как «Квота исчерпана» | `lib/sub_links.sh` | [cluster](CLUSTER.md) | ✅ |
| [P-79](OPS-CLOSED-1.md#p-79) | Журнал ноды хранил связку «адрес ↔ имя пользователя ↔ куда ходил» | `lib/protocols.sh` | [ops](OPS.md) | ✅ |
| [P-37](OPS-CLOSED-1.md#p-37) | Сбор трафика обнулял счётчики движков — спидометр падал в ноль при открытом TUI | `lib/traffic.sh` | [ops](OPS.md) | ✅ |
| [P-38](CLUSTER-CLOSED-1.md#p-38) | По кластеру ездил только Hysteria-онлайн: VLESS/TUIC-юзеры офлайн для соседей | `lib/publish.sh` | [cluster](CLUSTER.md) | ✅ |
| [P-71](LIMITS-CLOSED.md#p-71) | Глобальный лимит скорости — один на всю ноду, а не на клиента | `lib/perf.sh` | [limits](LIMITS.md) | ✅ |
| [P-70](LIMITS-CLOSED.md#p-70) | Нода без `SHAPE` шейпила один Hysteria — остальные протоколы мимо лимита | `lib/perf.sh` | [limits](LIMITS.md) | ✅ |
| [P-80](CLUSTER.md#p-80) | Имя профиля нельзя сменить: в кластере оно ничем не переносится | `lib/users.sh` | [cluster](CLUSTER.md) | 🟡 |
| [P-32](CLUSTER.md#p-32) | Нода с самоподписанным сертификатом не лечится сама | `lib/caddy.sh` | [cluster](CLUSTER.md) | 🟡 |
| [P-01](PROTOCOLS-CLOSED.md#p-01) | TUIC рестартует при любом изменении состава юзеров | `lib/protocols.sh` | [protocols](PROTOCOLS.md) | ✅ |
| [P-03](CLUSTER.md#p-03) | Нельзя снять юзера с одной ноды — только со всего кластера | `lib/cluster.sh` | [cluster](CLUSTER.md) | 🔴 |
| [P-07](LIMITS.md#p-07) | Детект шаринга имеет потолок и умирает молча | `lib/antiabuse.sh` | [limits](LIMITS.md) | 🔴 |
| [P-13](CLUSTER.md#p-13) | Удаление профиля на одной ноде не удаляет его в кластере | `lib/users.sh` | [cluster](CLUSTER.md) | 🔴 |
| [P-15](PROTOCOLS-CLOSED.md#p-15) | Онлайн Xray-протоколов всегда пуст (нет `statsUserOnline`) | `lib/protocols.sh` | [protocols](PROTOCOLS.md) | ✅ |
| [P-16](LIMITS.md#p-16) | Кик только у Hysteria: лимиты не действуют на доп. протоколы | `lib/protocols.sh` | [limits](LIMITS.md) | 🟡 |
| [P-02](PROTOCOLS-CLOSED.md#p-02) | Трафик TUIC не считается вообще (проверено) | `lib/protocols.sh` | [protocols](PROTOCOLS.md) | ✅ |
| [P-04](CLUSTER.md#p-04) | Общий секрет кластера: утечка с одной ноды = доступ ко всем | `lib/cluster.sh` | [cluster](CLUSTER.md) | 🟡 |
| [P-05](CLUSTER.md#p-05) | Манифест содержит пароли юзеров: каждая нода знает учётки всех | `lib/sub_links.sh` | [cluster](CLUSTER.md) | 🟡 |
| [P-06](CLUSTER.md#p-06) | Нет паспорта ноды: ёмкость, метка, протоколы не публикуются | `lib/cluster.sh` | [cluster](CLUSTER.md) | 🟡 |
| [P-08](CLUSTER.md#p-08) | Все юзеры на всех нодах: ёмкости нет, рост упирается в слабейшую | весь кластер | [cluster](CLUSTER.md) | 🟡 |
| [P-09](BILLING.md#p-09) | Роль издателя расщеплена между менеджером и надстройкой | cross-repo | [billing](BILLING.md) | ✅ |
| [P-11](BILLING.md#p-11) | Длина ваучера в стоковых клиентах не проверена | — | [billing](BILLING.md) | 🟡 |
| [P-14](CLUSTER.md#p-14) | Осиротевшие токены подписки не убираются никогда | `lib/sub_links.sh` | [cluster](CLUSTER.md) | 🟡 |
| [P-34](PROTOCOLS-CLOSED.md#p-34) | Онлайн складывался по протоколам: один клиент считался трижды | `lib/online.sh` | [protocols](PROTOCOLS.md) | ✅ |
| [P-33](PROTOCOLS-CLOSED.md#p-33) | Онлайн Xray считал историю IP: один телефон = 5–11 «устройств» | `lib/protocols.sh` | [protocols](PROTOCOLS.md) | ✅ |
| [P-17](PROTOCOLS-CLOSED.md#p-17) | Трафик/онлайн TUIC читают `metadata.user`, которого нет | `lib/protocols.sh` | [protocols](PROTOCOLS.md) | ✅ |
| [P-18](PROTOCOLS.md#p-18) | IP-трекинг только по журналу Hysteria — от него зависят тарифы | `lib/ip_tracking.sh` | [protocols](PROTOCOLS.md) | 🟡 |
| [P-19](BILLING.md#p-19) | Покупка тарифа обнуляет персональный тариф скорости | `lib/tgbot_client.sh` | [billing](BILLING.md) | ✅ |
| [P-20](BILLING.md#p-20) | Двойное зачисление ЮMoney: проверка и запись разнесены | `lib/yoomoney.sh` | [billing](BILLING.md) | ✅ |
| [P-21](OPS-CLOSED-1.md#p-21) | `stats.dat` правится без блокировки, кроны пересекаются | `lib/traffic.sh` | [ops](OPS.md) | ✅ |
| [P-35](OPS-CLOSED-1.md#p-35) | Трафик Xray в менеджере обновлялся раз в полчаса — выглядел зависшим | `lib/traffic.sh` | [ops](OPS.md) | ✅ |
| [P-22](CLUSTER.md#p-22) | Кластерная сумма трафика немонотонна, free-план строит на ней разницу | `lib/freeplan.sh` | [cluster](CLUSTER.md) | 🟡 |
| [P-169](PROTOCOLS.md#p-169) | Trojan/WS: путь `/` и не заданный в ссылке отпечаток TLS | `lib/protocols.sh` | [protocols](PROTOCOLS.md) | 🟢 |
| [P-174](PROTOCOLS.md#p-174) | Trojan: сотни TLS-рукопожатий в сутки обрываются по тайм-ауту | `lib/protocols.sh` | [protocols](PROTOCOLS.md) | 🟢 |
| [P-175](OPS.md#p-175) | Caddy перечитывает конфиг каждые 2–3 минуты (SSE `/api` под ударом, не проверено) | `lib/sub_links.sh` | [ops](OPS.md) | 🟢 |
| [P-176](OPS-CLOSED-2.md#p-176) | Адреса клиентов открытыми в файлах, журналах и у соседей — теперь хэш с солью месяца | `lib/iphash.py` | [ops](OPS.md) | ✅ |
| [P-177](OPS.md#p-177) | Фильтр журнала уронил Hysteria и Xray на соседях: установщик не возил `iphash.py`, умер читатель трубы — SIGPIPE демону | `install.sh`, `lib/ip_tracking.sh` | [ops](OPS.md) | 🟡 |
| [P-178](PROTOCOLS.md#p-178) | VLESS/REALITY не проходит у клиентов на ядре sing-box: «reality verification failed» | `lib/protocols.sh` | [protocols](PROTOCOLS.md) | 🟡 |
| [P-10](LIMITS.md#p-10) | tc-классы привязаны к имени юзера из `users.db` | `lib/perf.sh` | [limits](LIMITS.md) | 🟢 |
| [P-12](OPS.md#p-12) | Возможный двойной счёт скорости на релейном трафике | `lib/publish.sh` | [ops](OPS.md) | 🟢 |
| [P-72](OPS.md#p-72) | `onlineips.dat` осиротел: файл лежит, никто его не пишет и не читает | `lib/online.sh` | [ops](OPS.md) | 🟢 |
| [P-73](CLUSTER-CLOSED-1.md#p-73) | Демо на чужой ноде не переживает её недоступность | `lib/demo.sh` | [cluster](CLUSTER.md) | ✅ |
| [P-23](LIMITS-CLOSED.md#p-23) | `abuse.dat` растёт вечно | `lib/antiabuse.sh` | [limits](LIMITS.md) | ✅ |
| [P-24](CLUSTER.md#p-24) | Хвосты удалённого профиля достаются одноимённому новому | `lib/users.sh` | [cluster](CLUSTER.md) | 🟢 |
| [P-25](OPS-CLOSED-1.md#p-25) | Web API не знает про Trojan | `webapi/wa_dispatch.py` | [ops](OPS.md) | ✅ |
| [P-39](OPS-CLOSED-1.md#p-39) | Бот отправлял всех на сайт одного оператора | `lib/tgbot_daemon.sh` | [ops](OPS.md) | ✅ |
| [P-36](OPS-CLOSED-1.md#p-36) | `authmap.dat` растёт вечно, а его читает каждый перерасчёт онлайна | `lib/ip_tracking.sh` | [ops](OPS.md) | ✅ |
| [P-31](CLUSTER-CLOSED-1.md#p-31) | Недоступный пир никак себя не проявлял в менеджере | `lib/cluster.sh` | [cluster](CLUSTER.md) | ✅ |
| [P-41](LIMITS-CLOSED.md#p-41) | Жёсткая проверка снимает лимит устройств внутри ноды | `lib/devlimits.sh` | [limits](LIMITS.md) | ✅ |
| [P-42](LIMITS-CLOSED.md#p-42) | Оплата тарифа в боте затирает докупленные устройства | `lib/tgbot_client.sh` | [limits](LIMITS.md) | ✅ |
| [P-43](OPS-CLOSED-1.md#p-43) | Спидометр залипал на сотнях Мбит/с: mawk обрезал кумулятив до 2^31-1 | `lib/traffic.sh` | [ops](OPS.md) | ✅ |
| [P-44](LIMITS-CLOSED.md#p-44) | При превышении по кластеру кикали все ноды сразу | `lib/devlimits.sh` | [limits](LIMITS.md) | ✅ |
| [P-45](LIMITS-CLOSED.md#p-45) | Одно устройство считалось за столько, на скольких нодах видно | `lib/publish.sh` | [limits](LIMITS.md) | ✅ |
| [P-46](OPS-CLOSED-1.md#p-46) | Открытый TUI публикует статистику своим — старым — кодом | `lib/cluster.sh` | [ops](OPS.md) | ✅ |
| [P-47](OPS-CLOSED-1.md#p-47) | Кроны наслаивались друг на друга: 100% CPU из одних форков | `lib/cron.sh` | [ops](OPS.md) | ✅ |
| [P-48](OPS-CLOSED-1.md#p-48) | Открытое меню менеджера стоит ноде полъядра | `lib/online.sh` | [ops](OPS.md) | ✅ |
| [P-50](PROTOCOLS-CLOSED.md#p-50) | Trojan/TUIC/HY2 держались на insecure-флаге, которого у клиентов больше нет | `lib/protocols.sh` | [protocols](PROTOCOLS.md) | ✅ |
| [P-49](OPS-CLOSED-1.md#p-49) | Модуль, выпавший из состава, остаётся на ноде навсегда | `install.sh` | [ops](OPS.md) | ✅ |
| [P-51](PROTOCOLS.md#p-51) | Hysteria2 на ноде «жив», но снаружи её домен его не отдаёт | `lib/cluster.sh` | [protocols](PROTOCOLS.md) | 🟡 |
| [P-84](OPS.md#p-84) | `footprint` отдаёт наружу имена нераспознанных файлов `DATA_DIR` | `webapi/wa_footprint.py` | [ops](OPS.md) | 🟡 |
| [P-77](OPS.md#p-77) | `POST /v1/users/{name}/limits` отвечает ~5,5 с — потребитель срывается по таймауту | `webapi/dispatch.sh` | [ops](OPS.md) | 🟡 |
| [P-76](CLUSTER-CLOSED-1.md#p-76) | Верхний ключ подписки один для всех, а клиент выбор не запоминает | `lib/sub_links.sh` | [cluster](CLUSTER.md) | ✅ |
| [P-52](CLUSTER-CLOSED-1.md#p-52) | Нода без бесплатного тарифа отключала того, кто на бесплатном | `lib/expiry.sh` | [cluster](CLUSTER.md) | ✅ |
| [P-53](BILLING.md#p-53) | Снятие дней рапортовалось как «Подписка активна» и глушило напоминания | `lib/tgbot_client.sh` | [billing](BILLING.md) | ✅ |
| [P-56](LIMITS-CLOSED.md#p-56) | Исчерпав месячную квоту free, бот обещал возврат доступа через неделю | `lib/freeplan.sh` | [limits](LIMITS.md) | ✅ |
| [P-59](BILLING.md#p-59) | Возврат подарочных дней шлёт два уведомления от двух систем | `lib/tgbot_client.sh` | [billing](BILLING.md) | 🟡 |
| [P-62](CLUSTER-CLOSED-1.md#p-62) | Расход юзера на других нодах обрезался до 2 ГиБ (mawk, `%d`) | `lib/freeplan.sh` | [cluster](CLUSTER.md) | ✅ |
| [P-74](PROTOCOLS-CLOSED.md#p-74) | sing-box JSON-конфиг выдавался с SNI маскарада — клиент не подключался | `lib/users.sh` | [protocols](PROTOCOLS.md) | ✅ |
| [P-75](OPS-CLOSED-1.md#p-75) | `get_port` не читал порт из `listen` с адресом | `lib/config.sh` | [ops](OPS.md) | ✅ |
| [P-100](LIMITS-CLOSED.md#p-100) | Проданное устройство продолжало работать по своей ссылке | `lib/sub_links.sh` | [limits](LIMITS.md) | ✅ |
| [P-101](LIMITS.md#p-101) | У каждой ноды свой основной токен: подписка живёт по N ссылкам | `lib/sub_links.sh` | [limits](LIMITS.md) | 🟡 |
| [P-102](OPS-CLOSED-1.md#p-102) | Одно уведомление приходило дважды: и в личку бота, и в директ канала | `lib/notify.sh` | [ops](OPS.md) | ✅ |
| [P-103](OPS-CLOSED-1.md#p-103) | «Осталось 23ч 59м» вместо суток: остаток обрезался по секундам | `lib/expiry.sh` | [ops](OPS.md) | ✅ |
| [P-110](CLUSTER-CLOSED-1.md#p-110) | Забвение не выходило за ноду: стёртые данные возвращались с соседей | `lib/cluster.sh`, `lib/traffic.sh` | [cluster](CLUSTER.md) | ✅ |
| [P-119](OPS.md#p-119) | Фон менеджера съедает ядро целиком, интерактив стоит в общей очереди | `lib/config.sh`, `lib/sub_links.sh` | [ops](OPS.md) | 🟡 |
| [P-122](PROTOCOLS-CLOSED.md#p-122) | Клиентский конфиг резолвил домен ноды открытым UDP — перехват на транзите | `lib/users.sh` | [protocols](PROTOCOLS.md) | ✅ |
| [P-123](OPS.md#p-123) | Уведомление, которому некому уйти, терялось молча | `lib/notify.sh` | [ops](OPS.md) | — |
| [P-126](OPS-CLOSED-1.md#p-126) | Ссылка из директа канала вела в «код неверен» | `lib/tgbot_daemon.sh` | [ops](OPS.md) | ✅ |
| [P-129](PROTOCOLS.md#p-129) | REALITY маскировался чужим популярным доменом — бан адреса ноды | `lib/protocols.sh` | [protocols](PROTOCOLS.md) | 🟡 |
| [P-130](CLUSTER-CLOSED-1.md#p-130) | Отключённый локально при кластерном `active` застревал навсегда | `lib/cluster.sh` | [cluster](CLUSTER.md) | ✅ |
| [P-131](CLUSTER-CLOSED-1.md#p-131) | Оплатившего не снимали с бесплатного тарифа на ноде без `free=1` | `lib/freeplan.sh` | [cluster](CLUSTER.md) | ✅ |
| [P-132](OPS-CLOSED-1.md#p-132) | Web API называл основной VLESS транспортом, которого у него нет | `webapi/wa_dispatch.py` | [ops](OPS.md) | ✅ |
| [P-133](CLUSTER-CLOSED-2.md#p-133) | Крючок обновления требует Web API на цели, и об этом никто не говорит | `lib/cluster.sh`, `lib/caddy.sh` | [cluster](CLUSTER.md) | ✅ |
| [P-134](CLUSTER-CLOSED-2.md#p-134) | Имя пира из gossip становилось путём записи от root | `lib/cluster.sh` | [cluster](CLUSTER.md) | ✅ |
| [P-135](OPS-CLOSED-2.md#p-135) | Секрет кластера читался любым локальным процессом (Caddyfile 0644) | `lib/caddy.sh` | [ops](OPS.md) | ✅ |
| [P-136](PROTOCOLS.md#p-136) | `bind` уводил Caddy с loopback, а dest REALITY на него смотрит | `lib/caddy.sh` | [protocols](PROTOCOLS.md) | 🟡 |
| [P-153](OPS-CLOSED-2.md#p-153) | Напоминание об истечении приходило дважды: таймаут лички и соседние ноды | `lib/notify.sh` | [ops](OPS.md) | ✅ |
| [P-160](LIMITS-CLOSED.md#p-160) | Бесплатный тариф качелями между нодами: «снова работает» / «закончился» каждые минуты | `lib/freeplan.sh` | [limits](LIMITS.md) | ✅ |
| [P-159](LIMITS-CLOSED.md#p-159) | Один телефон на лимите 1 рвало каждые минуты: активные ноды считались за устройства | `lib/devlimits.sh`, `lib/antiabuse.sh` | [limits](LIMITS.md) | ✅ |
| [P-163](LIMITS-CLOSED.md#p-163) | Телефон на лимите 1 выбивало с рабочей ноды: вчерашний адрес считался вторым устройством | `lib/online.sh`, `lib/devlimits.sh` | [limits](LIMITS.md) | ✅ |
| [P-162](OPS-CLOSED-2.md#p-162) | Сообщения бесплатного тарифа и автоотключения слались из переходов на каждой ноде | `lib/freeplan.sh`, `lib/tgbot_daemon.sh` | [ops](OPS.md) | ✅ |
| [P-158](OPS-CLOSED-2.md#p-158) | Xray копил мёртвые соединения неделями: нет TCP keepalive на входах | `lib/protocols.sh` | [ops](OPS.md) | ✅ |
| [P-154](OPS-CLOSED-2.md#p-154) | `/start sub_…` не доходил до надстройки — «код неверен» | `lib/tgbot_daemon.sh` | [ops](OPS.md) | ✅ |
| [P-164](OPS.md#p-164) | CVE-2026-98432: удалённый root через MPTCP, xray на нодах не обновлялся | `lib/protocols.sh` | [ops](OPS.md) | 🟡 |
| [P-179](OPS.md#p-179) | В журнале ошибок раз в полчаса `grep: (standard input): binary file matches` | `lib/ip_tracking.sh` | [ops](OPS.md) | 🟢 |
| [P-180](OPS-CLOSED-2.md#p-180) | Журнал ошибок хранил адреса клиентов рядом с именами — след отладочной трассировки | — | [ops](OPS.md) | ✅ |
| [P-181](CLUSTER-CLOSED-2.md#p-181) | Данные пира писались в кэш в семи местах: без проверки, неатомарно, по рукопожатию на раздел | `lib/cluster.sh` | [cluster](CLUSTER.md) | ✅ |
| [P-182](OPS-CLOSED-2.md#p-182) | Любое действие над одним профилем ждало перевыпуска подписок всех профилей | `lib/sub_links.sh` | [ops](OPS.md) | ✅ |
| [P-183](OPS-CLOSED-2.md#p-183) | Меню при каждом открытии повторяло работу крона | `hy2-manager.sh` | [ops](OPS.md) | ✅ |
| [P-184](CLUSTER-CLOSED-2.md#p-184) | Сосед знал о ноде одно: отвечает ли её :443 | `lib/health.sh` | [cluster](CLUSTER.md) | ✅ |
| [P-185](CLUSTER.md#p-185) | Чистка удалённого профиля написана дважды, и списки файлов разошлись | `lib/users.sh`, `lib/cluster.sh` | [cluster](CLUSTER.md) | 🟢 |
| [P-186](OPS.md#p-186) | Живое сообщение инцидента реализовано дважды | `lib/ruprobe.sh`, `lib/health.sh` | [ops](OPS.md) | 🟢 |
| [P-187](OPS-CLOSED-2.md#p-187) | Тест здоровья кластера «проходил» с необъявленной функцией и неверным ожиданием | `tests/` | [ops](OPS.md) | ✅ |
| [P-188](OPS.md#p-188) | Девять файлов кода длиннее 500 строк | `lib/protocols.sh` | [ops](OPS.md) | 🟡 |

Следующий свободный номер — **P-189**.

Номера **P-74** и **P-75** выданы задним числом: обе линии — `main` и
`integration-multiprotocol` — независимо заняли `P-52` и `P-53` под разные
проблемы. При слиянии за ветвью оставлены её номера (на них ссылается
документация), а пришедшие из `main` перенумерованы в свободные.
