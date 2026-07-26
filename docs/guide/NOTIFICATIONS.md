# Система уведомлений бота (подписка + баланс)

Технический справочник по Telegram-уведомлениям. Рассчитан на то, чтобы человек
или нейросеть могли **настроить, отладить и дополнить** систему, не читая весь код.
Система распределена по двум репозиториям — большая часть здесь (hy2-manager),
уведомления о балансе — в надстройка (`docs/NOTIFICATIONS.md` там же).

---

## 1. Что делает система

Отправляет пользователю в Telegram:

| Событие | Кто шлёт | Триггер | Эмодзи |
|---|---|---|---|
| Активация/продление подписки (с датой окончания) | **менеджер** `lib/notify.sh` | любой extend через `bot_extend_user` | ⭐ |
| Напоминания об истечении (7д/3д/1д/12ч/1ч/30мин) | **менеджер** `lib/notify.sh` | cron `--notify-sweep` каждые 5 мин | ⭐ |
| Автоотключение по истечении | менеджер `lib/tgbot_daemon.sh` `bot_notify_expired` | `check_expired_users` | 🚫 |
| Зачисление на баланс | **надстройка** `TelegramNotifier` | обсервер `BalanceTransaction::created` | 💵 |
| Списание с баланса | **надстройка** `TelegramNotifier` | тот же обсервер | 🪙 |

Каждое уведомление доставляется **двумя каналами** (см. §5):
1. **личка бота** — всегда (если у пользователя есть привязка tg);
2. **«от лица канала»** — best-effort, в персональный чат прямых сообщений канала,
   с пометкой «перейти в бота». Работает только при выполненных предусловиях (§5).

---

## 2. Архитектура и поток данных

```
                      ┌─────────────────────── hy2-manager (bash) ───────────────────────┐
 продление (бот-оплата,│  bot_extend_user(user,days[,nonotify])                            │
 админ /add, dispatch  │    ├─ set_user_expiry            → expiry.dat / expiry_ts.dat     │
 из Laravel через      │    ├─ period_days_set(user,days) → period_days.dat  (для гейтов) │
 webapi/extend)        │    └─ bot_notify_activated(user,new_expiry)  ── ⭐ «действует до» │
                      │                                                                   │
 cron */5 --notify-sweep→ bot_notify_sweep()                                              │
                      │    для каждого user из expiry.dat:                                 │
                      │      left = end_of_day(expiry) - now                               │
                      │      пороги 7d/3d/1d/12h/1h/30m (гейты по period_days.dat)         │
                      │      дедуп: notify_state.dat  (user|end_ts|label)                  │
                      │      → notify_user()  ── ⭐ «скоро закончится»                      │
                      │                                                                   │
 входящее сообщение    │  bot_handle_update():                                             │
 в чат прямых сообщений│    if message.chat.is_direct_messages:                            │
 канала                │      chandm_topic_set(user_id, dm_chat_id, topic_id)              │
                      │        → chandm_map.dat  (tg_id|dm_chat_id|topic_id)               │
                      │                                                                   │
 notify_user(user,txt) │    ├─ tg_send(chat, txt)                    (личка)               │
                      │    └─ chandm_send(chat, txt)                (канал, +пометка)      │
                      └───────────────────────────────────────────────────────────────────┘
                                        chandm_map.dat  ← общий файл (chmod 644) →
                      ┌─────────────────────── надстройка (PHP) ───────────────────────┐
 credit()/debit()      │  BalanceService::apply → BalanceTransaction::create               │
                      │    └─ Observer::created → DB::afterCommit →                        │
                      │         TelegramNotifier::balanceMovement(tx)                      │
                      │           ├─ TelegramBot::sendMessage(tg_id, 💵/🪙 …)  (личка)      │
                      │           └─ читает chandm_map.dat → sendChannelDirect(…) (канал)   │
                      └───────────────────────────────────────────────────────────────────┘
```

Ключевая идея: **единая точка продления** `bot_extend_user` покрывает ВСЕ пути
выдачи срока (бот-оплата Stars, админ-команды, покупка за баланс из Laravel через
`webapi → dispatch.sh extend → bot_extend_user`). Поэтому уведомление об активации
шлётся один раз и одинаково независимо от источника. Прямой Stars-платёж в боте шлёт
свою расширенную карточку (с конфигом подключения) и передаёт `nonotify`, чтобы не
задваивать.

---

## 3. Файлы и функции

