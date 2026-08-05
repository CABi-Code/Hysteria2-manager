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
  Следующий свободный — см. конец сводки.
- Проверенное отличать от предполагаемого. Если проблема выведена из чтения
  кода, но не воспроизведена — так и писать.
- Проблема, у которой есть проект решения, ссылается на него, а не пересказывает.

Статусы: 🔴 ломает работу · 🟡 мешает, но живём · 🟢 мелочь · ✅ закрыто.

## Темы

| Файл | О чём | Проблем |
|---|---|:--:|
| [PROTOCOLS.md](PROTOCOLS.md) | Движки, их API, учёт трафика и онлайна по протоколам | 8 |
| [CLUSTER.md](CLUSTER.md) | Обмен между нодами, жизненный цикл профиля, подписка | 12 |
| [LIMITS.md](LIMITS.md) | Лимит устройств, жёсткая проверка, анти-абуз, скорость | 6 |
| [BILLING.md](BILLING.md) | Оплаты, тарифы, разделение ролей издателя и оператора | 4 |
| [OPS.md](OPS.md) | Гонки кронов, отдача данных наружу, мелочи | 10 |
| [WEBAPP.md](WEBAPP.md) | Мини-апп и веб-кабинет `/opt/надстройка` (отдельный репозиторий) | 6 |

## Сводка

Отсортировано по тяжести. «Где» — файл кода, с которого начинать разбор.

