#!/usr/bin/env python3
# ================================================
# Онлайн-статус (с гистерезисом), скорость и SSE-поток статуса.
# Часть hy2-webapi (точка входа — webapi/hy2-webapi.py, контракт — docs/guide/API.md).
# ================================================
import base64
import hashlib
import hmac
import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.parse
import urllib.request
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from wa_core import *  # noqa: F403
from wa_core import _env_int, _online_lock, _online_last_active
from wa_users import *  # noqa: F403



def hysteria_online(user):
    """Онлайн ЭТОЙ ноды из локального API Hysteria (см. lib/api.sh). None = недоступен."""
    secret_file = data_path("api_secret")
    try:
        with open(secret_file, encoding="utf-8") as f:
            secret = f.read().strip()
    except OSError:
        return None
    port = 25580
    try:
        with open(CONFIG_YAML, encoding="utf-8", errors="replace") as f:
            block = re.search(r"^trafficStats:.*?(?=^\S|\Z)", f.read(), re.S | re.M)
        if block:
            m = re.search(r"listen:\s*\S*?(\d+)\s*$", block.group(0), re.M)
            if m:
                port = int(m.group(1))
    except OSError:
        pass
    req = urllib.request.Request(f"http://127.0.0.1:{port}/online",
                                 headers={"Authorization": secret})
    try:
        with urllib.request.urlopen(req, timeout=3) as resp:
            data = json.loads(resp.read().decode())
        return int(data.get(user, 0))
    except Exception:
        return None


def user_active_raw(user):
    """True, если менеджер СЕЙЧАС считает юзера активным хоть на ОДНОЙ ноде.
    Профиль = весь кластер, поэтому OR: локальный activity.dat (user|active|...)
    ИЛИ любой peers/*.stats (TAB, active = индекс 6). ВАЖНО: локальный active=0 НЕ
    прерывает проверку пиров — юзер простаивает тут, но может быть активен на
    другой ноде (иначе онлайн «ломался» при подключении к другой ноде)."""
    for line in read_lines(data_path("activity.dat")):
        parts = line.split("|")
        if parts and parts[0] == user:
            if len(parts) >= 2 and parts[1] == "1":
                return True
            break   # нашли локально, но неактивен — идём проверять пиров
    try:
        names = os.listdir(PEERS_DIR)
    except OSError:
        names = []
    for name in names:
        if not name.endswith(".stats"):
            continue
        for line in read_lines(os.path.join(PEERS_DIR, name)):
            parts = line.split("\t")
            if parts and parts[0] == user:
                if len(parts) >= 7 and parts[6].isdigit() and int(parts[6]) > 0:
                    return True
                break
    return False


def active_users_raw():
    """Кто активен СЕЙЧАС хоть на одной ноде — один проход по тем же файлам,
    что читает user_active_raw() поштучно. Нужен, когда статус спрашивают
    сразу про многих (дерево рефералов в мини-аппе)."""
    users = set()
    for line in read_lines(data_path("activity.dat")):
        parts = line.split("|")
        if len(parts) >= 2 and parts[1] == "1" and parts[0]:
            users.add(parts[0])
    try:
        names = os.listdir(PEERS_DIR)
    except OSError:
        names = []
    for name in names:
        if not name.endswith(".stats"):
            continue
        for line in read_lines(os.path.join(PEERS_DIR, name)):
            parts = line.split("\t")
            if len(parts) >= 7 and parts[0] and parts[6].isdigit() and int(parts[6]) > 0:
                users.add(parts[0])
    return users


def online_users():
    """Список онлайн с тем же гистерезисом, что и is_online(): активные сейчас
    плюс те, кто был активен в последние ONLINE_GRACE_SEC."""
    now = time.time()
    active = active_users_raw()
    with _online_lock:
        for user in active:
            _online_last_active[user] = now
        return sorted(
            user for user, seen in _online_last_active.items()
            if now - seen < ONLINE_GRACE_SEC
        )


def is_online(user):
    """«Онлайн сейчас» с гистерезисом: active сейчас ИЛИ active наблюдался в
    последние ONLINE_GRACE_SEC. Гистерезис держится в памяти демона (сбрасывается
    на рестарте — не критично)."""
    now = time.time()
    active = user_active_raw(user)
    with _online_lock:
        if active:
            _online_last_active[user] = now
            return True
        return (now - _online_last_active.get(user, 0.0)) < ONLINE_GRACE_SEC