### hy2-manager
| Файл | Что там |
|---|---|
| `lib/notify.sh` | **вся новая логика**: `CE_MAP`/`ce()`, `fmt_date_dmy`, `bot_username`, `period_days_set/get`, `notify_user`, `chandm_send`, `chandm_topic_set`, `bot_notify_activated`, `bot_notify_sweep` |
| `lib/tgbot_client.sh` / `lib/tgbot_daemon.sh` | `bot_extend_user` (хук активации + `period_days_set`, флаг `nonotify`); `bot_handle_update` (захват topic канала); базовые `tg_api/tg_send/tg_esc/tg_user_chats/bot_get/bot_set/bot_token/bot_enabled` |
| `lib/expiry.sh` | `get_user_expiry`, `expiry_days_left`, `format_remaining`, `check_expired_users`→`bot_notify_expired` |
| `hy2-manager.sh` | подключает `notify` в `_required_libs`; CLI `--check-expiry` (зовёт `bot_notify_sweep`) и `--notify-sweep` |
| `lib/cron.sh` | ставит cron `*/5 --notify-sweep` (и `0 */6 --check-expiry`) |

### Файлы данных (в `$DATA_DIR`, по умолчанию `/etc/hysteria/manager`)
| Файл | Формат | Назначение |
|---|---|---|
| `expiry.dat` | `user\|YYYY-MM-DD` | дата окончания (источник правды по сроку) |
| `expiry_ts.dat` | `user\|epoch` | момент установки срока (кластер) |
| `period_days.dat` | `user\|days` | длина текущего периода — для гейтов «за 7д/за 1д» |
| `notify_state.dat` | `user\|end_ts\|label` | анти-дубли порогов; чистится по прошедшему `end_ts` |
| `chandm_map.dat` | `tg_id\|dm_chat_id\|topic_id` | привязка user→топик чата прямых сообщений канала (chmod 644, читает и Laravel) |
| `tgusers.dat` | `tg_id\|username\|ts` | привязка Telegram↔аккаунт; `tg_user_chats` = обратный поиск |
| `bot.conf` | `KEY=VALUE` | `BOT_TOKEN`, `BOT_USERNAME` (кэш getMe), `ADMIN_IDS` |

---

## 4. Эмодзи (кастомные из набора AdaptivePixelEmoji)

Telegram позволяет **боту** отправлять кастомные (премиум) эмодзи в тексте через
HTML-тег `<tg-emoji emoji-id="ID">BASE</tg-emoji>` при `parse_mode=HTML`. Их видят
все, премиум для просмотра не нужен. Проверено: этот бот успешно шлёт их.

### Как это реализовано
- **bash** (`lib/notify.sh`): ассоциативный массив `CE_MAP[base]=id` и функция
  `ce "⭐"` → `<tg-emoji emoji-id="5460980668378931880">⭐</tg-emoji>`; если base нет
  в карте — возвращает обычный юникод (фолбэк).
- **PHP** (`config/telegram.php` → `custom_emoji`, метод `TelegramNotifier::ce()`) —
  та же логика.

### Текущая карта (набор `AdaptivePixelEmoji`, id стабильны)
| base | назначение | custom_emoji_id |
|---|---|---|
| ⭐ | подписка/сроки | `5460980668378931880` |
| 💵 | зачисление баланса | `5372874186010158207` |
| 🪙 | списание баланса | `5318972874726339331` |
| 💬 | пометка «в бота» (канал) | `5296258510684712098` |
| 🎁 | (резерв, бонусы) | `5235695112419303615` |
| 🚫 | автоотключение | `5339428493992162714` |
| ⌛ / 🔔 / ❗️ | (резерв) | `5296482716567495148` / `5373136788900571050` / `5258382581375723416` |

### Как обновить/добавить эмодзи
1. Узнать id всех эмодзи набора:
   `curl -s "https://api.telegram.org/bot<TOKEN>/getStickerSet?name=AdaptivePixelEmoji"`
   — в `result.stickers[]` поля `emoji` (base) и `custom_emoji_id`.
2. Прописать пару в `CE_MAP` (`lib/notify.sh`) и/или в `config('telegram.custom_emoji')`.
3. id меняются только если автор пересоздал набор — тогда обновить всю карту.
4. Другой набор → сменить имя в `getStickerSet` и перезаполнить карту.

---

## 5. Доставка «от лица канала» (Direct Messages in Channels, Bot API 9.2)

Фича Telegram (авг 2025): у канала есть отдельный чат прямых сообщений (monoforum),
где у каждого пользователя свой **топик**; бот-админ канала может отвечать в топик
«от лица канала».

### Как отправить
`sendMessage` с:
- `chat_id` = **id чата прямых сообщений канала** (НЕ id канала) — это `message.chat.id`
  входящего, у которого `chat.is_direct_messages == true`;
- `direct_messages_topic_id` = **топик пользователя** (обязателен!) — из
  `message.direct_messages_topic.topic_id`;
- `text`, `parse_mode=HTML`.

### Откуда берётся мапинг
Только из входящих сообщений: `bot_handle_update` при `is_direct_messages==true`
пишет `chandm_topic_set(user.id, chat.id, topic_id)` → `chandm_map.dat`. Владелец
топика — `message.direct_messages_topic.user.id` (по API «currently always present»).

