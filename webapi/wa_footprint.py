#!/usr/bin/env python3
"""Полный след пользователя на узле: что о нём лежит в КАЖДОМ файле данных.

Зачем. Кабинет показывает человеку, что о нём хранится
(docs/guide/DATA-RETENTION.md). Пересказывать список файлов на той стороне
нельзя: он разъедется с кодом при первой же новой фиче, и экран начнёт врать
уверенным голосом. Поэтому список живёт ЗДЕСЬ, рядом с самими файлами.

Полнота проверяется машиной, а не памятью автора. `KNOWN` перечисляет всё
содержимое `DATA_DIR`; чего в нём нет — попадает в ответ отдельным списком
`undeclared`. Появился новый файл — кабинет сам скажет «тут есть что-то, чего
мы вам не показываем», и это увидит первый же дотошный пользователь.

Секреты не отдаются никогда: пароль профиля, токены подписки и пароли слотов
здесь только НАЗВАНЫ (`secrets`), значений нет. Знать, что пароль на узле
лежит открытым текстом, человек имеет право; получить его через API кабинета —
нет.
"""

import os
import re
import subprocess
import time

from wa_core import DATA_DIR, MANAGER_DIR, PEERS_DIR, data_path, pipe_rows, read_lines

# Сколько строк журнала просматриваем. Журнал живёт три дня и на людной ноде
# это сотни тысяч строк: без потолка ручка кабинета читала бы гигабайты.
JOURNAL_SCAN_LINES = 20000
JOURNAL_SAMPLE = 20

# Файлы DATA_DIR, про которые мы знаем, ЧТО в них про пользователя.
# Формат: имя → (что это человеческим языком, есть ли там персональные данные).
# «False» — файл про узел, а не про человека; он всё равно перечислен, чтобы
# список был полным и проверяемым.
KNOWN = {
    "users.db": ("Имя профиля и его пароль", True),
    "subtokens.db": ("Токен ссылки-подписки", True),
    "slotpass.db": ("Пароли отдельных ссылок-устройств", True),
    "tgusers.dat": ("Связка «аккаунт Telegram ↔ профиль» и когда её сделали", True),
    "stats.dat": ("Счётчики трафика", True),
    "ips.dat": ("Адреса подключения: адрес, впервые, последний раз, сколько раз", True),
    "authmap.dat": ("Живая таблица «профиль → адрес» последних подключений", True),
    "slotmap.dat": ("Какой слот занят каким адресом", True),
    "subips.dat": ("Адреса, с которых скачивали подписку по ссылке", True),
    "subapps.dat": ("Чем скачивали подписку: приложение, его версия, ОС и модель устройства", True),
    "subapps_seen.dat": ("О каком устройстве вам уже присылали предупреждение", True),
    "expiry.dat": ("До какого числа действует доступ", True),
    "expiry_ts.dat": ("Когда срок выставили в последний раз", True),
    "disabled.dat": ("Отключён ли профиль вручную", True),
    "speed.dat": ("Скорость за последний интервал", True),
    "rates.dat": ("Скорость для спидометра", True),
    "rates_prev.dat": ("Прошлый снимок счётчиков для расчёта скорости", True),
    "activity.dat": ("Активен ли профиль прямо сейчас", True),
    "activity_prev.dat": ("Прошлый снимок трафика для расчёта активности", True),
    "traffic_prev.dat": ("Прошлый снимок трафика", True),
    "abuse.dat": ("Балл подозрения на общий доступ", True),
    "abuse_obs.dat": ("Наблюдения, из которых считается балл", True),
    "freeplan.dat": ("Состояние бесплатного тарифа и расход по нему", True),
    "userlimits.dat": ("Лимиты: устройства, скорость, жёсткая проверка", True),
    "userlimits_ts.dat": ("Когда лимиты меняли", True),
    "userlimits.dat.bak.1784284151": ("Резервная копия файла лимитов", True),
    "userlimits.dat.bak2.1784284830": ("Резервная копия файла лимитов", True),
    "authlimits.dat": ("Снимок лимитов для скрипта аутентификации", True),
    "demos.db": ("Выданные демо-ключи", True),
    "cluster_users": ("Список профилей, заведённых на этом узле", True),
    "notify_state.dat": ("Когда бот присылал напоминание о сроке", True),
    "botnotify.dat": ("Очередь уведомлений бота", True),
    "botcodes.dat": ("Одноразовые коды привязки бота", True),
    "chandm_map.dat": ("Служебная привязка чата бота к аккаунту Telegram", True),
    "limit.log": ("Журнал срабатываний лимита устройств", True),
    "webapi_access.log": ("Аудит запросов к API: путь запроса содержит имя профиля", True),
    "self.stats": ("Сводка узла для соседей", False),
    "cluster_state.dat": ("Состояние соседних узлов", False),
    "cluster.conf": ("Список узлов кластера", False),
    "cluster.secret": ("Общий секрет кластера", False),
    "cluster_pwreset.dat": ("Очередь смены паролей по кластеру", False),
    "node.conf": ("Настройки этого узла", False),
    "bot.conf": ("Настройки бота", False),
    "bot.offset": ("Указатель прочитанных сообщений бота", False),
    "webapi.conf": ("Настройки API", False),
    "webapi.keys": ("Ключи доступа к API", False),
    "tariffs.conf": ("Каталог тарифов", False),
    "protocols.conf": ("Настройки протоколов", False),
    "proto.secret": ("Ключи протоколов", False),
    "klimit.conf": ("Настройки ограничения скорости", False),
    "klimit.sh": ("Скрипт ограничения скорости", False),
    "klimit_reconcile.sig": ("Отпечаток применённых правил скорости", False),
    "hysteria-auth.sh": ("Скрипт аутентификации", False),
    "api_secret": ("Секрет API протоколов", False),
    "last_log_ts": ("Метка последнего разбора журнала", False),
    "sublog_ts": ("Метка последнего разбора лога подписок", False),
    "speed_ts": ("Метка последнего замера скорости", False),
    "traffic_refresh.ts": ("Метка последнего пересчёта трафика", False),
    "peers": ("Копии данных соседних узлов", True),
    "onlineips.dat": ("Осиротевший файл прежней схемы онлайна: «профиль → адрес». "
                      "Никто его больше не пишет и не читает (issues/OPS.md P-72)", True),
    "period_days.dat": ("Выбранный в боте срок покупки, по аккаунту Telegram", True),
    "proto": ("Конфиги и сертификаты протоколов", False),
}