# --- SSE live-пуш статуса онлайн ---
# Браузер не хранит ключ менеджера, поэтому Laravel (по своему Bearer-ключу)
# запрашивает у нас короткоживущий тикет на конкретного юзера, а EventSource
# открывает /v1/stream/online?ticket=… Тикет подписан секретом процесса (живёт в
# памяти, ротация на рестарте — тикеты короткие). Данные потока — только булев
# online одного юзера, чувствительность низкая.
_STREAM_SECRET = os.urandom(32)
STREAM_TICKET_TTL = _env_int("HY2M_STREAM_TICKET_TTL", 1800)  # с
STREAM_POLL_SEC = max(2, _env_int("HY2M_STREAM_POLL_SEC", 5))  # как часто watcher сверяет статус
STREAM_PING_SEC = max(10, _env_int("HY2M_STREAM_PING_SEC", 20))  # keepalive-комментарий
STREAM_HANDLED = object()  # сентинел: хендлер уже сам отдал ответ (стрим), respond() не нужен

# Общий watcher вместо опроса на каждого клиента: считает is_online только для
# юзеров, у кого есть активные подписчики, раз в STREAM_POLL_SEC, и будит хендлеры.
_stream_cv = threading.Condition()
_stream_subs = {}    # user -> число открытых SSE-подписчиков
_stream_state = {}   # user -> последний известный (online: bool, bps: int)
# Идея 17: вместо одного мгновенного bps копим ряд выборок (ts_сек, bps) за
# последние ~STREAM_SAMPLES_WINDOW опросов. Фронт плавно прогоняет стрелку по
# ним в реальном времени, вместо телепорта на новое число. Окно ограничено —
# при устоявшейся скорости старые точки вытесняются, память не растёт.
from collections import deque   # noqa: E402
STREAM_SAMPLES_WINDOW = max(2, _env_int("HY2M_STREAM_SAMPLES_WINDOW", 8))
_stream_samples = {}  # user -> deque[(ts_сек, bps)]


def make_stream_ticket(user):
    exp = int(time.time()) + STREAM_TICKET_TTL
    sig = hmac.new(_STREAM_SECRET, f"{user}:{exp}".encode(), hashlib.sha256).hexdigest()[:32]
    return base64.urlsafe_b64encode(f"{user}:{exp}:{sig}".encode()).decode()


def parse_stream_ticket(ticket):
    """Вернуть username из валидного тикета либо None. username из [A-Za-z0-9_-]
    (RE_USERNAME) — двоеточий не содержит, поэтому rsplit безопасен."""
    try:
        raw = base64.urlsafe_b64decode((ticket or "").encode()).decode()
        user, exp_s, sig = raw.rsplit(":", 2)
        exp = int(exp_s)
    except Exception:
        return None
    if exp < time.time() or not RE_USERNAME.fullmatch(user):
        return None
    good = hmac.new(_STREAM_SECRET, f"{user}:{exp}".encode(), hashlib.sha256).hexdigest()[:32]
    return user if hmac.compare_digest(sig, good) else None


# Скорость считает таймер hy2-rates (см. collect_rates): свою — в rates.dat,
# чужую мы стягиваем в peers/*.rates. Файл считается протухшим, если его давно
# не обновляли (таймер упал, пир недоступен) — лучше показать 0, чем застывшую
# скорость получасовой давности.
RATES_MAX_AGE = _env_int("HY2M_RATES_MAX_AGE", 60)  # с
# stats (число подключений) публикуется раз в ~60с (cluster_online_sync), поэтому
# порог протухания шире, чем у rates: минутный файл — ещё свежий.
STATS_MAX_AGE = _env_int("HY2M_STATS_MAX_AGE", 180)  # с


def _fresh(path, max_age):
    try:
        return time.time() - os.path.getmtime(path) <= max_age
    except OSError:
        return False


def _rate_dir_from(path, user):
    """(down_bps, up_bps) юзера из rates-файла. v2: «user|down|up|ts». v1 (старый
    пир до сплита): «user|bps|ts» — кладём всё в down. Протухший файл → (0,0),
    строки-заголовки «#...» пропускаем."""
    if not _fresh(path, RATES_MAX_AGE):
        return (0, 0)
    for line in read_lines(path):
        if not line or line[0] == "#":
            continue
        p = line.split("|")
        if p and p[0] == user:
            if len(p) >= 4 and p[1].isdigit() and p[2].isdigit():
                return (int(p[1]), int(p[2]))
            if len(p) >= 2 and p[1].isdigit():
                return (int(p[1]), 0)   # v1 combined
            return (0, 0)
    return (0, 0)


def _rates_label(path):
    """Метка ноды из заголовка «#label|…» rates-файла (NODE_LABEL по кластеру не
    синхронизируется, поэтому каждая нода печатает свою метку в свой rates)."""
    for line in read_lines(path):
        if line.startswith("#label|"):
            return line[len("#label|"):].strip() or None
        if line and line[0] != "#":
            break   # заголовок только в начале файла
    return None


def _conns_from(path, user):
    """Число подключений юзера из stats-файла (TAB: user, online, …). Протухший → 0."""
    if not _fresh(path, STATS_MAX_AGE):
        return 0
    for line in read_lines(path):
        p = line.split("\t")
        if p and p[0] == user:
            return int(p[1]) if len(p) >= 2 and p[1].isdigit() else 0
    return 0


