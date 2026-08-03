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
| [SPEED-LIMITS.md](SPEED-LIMITS.md) | **Лимит скорости для всех протоколов**: tc HTB + fq_codel, пер-IP тарифные классы | `lib/perf.sh`, `lib/ui_perf.sh` |
| [PEER-HEALTH.md](PEER-HEALTH.md) | **Здоровье пиров**: почему недоступная нода была не видна в TUI, диагноз пира (DNS / TLS / секрет), `.health`, баннер в главном меню | `lib/cluster.sh`, `lib/config.sh`, `hy2-manager.sh` |
| [CLUSTER-SCOPE.md](CLUSTER-SCOPE.md) | **Область действия настроек в кластере**: локальный профиль против кластерного, что уезжает на другие ноды, правила для нового синхронизируемого поля | `lib/cluster.sh`, `lib/limits.sh`, `lib/ui_users.sh` |
| [NOTIFICATIONS.md](NOTIFICATIONS.md) | **Уведомления бота**: подписка (менеджер) и баланс (cibpn-webapp), кастомные эмодзи, канал-DM, как добавить новое уведомление | `lib/notify.sh`, `lib/tgbot*.sh` |
| [BOT-MODULES.md](BOT-MODULES.md) | **Модули бота**: продажу, уведомления и админ-панель можно включать по отдельности (`BOT_MODULES`); что при этом остаётся ядром | `lib/tgbot.sh`, `lib/tgbot_client.sh`, `lib/tgbot_daemon.sh`, `lib/tgbot_menu.sh` |
| [BOT-START.md](BOT-START.md) | **`/start` и реферальные ссылки**: бот передаёт команду мини-аппу, тот шлёт приветствие и начисляет бонус (полное описание — `cibpn-webapp/docs/BOT-START.md`) | `lib/tgbot_client.sh`, `lib/tgbot_daemon.sh` |
| [YOOMONEY.md](YOOMONEY.md) | **Приём рублей через ЮMoney**: продажа тарифов без платёжного провайдера (личный кошелёк, метка платежа, опрос истории) | `lib/yoomoney.sh`, `lib/tgbot_client.sh`, `lib/tgbot_menu.sh` |
| [DEMO-KEYS.md](DEMO-KEYS.md) | **Демо-ключи**: `demo_create()`, таблица `DEMOS_DB`, enforcement капов кроном, грейс-сутки и авто-purge | `lib/demo.sh`, `lib/ui_users.sh` |
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