def _row_field(path, user, index, sep="|"):
    for parts in pipe_rows(path, index + 1):
        if parts[0] == user:
            return parts[index]
    return None


def _colon_has(path, user):
    for line in read_lines(path):
        if line.startswith(user + ":"):
            return True
    return False


def _count_matching(path, user):
    """Сколько строк файла упоминают этого пользователя. Для журналов и логов,
    где строка — событие, а не запись «одна на юзера»."""
    n = 0
    for line in read_lines(path):
        if user in line:
            n += 1
    return n


def ips_by_node(user):
    """Адреса пользователя по узлам: сначала этот, потом копии соседей.

    Разделение принципиальное. Строки этого узла мы можем удалить по просьбе
    человека; строки соседа — его копия, удалить её здесь бессмысленно (вернётся
    ближайшей синхронизацией), она уйдёт сама по сроку на своём узле. Свалив всё
    в один список, мы бы обещали удаление там, где его нет.
    """
    out = []
    local = [_ip_row(r) for r in pipe_rows(data_path("ips.dat"), 4) if r[0] == user]
    out.append({"node": _node_label(), "self": True, "rows": [r for r in local if r]})

    try:
        names = sorted(os.listdir(PEERS_DIR))
    except OSError:
        names = []
    for name in names:
        if not name.endswith(".ips"):
            continue
        rows = [_ip_row(r) for r in pipe_rows(os.path.join(PEERS_DIR, name), 4) if r[0] == user]
        rows = [r for r in rows if r]
        if rows:
            out.append({"node": name[:-4], "self": False, "rows": rows})

    return out


def _ip_row(parts):
    try:
        return {"ip": parts[1], "first_seen": int(parts[2]), "last_seen": int(parts[3]),
                "count": int(parts[4]) if len(parts) > 4 else 1}
    except (ValueError, IndexError):
        return None


def _node_label():
    from wa_core import read_kv
    node = read_kv(data_path("node.conf"))
    return node.get("NODE_LABEL") or node.get("NODE_NAME") or "этот узел"