def _peer_rates_files():
    try:
        return [n for n in os.listdir(PEERS_DIR) if n.endswith(".rates")]
    except OSError:
        return []


def user_rate_bps(user):
    """Текущая скорость юзера (байт/с) по ВСЕМУ кластеру: своя нода плюс каждый
    пир, оба направления. Профиль у юзера один на кластер, а подключается он к
    любой ноде — поэтому складываем: без пиров спидометр показывал бы 0 при работе
    через соседа (а именно так обычно и есть)."""
    d, u = _rate_dir_from(data_path("rates.dat"), user)
    total = d + u
    for name in _peer_rates_files():
        d, u = _rate_dir_from(os.path.join(PEERS_DIR, name), user)
        total += d + u
    return total


def user_nodes(user):
    """Разбивка по нодам, где юзер сейчас активен: [{label, conns, down, up}].
    Скорость ↓↑ живая (rates, 5с); conns — из минутной stats (меняются медленно).
    Нода в списке, если есть трафик ИЛИ подключения. Сортировка по сумме скорости."""
    nodes = []

    def add(rates_path, stats_path, fallback):
        down, up = _rate_dir_from(rates_path, user)
        conns = _conns_from(stats_path, user)
        if down <= 0 and up <= 0 and conns <= 0:
            return
        nodes.append({
            "label": _rates_label(rates_path) or fallback,
            "conns": conns, "down": down, "up": up,
        })

    add(data_path("rates.dat"), data_path("self.stats"), "эта нода")
    for name in _peer_rates_files():
        base = name[:-len(".rates")]
        add(os.path.join(PEERS_DIR, name), os.path.join(PEERS_DIR, base + ".stats"), base)
    nodes.sort(key=lambda n: n["down"] + n["up"], reverse=True)
    return nodes


# Живой трафик как признак онлайна. is_online читает activity.dat, который пишет
# collect_activity раз в ~60с (cluster_online_sync) + грейс 90с — статус включался
# с отставанием до минуты, хотя спидометр (rates, каждые 5с) уже показывал трафик.
# Порог отсекает keepalive-пинги (как ACTIVITY_THRESHOLD_BPS у collect_activity).
ONLINE_LIVE_RATE_BPS = _env_int("HY2M_ONLINE_RATE_BPS", 2048)


def stream_snapshot(user):
    bps = user_rate_bps(user)
    online = is_online(user)
    # Трафик идёт прямо сейчас — онлайн, не дожидаясь минутного collect_activity.
    # Обновляем и грейс-таймер: после остановки трафика статус гаснет плавно через
    # ONLINE_GRACE_SEC, а не мигает.
    if bps >= ONLINE_LIVE_RATE_BPS:
        with _online_lock:
            _online_last_active[user] = time.time()
        online = True
    return (online, bps)


def _stream_watcher():
    """Демонический тред: раз в STREAM_POLL_SEC пересчитывает online и скорость
    подписанных юзеров (O(число подписанных), не на клиента) и будит хендлеры
    при изменении."""
    while True:
        time.sleep(STREAM_POLL_SEC)
        try:
            with _stream_cv:
                users = list(_stream_subs.keys())
            now = time.time()
            updates = {u: stream_snapshot(u) for u in users}
            with _stream_cv:
                changed = any(_stream_state.get(u) != v for u, v in updates.items())
                _stream_state.update(updates)
                for u, (_online, bps) in updates.items():
                    _stream_samples.setdefault(u, deque(maxlen=STREAM_SAMPLES_WINDOW)).append((now, bps))
                # Юзер отписался — его состояние и выборки больше не нужны:
                # словари жили вечно и росли со списком всех, кто когда-либо
                # открывал кабинет.
                for u in [u for u in _stream_state if u not in _stream_subs]:
                    _stream_state.pop(u, None)
                    _stream_samples.pop(u, None)
                if changed:
                    _stream_cv.notify_all()
            # Гистерезис онлайна: запись старше грейса ни на что не влияет
            # (is_online на ней вернёт False) — держать её незачем.
            with _online_lock:
                for u in [u for u, ts in _online_last_active.items() if now - ts > ONLINE_GRACE_SEC]:
                    _online_last_active.pop(u, None)
        except Exception as e:
            sys.stderr.write(f"stream watcher: {e!r}\n")


def stream_payload(user, state):
    """SSE-объект: online/bps (обратная совместимость) + ряд выборок samples
    [{t: мс-эпоха, bps}] за окно наблюдения. Фронт проигрывает стрелку по samples
    в реальном времени; старые клиенты читают bps и игнорируют samples."""
    online, bps = state
    samples = [{"t": int(ts * 1000), "bps": b} for ts, b in _stream_samples.get(user, ())]
    return {"online": online, "bps": bps, "samples": samples}