| # | Проблема | Где | Тема | Статус |
|:--:|---|---|---|:--:|
| [P-37](OPS.md#p-37) | Сбор трафика обнулял счётчики движков — спидометр падал в ноль при открытом TUI | `lib/traffic.sh` | [ops](OPS.md) | ✅ |
| [P-38](CLUSTER.md#p-38) | По кластеру ездил только Hysteria-онлайн: VLESS/TUIC-юзеры офлайн для соседей | `lib/publish.sh` | [cluster](CLUSTER.md) | ✅ |
| [P-32](CLUSTER.md#p-32) | Нода с самоподписанным сертификатом не лечится сама | `lib/caddy.sh` | [cluster](CLUSTER.md) | 🔴 |
| [P-01](PROTOCOLS.md#p-01) | TUIC рестартует при любом изменении состава юзеров | `lib/protocols.sh` | [protocols](PROTOCOLS.md) | ✅ |
| [P-03](CLUSTER.md#p-03) | Нельзя снять юзера с одной ноды — только со всего кластера | `lib/cluster.sh` | [cluster](CLUSTER.md) | 🔴 |
| [P-07](LIMITS.md#p-07) | Детект шаринга имеет потолок и умирает молча | `lib/antiabuse.sh` | [limits](LIMITS.md) | 🔴 |
| [P-13](CLUSTER.md#p-13) | Удаление профиля на одной ноде не удаляет его в кластере | `lib/users.sh` | [cluster](CLUSTER.md) | 🔴 |
| [P-15](PROTOCOLS.md#p-15) | Онлайн Xray-протоколов всегда пуст (нет `statsUserOnline`) | `lib/protocols.sh` | [protocols](PROTOCOLS.md) | ✅ |
| [P-16](LIMITS.md#p-16) | Кик только у Hysteria: лимиты не действуют на доп. протоколы | `lib/protocols.sh` | [limits](LIMITS.md) | 🟡 |
| [P-26](WEBAPP.md#p-26) | Неавторизованный запрос к `/api/*` отдаёт 500 и стек вместо 401 | `bootstrap/app.php` | [webapp](WEBAPP.md) | ✅ |
| [P-27](WEBAPP.md#p-27) | Прод работает как `APP_ENV=local` с `APP_DEBUG=true` | `.env` | [webapp](WEBAPP.md) | ✅ |
| [P-02](PROTOCOLS.md#p-02) | Трафик TUIC не считается вообще (проверено) | `lib/protocols.sh` | [protocols](PROTOCOLS.md) | ✅ |
| [P-04](CLUSTER.md#p-04) | Общий секрет кластера: утечка с одной ноды = доступ ко всем | `lib/cluster.sh` | [cluster](CLUSTER.md) | 🟡 |
| [P-05](CLUSTER.md#p-05) | Манифест содержит пароли юзеров: каждая нода знает учётки всех | `lib/sub_links.sh` | [cluster](CLUSTER.md) | 🟡 |
| [P-06](CLUSTER.md#p-06) | Нет паспорта ноды: ёмкость, метка, протоколы не публикуются | `lib/cluster.sh` | [cluster](CLUSTER.md) | 🟡 |
| [P-08](CLUSTER.md#p-08) | Все юзеры на всех нодах: ёмкости нет, рост упирается в слабейшую | весь кластер | [cluster](CLUSTER.md) | 🟡 |
| [P-09](BILLING.md#p-09) | Роль издателя расщеплена между менеджером и webapp | cross-repo | [billing](BILLING.md) | ✅ |
| [P-11](BILLING.md#p-11) | Длина ваучера в стоковых клиентах не проверена | — | [billing](BILLING.md) | 🟡 |
| [P-14](CLUSTER.md#p-14) | Осиротевшие токены подписки не убираются никогда | `lib/sub_links.sh` | [cluster](CLUSTER.md) | 🟡 |
| [P-34](PROTOCOLS.md#p-34) | Онлайн складывался по протоколам: один клиент считался трижды | `lib/online.sh` | [protocols](PROTOCOLS.md) | ✅ |
| [P-33](PROTOCOLS.md#p-33) | Онлайн Xray считал историю IP: один телефон = 5–11 «устройств» | `lib/protocols.sh` | [protocols](PROTOCOLS.md) | ✅ |
| [P-17](PROTOCOLS.md#p-17) | Трафик/онлайн TUIC читают `metadata.user`, которого нет | `lib/protocols.sh` | [protocols](PROTOCOLS.md) | ✅ |
| [P-18](PROTOCOLS.md#p-18) | IP-трекинг только по журналу Hysteria — от него зависят тарифы | `lib/ip_tracking.sh` | [protocols](PROTOCOLS.md) | 🟡 |
| [P-19](BILLING.md#p-19) | Покупка тарифа обнуляет персональный тариф скорости | `lib/tgbot_client.sh` | [billing](BILLING.md) | ✅ |
| [P-20](BILLING.md#p-20) | Двойное зачисление ЮMoney: проверка и запись разнесены | `lib/yoomoney.sh` | [billing](BILLING.md) | ✅ |
| [P-21](OPS.md#p-21) | `stats.dat` правится без блокировки, кроны пересекаются | `lib/traffic.sh` | [ops](OPS.md) | ✅ |
| [P-35](OPS.md#p-35) | Трафик Xray в менеджере обновлялся раз в полчаса — выглядел зависшим | `lib/traffic.sh` | [ops](OPS.md) | ✅ |
| [P-22](CLUSTER.md#p-22) | Кластерная сумма трафика немонотонна, free-план строит на ней разницу | `lib/freeplan.sh` | [cluster](CLUSTER.md) | 🟡 |
| [P-28](WEBAPP.md#p-28) | Резервный провайдер курсов мёртв: цепочка фактически из одного | `app/Services/RatesService.php` | [webapp](WEBAPP.md) | 🟡 |
| [P-10](LIMITS.md#p-10) | tc-классы привязаны к имени юзера из `users.db` | `lib/perf.sh` | [limits](LIMITS.md) | 🟢 |
| [P-12](OPS.md#p-12) | Возможный двойной счёт скорости на релейном трафике | `lib/publish.sh` | [ops](OPS.md) | 🟢 |
| [P-23](LIMITS.md#p-23) | `abuse.dat` растёт вечно | `lib/antiabuse.sh` | [limits](LIMITS.md) | ✅ |
| [P-24](CLUSTER.md#p-24) | Хвосты удалённого профиля достаются одноимённому новому | `lib/users.sh` | [cluster](CLUSTER.md) | 🟢 |
| [P-25](OPS.md#p-25) | Web API не знает про Trojan | `webapi/wa_dispatch.py` | [ops](OPS.md) | ✅ |
| [P-39](OPS.md#p-39) | Бот отправлял всех на сайт одного оператора | `lib/tgbot_daemon.sh` | [ops](OPS.md) | ✅ |
| [P-29](WEBAPP.md#p-29) | `topup:watch-ton` рапортует о зачислении, которого не было | `app/Services/TonWatcher.php` | [webapp](WEBAPP.md) | ✅ |
| [P-36](OPS.md#p-36) | `authmap.dat` растёт вечно, а его читает каждый перерасчёт онлайна | `lib/ip_tracking.sh` | [ops](OPS.md) | ✅ |
| [P-30](WEBAPP.md#p-30) | `laravel.log` без ротации, туда же пишут прогоны тестов | `.env` | [webapp](WEBAPP.md) | ✅ |
| [P-40](WEBAPP.md#p-40) | Caddy резал PUT и DELETE: админка не сохранялась | `/etc/caddy/extra/00-common.caddy` | [webapp](WEBAPP.md) | ✅ |
| [P-31](CLUSTER.md#p-31) | Недоступный пир никак себя не проявлял в менеджере | `lib/cluster.sh` | [cluster](CLUSTER.md) | ✅ |
| [P-41](LIMITS.md#p-41) | Жёсткая проверка снимает лимит устройств внутри ноды | `lib/devlimits.sh` | [limits](LIMITS.md) | ✅ |
| [P-42](LIMITS.md#p-42) | Оплата тарифа в боте затирает докупленные устройства | `lib/tgbot_client.sh` | [limits](LIMITS.md) | ✅ |
| [P-43](OPS.md#p-43) | Спидометр залипал на сотнях Мбит/с: mawk обрезал кумулятив до 2^31-1 | `lib/traffic.sh` | [ops](OPS.md) | ✅ |
| [P-44](LIMITS.md#p-44) | При превышении по кластеру кикали все ноды сразу | `lib/devlimits.sh` | [limits](LIMITS.md) | ✅ |
| [P-45](LIMITS.md#p-45) | Одно устройство считалось за столько, на скольких нодах видно | `lib/publish.sh` | [limits](LIMITS.md) | ✅ |
| [P-46](OPS.md#p-46) | Открытый TUI публикует статистику своим — старым — кодом | `lib/cluster.sh` | [ops](OPS.md) | ✅ |
| [P-47](OPS.md#p-47) | Кроны наслаивались друг на друга: 100% CPU из одних форков | `lib/cron.sh` | [ops](OPS.md) | ✅ |
| [P-48](OPS.md#p-48) | Открытое меню менеджера стоит ноде полъядра | `lib/online.sh` | [ops](OPS.md) | ✅ |
| [P-50](PROTOCOLS.md#p-50) | Trojan/TUIC/HY2 держались на insecure-флаге, которого у клиентов больше нет | `lib/protocols.sh` | [protocols](PROTOCOLS.md) | ✅ |
| [P-49](OPS.md#p-49) | Модуль, выпавший из состава, остаётся на ноде навсегда | `install.sh` | [ops](OPS.md) | ✅ |
| [P-51](PROTOCOLS.md#p-51) | Hysteria2 на ноде «жив», но снаружи её домен его не отдаёт | `lib/cluster.sh` | [protocols](PROTOCOLS.md) | 🟡 |

Следующий свободный номер — **P-52**.