def ips_retention_days():
    """Срок хранения адресов — из самого кода менеджера, не константой здесь:
    иначе кабинет однажды начнёт обещать срок, который давно другой."""
    return _read_setting("lib/ip_tracking.sh", r'IPS_RETENTION_DAYS="\$\{IPS_RETENTION_DAYS:-(\d+)\}"')


def journal_retention_days():
    return _read_setting("lib/ip_tracking.sh", r'JOURNAL_RETENTION_DAYS="\$\{JOURNAL_RETENTION_DAYS:-(\d+)\}"')


def _read_setting(rel_path, pattern):
    try:
        with open(os.path.join(MANAGER_DIR, rel_path), encoding="utf-8") as fh:
            m = re.search(pattern, fh.read())
            return int(m.group(1)) if m else None
    except OSError:
        return None


def journal_trace(user):
    """Что о человеке лежит в журнале systemd: сколько строк и как они выглядят.

    Строки подключений Hysteria («адрес + имя профиля») выключить нельзя — из
    них собирается ips.dat. Зато их можно показать: человек видит ровно то, что
    видит администратор. Удалить их выборочно невозможно — journald режет
    журнал целиком по сроку, и это честнее написать, чем изображать кнопку.
    """
    try:
        out = subprocess.run(
            ["journalctl", "-u", "hysteria-server", "-n", str(JOURNAL_SCAN_LINES),
             "--no-pager", "-o", "cat"],
            capture_output=True, text=True, timeout=20,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return {"available": False}

    # Пробел после двоеточия в JSON-логе Hysteria есть, но обещать его нельзя:
    # версии пишут по-разному, а тихо посчитать ноль строк — худший исход для
    # экрана, который обещает показать всё.
    needle = re.compile(r'"id":\s*"%s"' % re.escape(user))
    lines = [ln for ln in out.splitlines() if needle.search(ln)]
    sample = []
    for line in lines[-JOURNAL_SAMPLE:]:
        ip = re.search(r'"addr":\s*"([0-9a-fA-F:.]+)', line)
        event = "подключение" if "client connected" in line else (
            "отключение" if "client disconnected" in line else "событие")
        ts = re.match(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)", line)
        sample.append({"ts": ts.group(1) if ts else None,
                       "ip": ip.group(1) if ip else None, "event": event})

    return {"available": True, "scanned_lines": JOURNAL_SCAN_LINES,
            "matched": len(lines), "sample": sample,
            "retention_days": journal_retention_days(),
            "deletable": False}


def footprint(user):
    """Полный след: запись на каждый файл данных, где есть этот человек."""
    records = []

    def add(file, present, detail=None):
        what, personal = KNOWN.get(file, (file, True))
        if not personal:
            return
        records.append({"file": file, "what": what,
                        "present": bool(present), "detail": detail})

    add("users.db", _colon_has(data_path("users.db"), user), "имя профиля и пароль к нему")
    add("subtokens.db", _colon_has(data_path("subtokens.db"), user))
    add("slotpass.db", _row_field(data_path("slotpass.db"), user, 0) is not None)

    tg = None
    for parts in pipe_rows(data_path("tgusers.dat"), 2):
        if len(parts) > 1 and parts[1] == user:
            tg = parts
            break
    add("tgusers.dat", tg is not None,
        "аккаунт Telegram №%s, привязан %s" % (tg[0], _stamp(tg[2])) if tg and len(tg) > 2 else None)

    stats = _row_field(data_path("stats.dat"), user, 1)
    add("stats.dat", stats is not None, "счётчик передано/принято")

    local_ips = sum(1 for r in pipe_rows(data_path("ips.dat"), 2) if r[0] == user)
    add("ips.dat", local_ips, "адресов записано: %d" % local_ips)

    authmap = sum(1 for r in pipe_rows(data_path("authmap.dat"), 2) if r[0] == user)
    add("authmap.dat", authmap, "строк подключения за последние двое суток: %d" % authmap)

    slots = sum(1 for r in pipe_rows(data_path("slotmap.dat"), 2) if r[0] == user)
    add("slotmap.dat", slots, "занятых слотов в записи: %d" % slots)

    for name, note in (("expiry.dat", "срок доступа"), ("expiry_ts.dat", "когда срок меняли"),
                       ("disabled.dat", "отключён вручную"), ("speed.dat", "скорость"),
                       ("rates.dat", "скорость для спидометра"), ("rates_prev.dat", None),
                       ("activity.dat", "активен ли сейчас"), ("activity_prev.dat", None),
                       ("traffic_prev.dat", None), ("abuse.dat", "балл подозрения на общий доступ"),
                       ("abuse_obs.dat", None), ("freeplan.dat", "состояние бесплатного тарифа"),
                       ("userlimits.dat", "лимиты"), ("userlimits_ts.dat", None),
                       ("authlimits.dat", None), ("cluster_users", None),
                       ("notify_state.dat", "когда напоминали о сроке")):
        add(name, _row_field(data_path(name), user, 0) is not None, note)

    for name in ("userlimits.dat.bak.1784284151", "userlimits.dat.bak2.1784284830"):
        add(name, _row_field(data_path(name), user, 0) is not None, "старая копия файла лимитов")

    subips = 0
    tokens = {line.partition(":")[2] for line in read_lines(data_path("subtokens.db"))
              if line.startswith(user + ":")}
    for parts in pipe_rows(data_path("subips.dat"), 2):
        if parts[0] in tokens:
            subips += 1
    add("subips.dat", subips, "адресов, скачивавших вашу подписку: %d" % subips)

    # Токены соседей тоже наши: их подписку отдаёт наш же Caddy, и разбор
    # заголовков записал их сюда (docs/guide/SUB-CLIENTS.md).
    all_tokens = set(tokens)
    try:
        for name in sorted(os.listdir(PEERS_DIR)):
            if name.endswith(".subtokens"):
                all_tokens.update(
                    line.partition(":")[2]
                    for line in read_lines(os.path.join(PEERS_DIR, name))
                    if line.startswith(user + ":"))
    except OSError:
        pass
    subapps = sum(1 for parts in pipe_rows(data_path("subapps.dat"), 9) if parts[0] in all_tokens)
    add("subapps.dat", subapps, "устройств и приложений, скачивавших вашу подписку: %d" % subapps)
    seen = sum(1 for parts in pipe_rows(data_path("subapps_seen.dat"), 3) if parts[0] in all_tokens)
    add("subapps_seen.dat", seen, "устройств, о которых вам уже писали: %d" % seen)

    add("demos.db", _colon_has(data_path("demos.db"), user) or _row_field(data_path("demos.db"), user, 0) is not None)

    limit_hits = _count_matching(data_path("limit.log"), user + ":")
    add("limit.log", limit_hits, "строк о срабатывании лимита: %d" % limit_hits)

    api_hits = _count_matching(data_path("webapi_access.log"), "/" + user)
    add("webapi_access.log", api_hits, "запросов кабинета про вас: %d" % api_hits)

    peers_files = 0
    try:
        for name in os.listdir(PEERS_DIR):
            path = os.path.join(PEERS_DIR, name)
            if any(r[0] == user for r in pipe_rows(path, 1)) or _colon_has(path, user):
                peers_files += 1
    except OSError:
        pass
    add("peers", peers_files, "файлов-копий с соседних узлов, где вы есть: %d" % peers_files)

    return {
        "username": user,
        "node": _node_label(),
        "records": records,
        "secrets": [
            {"what": "Пароль профиля", "where": "users.db",
             "how": "лежит открытым текстом: из него собираются ссылки подписки, хэш тут не подходит"},
            {"what": "Токен ссылки-подписки", "where": "subtokens.db", "how": "открытым текстом, это и есть адрес вашей подписки"},
            {"what": "Пароли ссылок-устройств", "where": "slotpass.db", "how": "открытым текстом, по той же причине"},
        ],
        "undeclared": _undeclared(),
        "ips": {"by_node": ips_by_node(user), "retention_days": ips_retention_days(),
                "deletable_older_than_hours": 24},
        "journal": journal_trace(user),
    }


def _undeclared():
    """Файлы данных, которых нет в KNOWN. Пустой список — обещание «показали всё»
    сдержано; непустой — кто-то завёл файл и забыл про этот экран."""
    try:
        names = os.listdir(DATA_DIR)
    except OSError:
        return []

    return sorted(n for n in names
                  if not n.startswith(".") and not n.endswith(".lock") and n not in KNOWN)


def _stamp(value):
    try:
        return time.strftime("%d.%m.%Y", time.localtime(int(value)))
    except (ValueError, TypeError):
        return "—"
