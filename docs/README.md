# Документация hy2-manager

Четыре папки, у каждой свой `README.md` со своей таблицей. Разделены по одному
признаку — **степени реальности**: работает / известно, что сломано / решено
делать.

| Папка | Что внутри | Когда сюда идти |
|---|---|---|
| [guide/](guide/README.md) | Как работает то, что **уже написано**: API, протоколы, онлайн, лимиты, бот, оплаты, эксплуатация | Правишь код или разбираешься, как устроена фича |
| [issues/](issues/README.md) | **Реестр проблем** `P-NN`: что не работает или работает не так, как обещает документ темы | Столкнулся со странностью; нашёл новую проблему; выбираешь, что чинить |
| [design/](design/README.md) | Спроектировано, **кода нет** | Берёшься за большую фичу, у которой уже есть проект |

## Куда идти с вопросом

| Вопрос | Куда |
|---|---|
| Как мини-аппу получить/поменять данные юзера | [guide/API.md](guide/API.md) |
| Откуда у юзера ключи VLESS/TUIC/Trojan и почему они такие | [guide/MULTIPROTOCOL.md](guide/MULTIPROTOCOL.md) |
| Почему VLESS в подписке два и чем `VLESS-X` отличается от `VLESS` | [guide/MULTIPROTOCOL.md](guide/MULTIPROTOCOL.md#второй-vless-xhttp-как-резерв-а-не-замена) |
| Почему юзер «в сети» / откуда цифры трафика и спидометра | [guide/ONLINE.md](guide/ONLINE.md) |
| Почему скорость не режется (или режется не так) | [guide/SPEED-LIMITS.md](guide/SPEED-LIMITS.md) |
| Настройка на соседней ноде другая — это баг? | [guide/CLUSTER-SCOPE.md](guide/CLUSTER-SCOPE.md) |
| Как ноды вообще разговаривают и по какому каналу что посылать | [guide/CLUSTER-CHANNELS.md](guide/CLUSTER-CHANNELS.md) |
| Что будет, если взломают обмен между нодами | [guide/CLUSTER-CHANNELS.md](guide/CLUSTER-CHANNELS.md#безопасность) |
| Оплата пришла, доступа нет | [guide/YOOMONEY.md](guide/YOOMONEY.md), [issues/BILLING.md](issues/BILLING.md) |
| Удалил юзера, а подписка работает | [issues/CLUSTER.md#p-13](issues/CLUSTER.md#p-13) |
| Откуда у юзера число устройств и что оно ограничивает | [guide/DEVICE-LIMITS.md](guide/DEVICE-LIMITS.md) |
| Лимит устройств не держит | [issues/LIMITS.md#p-16](issues/LIMITS.md#p-16), [#p-41](issues/LIMITS.md#p-41) |
| Файлы и логи растут, что чистить | [guide/MAINTENANCE.md](guide/MAINTENANCE.md) |

Список модулей и «тема → какой `lib/*.sh` править» — в корневом
[CLAUDE.md](../CLAUDE.md). Здесь — только документы.

## Правила

- **Новая фича = новый документ в [guide/](guide/README.md) + строка в его
  таблице.** Документ темы читается ДО правки её кода.
- **Нашёл проблему — строка в [issues/](issues/README.md)**, даже если чинить не
  собираешься. Починил — правь статус там же, запись не удаляй.
- У каждой папки (и подпапки) есть `README.md`: что внутри, зачем, в каком
  порядке читать. Без него папку заводить нельзя.
- Документ описывает **замысел и как оно устроено**, а не пересказ кода строка в
  строку. Ссылка на функцию и файл лучше копии кода — копия устареет.

## Куда что переехало (реорганизация 27.07.2026)

Плоский список из 20 файлов разложен по папкам. Старые пути:

| Было | Стало |
|---|---|
| `docs/ISSUES.md` | [issues/](issues/README.md) — разбит по темам, номера `P-NN` сохранены |
| `docs/08-multiprotocol.md` | [guide/MULTIPROTOCOL.md](guide/MULTIPROTOCOL.md) |
| `docs/09-online-activity.md` | [guide/ONLINE.md](guide/ONLINE.md) |
| `docs/10-multiprotocol-limits.md` | [guide/SPEED-LIMITS.md](guide/SPEED-LIMITS.md) |
| `docs/API.md`, `MAINTENANCE.md`, `NOTIFICATIONS.md`, `YOOMONEY.md`, `DEMO-KEYS.md`, `BOT-START.md`, `CLUSTER-SCOPE.md` | [guide/](guide/README.md) под теми же именами |
| `docs/PLACEMENT/` | [design/PLACEMENT/](design/PLACEMENT/README.md) |