### Предусловия (без них канал-доставка молча пропускается)
1. В канале **включены Direct Messages** (настройка владельца).
2. Бот — **администратор канала** с правом `can_post_messages`.
3. Пользователь **уже написал** в чат канала (иначе топика нет — холодная рассылка
   невозможна by design).

### Пометка «в бота»
Канальная копия получает суффикс `💬 Управляйте подпиской в боте: @<username>`
(`bot_username()` / `config('telegram.bot_username')`). Личка бота такой пометки не
имеет (она и так «в боте»).

---

## 6. Пороги напоминаний (bot_notify_sweep)

`end_ts` = конец дня истечения (`YYYY-MM-DD 23:59:59`, срок дневной точности).
`left = end_ts - now`. Пороги (по убыванию), с гейтами по `period_days`:

| label | секунд | гейт (длина периода) |
|---|---|---|
| 7d | 604800 | `period_days > 8` |
| 3d | 259200 | `period_days >= 3` |
| 1d | 86400 | `period_days > 2` |
| 12h | 43200 | — |
| 1h | 3600 | — |
| 30m | 1800 | — |

**Правило отправки (важно):** за один проход собираем ВСЕ пройденные (`left<=secs`) и
прошедшие гейт пороги; шлём **одно** сообщение (если появился хоть один новый, ещё не
отправленный порог), а **все** пройденные пороги помечаем отправленными в
`notify_state.dat`. Это исключает «пачку» (7д+3д+1д разом) при первом проходе на уже
дозревшей подписке — одно напоминание на каждый переход через порог. Дедуп-ключ
включает `end_ts`, поэтому новая покупка (новая дата) естественно сбрасывает пороги.

**Частота:** cron `*/5 * * * * --notify-sweep`. Пороги 30мин/1ч ловятся только при
частом прогоне — не ставьте реже 5–10 минут.

---

## 7. Как дополнять

- **Новый тип уведомления (подписка):** добавить функцию в `lib/notify.sh` по образцу
  `bot_notify_activated` (собрать текст через `ce`/`fmt_date_dmy`, вызвать
  `notify_user "$user" "$text"`), и дёрнуть её из нужной точки (`lib/tgbot_daemon.sh` или
  cron-ветки `hy2-manager.sh`).
- **Новый тип уведомления (баланс/оплата):** в надстройка — метод в
  `TelegramNotifier`, вызвать из обсервера/сервиса **после коммита** (`DB::afterCommit`),
  best-effort (try/catch, не ломать деньги).
- **Изменить пороги:** правьте список `for pair in ...` и `case`-гейты в
  `bot_notify_sweep`. Помните про частоту cron для мелких порогов.
- **Изменить текст/эмодзи:** тексты — в `bot_notify_*`/`TelegramNotifier`; эмодзи — §4.
- **Другой канал доставки** (напр. email): добавьте ветку в `notify_user` (bash) и в
  `TelegramNotifier::deliver` (PHP).

---

## 8. Зависимости и подводные камни

- **jq** — парсинг апдейтов в `bot_handle_update` (захват topic канала).
- **`bot_enabled`** (есть токен + юнит) — все функции тихо выходят, если бот выключен.
- **`config:cache` в надстройка**: тесты при закэшированном конфиге стирают боевую БД
  (см. надстройка `docs/`), к уведомлениям прямого отношения нет, но помните.
- **`telegram.notifications_enabled`** (PHP) — глобальный выключатель; в тестах off,
  в проде on (env `TELEGRAM_NOTIFICATIONS_ENABLED`).
- **Идемпотентность баланса**: обсервер шлёт только на `created` (реальная вставка);
  повторный `credit/debit` с тем же `idempotency_key` не создаёт строку → не дублирует.
- **Канал-доставка** молчит без предусловий §5 — это норма, не ошибка.
- **Часовой пояс**: `end_ts` считается в TZ сервера (`date -d "... 23:59:59"`).
- **Перезапуск бота** (`systemctl restart hy2-bot`) нужен после правок `lib/*.sh`,
  чтобы демон подхватил код; cron-ветки (`--notify-sweep`) сорсят libs заново сами.

---

## 9. Ручная проверка

```bash
# Разово прогнать напоминания (безопасно — дедуп в notify_state.dat):
/bin/bash /opt/hy2-manager/hy2-manager.sh --notify-sweep

# Тест кастомного эмодзи в личку:
TOKEN=$(grep '^BOT_TOKEN=' /etc/hysteria/manager/bot.conf | cut -d= -f2-)
curl -s "https://api.telegram.org/bot$TOKEN/sendMessage" \
  --data-urlencode chat_id=<tg_id> --data-urlencode parse_mode=HTML \
  --data-urlencode 'text=<tg-emoji emoji-id="5460980668378931880">⭐</tg-emoji> тест'

# Обновить карту эмодзи из набора:
curl -s "https://api.telegram.org/bot$TOKEN/getStickerSet?name=AdaptivePixelEmoji"
```
