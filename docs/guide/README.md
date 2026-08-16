# Как это работает

Документы про то, что **уже написано и работает на нодах**. Колонка «Код» — файлы,
которые правишь по этому документу; ищи по ней, а не обходом дерева.

Правило: читай документ темы ДО правки её кода. Новая фича — новый документ здесь
плюс строка в таблице.

| Документ | О чём | Код |
|---|---|---|
| [API.md](API.md) | **Web API менеджера** для внешних приложений (мини-апп, биллинг, бот, панель): ключи и scopes, все эндпоинты с примерами, приём платежей Stars | `webapi/*.py`, `webapi/dispatch.sh`, `lib/webapi.sh` |
| [MULTIPROTOCOL.md](MULTIPROTOCOL.md) | **Мультипротокол**: VLESS+REALITY, SS-2022, Trojan/WS (Xray), TUIC v5 (sing-box) рядом с Hysteria, единая подписка, деривация кредов | `lib/protocols.sh`, `lib/ui_protocols.sh` |
| [ONLINE.md](ONLINE.md) | **Онлайн-статус и активность**: активность по всем протоколам, гистерезис, live-пуш через SSE, спидометр | `lib/online.sh`, `lib/publish.sh`, `webapi/wa_online.py` |
| [DEVICE-LIMITS.md](DEVICE-LIMITS.md) | **Устройства**: что менеджер считает устройством, где хранится персональное число и как оно едет по кластеру, три механизма применения (кик по адресам, жёсткая проверка по нодам, анти-абуз), чего они не держат | `lib/limits.sh`, `lib/devlimits.sh`, `lib/online.sh`, `lib/antiabuse.sh` |
| [SUB-HEADERS.md](SUB-HEADERS.md) | **Оформление подписки**: что клиент показывает поверх ключей — расход и срок (`subscription-userinfo`), анонс под план юзера (демо / бесплатный / платный), кнопки ссылок, свободный список любых параметров клиента; как заголовок делается персональным и чем это стоит | `lib/node.sh`, `lib/sub_links.sh`, `lib/caddy.sh`, `lib/ui_subscription.sh` |
| [SLOTS.md](SLOTS.md) | **Слоты**: устройство опознаётся по креду, а не по адресу — у каждой доп. ссылки подписки свой пароль Hysteria. Реализована фаза A (отказа на занятом слоте ещё нет) | `lib/sub_links.sh`, `lib/migration.sh`, `lib/users.sh` |
| [SPEED-LIMITS.md](SPEED-LIMITS.md) | **Лимит скорости для всех протоколов**: tc HTB + fq_codel, пер-IP тарифные классы | `lib/perf.sh`, `lib/ui_perf.sh` |
| [PEER-HEALTH.md](PEER-HEALTH.md) | **Здоровье пиров**: почему недоступная нода была не видна в TUI, диагноз пира (DNS / TLS / секрет), `.health`, баннер в главном меню | `lib/cluster.sh`, `lib/config.sh`, `hy2-manager.sh` |
| [CLUSTER-PROTOCOLS.md](CLUSTER-PROTOCOLS.md) | **Состояние протоколов по кластеру**: снимок «включён / слушает / порт» с каждой ноды, обмен через `/cluster/protocols`, экран в меню протоколов и почему внешней пробы портов нет | `lib/protocols.sh`, `lib/cluster.sh`, `lib/ui_protocols.sh` |
| [CLUSTER-SCOPE.md](CLUSTER-SCOPE.md) | **Область действия настроек в кластере**: локальный профиль против кластерного, что уезжает на другие ноды, правила для нового синхронизируемого поля | `lib/cluster.sh`, `lib/limits.sh`, `lib/ui_users.sh` |
| [SUB-PREFER.md](SUB-PREFER.md) | **Предпочитаемый ключ подписки**: клиент выбирает сервер позицией в списке (верхний ключ), поле `prefer` рядом с лимитами, `sub_prefer_sort`, выставление через API | `lib/limits.sh`, `lib/sub_links.sh`, `webapi/dispatch.sh` |
| [NOTIFICATIONS.md](NOTIFICATIONS.md) | **Уведомления бота**: подписка (менеджер) и баланс (надстройка), кастомные эмодзи, канал-DM, как добавить новое уведомление | `lib/notify.sh`, `lib/tgbot*.sh` |
| [SALES.md](SALES.md) | **Границы продажи**: менеджер — источник правды по каталогу и ценам, надстройка владеет деньгами покупателя; что решает оператор, а что код | `lib/tariffs.sh`, `lib/tgbot*.sh`, `webapi/*` |
| [TARIFF-PRICING.md](TARIFF-PRICING.md) | **Цена тарифа**: где живёт, мультивалютность, два режима звёздной цены (`fixed` / из рублёвой по курсу) — одна формула для бота и API | `lib/tariffs.sh`, `lib/tgbot_client.sh`, `webapi/wa_dispatch.py` |
| [BOT-MODULES.md](BOT-MODULES.md) | **Модули бота**: продажу, уведомления и админ-панель можно включать по отдельности (`BOT_MODULES`); что при этом остаётся ядром | `lib/tgbot.sh`, `lib/tgbot_client.sh`, `lib/tgbot_daemon.sh`, `lib/tgbot_menu.sh` |
| [BOT-START.md](BOT-START.md) | **`/start` и реферальные ссылки**: бот передаёт команду мини-аппу, тот шлёт приветствие и начисляет бонус (его сторона — в его документации) | `lib/tgbot_client.sh`, `lib/tgbot_daemon.sh` |
| [YOOMONEY.md](YOOMONEY.md) | **Приём рублей через ЮMoney**: продажа тарифов без платёжного провайдера (личный кошелёк, метка платежа, опрос истории) | `lib/yoomoney.sh`, `lib/tgbot_client.sh`, `lib/tgbot_menu.sh` |
| [DEMO-KEYS.md](DEMO-KEYS.md) | **Демо-ключи**: `demo_create()`, таблица `DEMOS_DB`, выбор ноды-приёмника (`DEMO_NODES`), выдача на соседней ноде, enforcement капов минутным тиком, грейс-сутки и авто-purge | `lib/demo.sh`, `webapi/hy2-webapi.py` |
| [CRON.md](CRON.md) | **Периодические задачи и цена одного тика**: расписание кронов, замок `cron_lock` (один живой прогон на режим), правила против форков в циклах, отказ от лишней работы, ориентиры по времени | `lib/cron.sh`, `hy2-manager.sh`, `lib/config.sh`, `lib/online.sh` |
| [MAINTENANCE.md](MAINTENANCE.md) | **Эксплуатационная гигиена**: ротация логов, временные файлы с `$BASHPID`, retention истории IP, пин и сверка версий ядер | `install.sh`, `lib/ip_tracking.sh`, `lib/publish.sh`, `lib/protocols.sh` |

## Порядок чтения для нового человека

1. [MULTIPROTOCOL.md](MULTIPROTOCOL.md) — что нода вообще раздаёт и откуда берутся
   ключи каждого протокола.
2. [CLUSTER-SCOPE.md](CLUSTER-SCOPE.md) — почему одна и та же настройка на соседней
   ноде может выглядеть иначе. Без этого кластерные баги выглядят мистикой.
3. [ONLINE.md](ONLINE.md) — как считается «юзер в сети» и трафик: на этих файлах
   стоят квоты, лимиты и спидометр.
4. [API.md](API.md) — если трогаешь мини-апп или биллинг.

Что из описанного здесь работает **не так, как написано**, — в
[../issues/](../issues/README.md). Документ темы описывает замысел, реестр —
известные расхождения с ним.
