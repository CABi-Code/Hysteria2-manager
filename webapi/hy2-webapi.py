#!/usr/bin/env python3
# ================================================
# hy2-webapi — HTTP JSON API менеджера Hysteria2 для внешних приложений
# (Telegram mini-app, биллинги, боты сторонних разработчиков).
#
# Только stdlib (python3 ≥ 3.9): демон обязан работать на голом Debian/Ubuntu
# без pip. Слушает localhost; наружу выставляется через Caddy (handle /api/* →
# reverse_proxy), см. lib/webapi.sh и setup_caddy в lib/subscription.sh.
#
# Аутентификация: Authorization: Bearer hyk_<40 симв.>. В webapi.keys хранится
# ТОЛЬКО sha256 ключа — утечка файла не раскрывает ключи. Scopes ограничивают,
# что каждому приложению можно (read/users/payments/telegram или *).
#
# Чтения парсят файлы DATA_DIR напрямую (форматы — точка правды в lib/config.sh);
# файлы менеджер правит через sed -i/tmp+cat, поэтому каждый файл читается одним
# read(), битые строки пропускаются — согласованность eventually (как и весь
# кластерный обмен). Мутации идут ТОЛЬКО через webapi/dispatch.sh: он сорсит
# lib/*.sh и вызывает те же функции, что меню/бот, — кластерная публикация,
# метки времени и пересборка подписок не дублируются здесь.
#
# Документация API для разработчиков: docs/API.md.
# ================================================
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
import urllib.request
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MANAGER_DIR = os.environ.get("HY2M_MANAGER_DIR") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA_DIR = os.environ.get("HY2M_DATA_DIR", "/etc/hysteria/manager")
CONFIG_YAML = os.environ.get("HY2M_CONFIG", "/etc/hysteria/config.yaml")
DISPATCH = os.path.join(MANAGER_DIR, "webapi", "dispatch.sh")

CONF_FILE = os.path.join(DATA_DIR, "webapi.conf")
KEYS_FILE = os.path.join(DATA_DIR, "webapi.keys")
ACCESS_LOG = os.path.join(DATA_DIR, "webapi_access.log")
PEERS_DIR = os.path.join(DATA_DIR, "peers")

RE_USERNAME = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
RE_TG_ID = re.compile(r"^\d{1,20}$")
RE_CODE = re.compile(r"^[A-Za-z0-9]{4,64}$")
RE_CHARGE = re.compile(r"^[A-Za-z0-9_\-.:]{1,128}$")

_log_lock = threading.Lock()
_rate_lock = threading.Lock()
_rate_buckets = {}  # key_name -> [tokens, last_ts]


def _env_int(name, default):
    v = os.environ.get(name, "")
    return int(v) if v.isdigit() else default


# --- «Онлайн сейчас» по активности трафика ---
# Проблема: клиент для замера латентности пингует все протоколы сразу, и каждый
# движок (Hysteria/Xray/TUIC) видит пинг как «соединение». Считать онлайн по
# наличию соединений — значит множить один пинг на число протоколов. Единственный
# устойчивый признак «реально пользуется, а не пингует» — движение байтовых
# счётчиков: пинг двигает их на единицы КБ за интервал (десятки Б/с), реальное
# использование — на порядки больше. Фоновый сэмплер (_online_sampler) снимает
# кумулятивный трафик всех юзеров раз в ONLINE_SAMPLE_SEC; юзер «онлайн», если
# скорость между снимками >= ONLINE_RATE_BPS. Порог настраивается env-переменными
# на юните демона (см. lib/webapi.sh); дефолт 2 КБ/с — заведомо выше пинг-шума и
# ниже даже лёгкого реального сёрфинга.
ONLINE_SAMPLE_SEC = max(5, _env_int("HY2M_ONLINE_SAMPLE_SEC", 15))
ONLINE_RATE_BPS = _env_int("HY2M_ONLINE_RATE_BPS", 2048)
_online_lock = threading.Lock()
_online_prev = {}      # user -> (total_bytes, ts) — предыдущий снимок сэмплера
_online_active = set()  # user'ы, активные по последнему снимку


# ---------- конфиг и ключи ----------

def read_kv(path):
    """KEY=VALUE файлы менеджера (node.conf/bot.conf/webapi.conf)."""
    out = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            data = f.read()
    except OSError:
        return out
    for line in data.splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            k, _, v = line.partition("=")
            out[k.strip()] = v.strip()
    return out


def conf():
    c = read_kv(CONF_FILE)
    port = c.get("PORT", "8787")
    return {
        "bind": c.get("BIND", "127.0.0.1"),
        "port": int(port) if port.isdigit() else 8787,
        "rate_rpm": int(c["RATE_RPM"]) if c.get("RATE_RPM", "").isdigit() else 120,
    }


def load_keys():
    """webapi.keys: name|sha256hex|scopes|created_ts (scopes через запятую, * = все)."""
    keys = {}
    try:
        with open(KEYS_FILE, encoding="utf-8", errors="replace") as f:
            data = f.read()
    except OSError:
        return keys
    for line in data.splitlines():
        parts = line.split("|")
        if len(parts) >= 3 and re.fullmatch(r"[0-9a-f]{64}", parts[1] or ""):
            keys[parts[1]] = {"name": parts[0], "scopes": set(parts[2].split(","))}
    return keys


def authenticate(header):
    if not header or not header.startswith("Bearer "):
        return None
    token = header[7:].strip()
    if not re.fullmatch(r"[A-Za-z0-9_]{8,128}", token):
        return None
    digest = hashlib.sha256(token.encode()).hexdigest()
    for stored, info in load_keys().items():
        if hmac.compare_digest(stored, digest):
            return info
    return None


def has_scope(key, scope):
    return "*" in key["scopes"] or scope in key["scopes"]


def rate_ok(key_name, rpm):
    """Token bucket: ёмкость rpm, пополнение rpm/60 в секунду."""
    now = time.monotonic()
    with _rate_lock:
        tokens, last = _rate_buckets.get(key_name, (float(rpm), now))
        tokens = min(float(rpm), tokens + (now - last) * rpm / 60.0)
        if tokens < 1.0:
            _rate_buckets[key_name] = (tokens, now)
            return False
        _rate_buckets[key_name] = (tokens - 1.0, now)
        return True


def audit(key_name, method, path, status, ms):
    line = f"{int(time.time())}|{key_name}|{method}|{path}|{status}|{ms}\n"
    with _log_lock:
        try:
            with open(ACCESS_LOG, "a", encoding="utf-8") as f:
                f.write(line)
        except OSError:
            pass


# ---------- парсеры данных менеджера ----------

def read_lines(path):
    """Файл целиком одним read() — минимизирует окно torn read при sed -i."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read().splitlines()
    except OSError:
        return []


def data_path(name):
    return os.path.join(DATA_DIR, name)


def colon_db(path):
    """user:value, value может содержать ':' — split по первому двоеточию."""
    out = {}
    for line in read_lines(path):
        if ":" in line:
            k, _, v = line.partition(":")
            if k:
                out.setdefault(k, []).append(v)
    return out


def pipe_rows(path, min_fields):
    rows = []
    for line in read_lines(path):
        parts = line.split("|")
        if len(parts) >= min_fields and parts[0]:
            rows.append(parts)
    return rows


def user_exists(user):
    active = user in colon_db(data_path("users.db"))
    disabled = any(r[0] == user for r in pipe_rows(data_path("disabled.dat"), 2))
    return active, disabled


def user_expiry(user):
    for r in pipe_rows(data_path("expiry.dat"), 2):
        if r[0] == user and re.fullmatch(r"\d{4}-\d{2}-\d{2}", r[1]):
            return r[1]
    return None


def days_left(expiry):
    """Как expiry_days_left в lib/expiry.sh: срок действует до 23:59:59 даты."""
    if not expiry:
        return None
    end = datetime.strptime(expiry, "%Y-%m-%d").replace(hour=23, minute=59, second=59)
    return max(-3650, int((end - datetime.now()).total_seconds() // 86400))


def user_limits(user):
    for r in pipe_rows(data_path("userlimits.dat"), 2):
        if r[0] == user:
            devices = int(r[1]) if r[1].isdigit() else 1
            hardcheck = 1 if len(r) > 2 and r[2] == "1" else 0
            rate = int(r[3]) if len(r) > 3 and r[3].isdigit() else 0
            return {"devices": devices, "hardcheck": bool(hardcheck), "rate_mbps": rate}
    return {"devices": 1, "hardcheck": False, "rate_mbps": 0}


def peer_stats(user):
    """Суммы по кэшам пиров $DATA_DIR/peers/*.stats:
    user \t online \t tx \t rx \t sptx \t sprx \t active \t active_since"""
    online = tx = rx = 0
    try:
        names = os.listdir(PEERS_DIR)
    except OSError:
        names = []
    for name in names:
        if not name.endswith(".stats"):
            continue
        for line in read_lines(os.path.join(PEERS_DIR, name)):
            parts = line.split("\t")
            if len(parts) >= 4 and parts[0] == user:
                online += int(parts[1]) if parts[1].isdigit() else 0
                tx += int(parts[2]) if parts[2].isdigit() else 0
                rx += int(parts[3]) if parts[3].isdigit() else 0
                break
    return online, tx, rx


def local_traffic(user):
    for r in pipe_rows(data_path("stats.dat"), 3):
        if r[0] == user:
            return (int(r[1]) if r[1].isdigit() else 0,
                    int(r[2]) if r[2].isdigit() else 0)
    return 0, 0


# Окно «активных устройств»: считаем уникальные IP только за последние сутки.
# ips.dat раньше отдавался целиком (кумулятивно за всё время) и рос вечно
# из-за ротации мобильных IP/CGNAT — карточка показывала «128 из 1». Формат
# строки: user|ip|first_seen|last_seen|count (см. lib/ip_tracking.sh), время —
# epoch-секунды; фильтруем по last_seen (поле 4, индекс 3).
DEVICES_WINDOW_SEC = 86400


def user_ip_count(user, window_sec=DEVICES_WINDOW_SEC):
    cutoff = time.time() - window_sec
    ips = set()

    def consider(row):
        # Требуем last_seen; строки без метки времени (легаси) в окно не берём.
        if len(row) < 4:
            return
        try:
            last_seen = int(row[3])
        except (ValueError, IndexError):
            return
        if last_seen >= cutoff:
            ips.add(row[1])

    for r in pipe_rows(data_path("ips.dat"), 2):
        if r[0] == user:
            consider(r)
    try:
        names = os.listdir(PEERS_DIR)
    except OSError:
        names = []
    for name in names:
        if name.endswith(".ips"):
            for r in pipe_rows(os.path.join(PEERS_DIR, name), 2):
                if r[0] == user:
                    consider(r)
    return len(ips)


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


def _all_user_totals():
    """user -> суммарный кумулятивный трафик (локальный + пировый), одним проходом
    файлов. Те же источники, что traffic в user_payload (stats.dat + peers/*.stats),
    поэтому суммы сходятся. Считается по всем протоколам сразу — движки пишут в
    общий stats.dat, так что признак активности не зависит от протокола."""
    totals = {}
    for r in pipe_rows(data_path("stats.dat"), 3):
        tx = int(r[1]) if r[1].isdigit() else 0
        rx = int(r[2]) if r[2].isdigit() else 0
        totals[r[0]] = totals.get(r[0], 0) + tx + rx
    try:
        names = os.listdir(PEERS_DIR)
    except OSError:
        names = []
    for name in names:
        if not name.endswith(".stats"):
            continue
        for line in read_lines(os.path.join(PEERS_DIR, name)):
            parts = line.split("\t")
            if len(parts) >= 4:
                tx = int(parts[2]) if parts[2].isdigit() else 0
                rx = int(parts[3]) if parts[3].isdigit() else 0
                totals[parts[0]] = totals.get(parts[0], 0) + tx + rx
    return totals


def _online_sampler():
    """Фоновый цикл: раз в ONLINE_SAMPLE_SEC пересчитывает множество активных
    юзеров по скорости трафика между снимками. Демонический тред, ошибки не
    роняют его (I/O по файлам менеджера может временно спотыкаться о sed -i)."""
    while True:
        try:
            now = time.time()
            totals = _all_user_totals()
            active = set()
            with _online_lock:
                for user, cur in totals.items():
                    prev = _online_prev.get(user)
                    if prev:
                        pb, pts = prev
                        dt = now - pts
                        # dt>0 всегда (цикл со сном), delta<0 = сброс счётчика.
                        if dt > 0 and cur >= pb and (cur - pb) / dt >= ONLINE_RATE_BPS:
                            active.add(user)
                _online_prev.clear()
                _online_prev.update((u, (b, now)) for u, b in totals.items())
                _online_active.clear()
                _online_active.update(active)
        except Exception as e:
            sys.stderr.write(f"online sampler: {e!r}\n")
        time.sleep(ONLINE_SAMPLE_SEC)


def is_online(user):
    """«Онлайн сейчас» = юзер реально гонял трафик в последнем окне сэмплера."""
    with _online_lock:
        return user in _online_active


def sub_tokens(user):
    """Локальные + пировые токены подписки (первый локальный — основной)."""
    tokens = list(colon_db(data_path("subtokens.db")).get(user, []))
    try:
        names = os.listdir(PEERS_DIR)
    except OSError:
        names = []
    for name in names:
        if name.endswith(".subtokens"):
            for t in colon_db(os.path.join(PEERS_DIR, name)).get(user, []):
                if t not in tokens:
                    tokens.append(t)
    return tokens


def tg_username(tg_id):
    for r in pipe_rows(data_path("tgusers.dat"), 2):
        if r[0] == tg_id:
            # Пустое поле — tombstone отвязки (кластерный LWW, см. tg_unbind):
            # трактуем как «не привязан», а не как привязку к юзеру "".
            return r[1] or None
    return None


def user_payload(user):
    active, disabled = user_exists(user)
    if not active and not disabled:
        return None
    expiry = user_expiry(user)
    ltx, lrx = local_traffic(user)
    ponline, ptx, prx = peer_stats(user)
    lonline = hysteria_online(user)
    limits = user_limits(user)
    return {
        "username": user,
        "status": "active" if active else "disabled",
        "expiry": expiry,                      # null = бессрочно
        "days_left": days_left(expiry),
        "unlimited": expiry is None,
        "limits": limits,
        "traffic": {
            "tx_bytes": ltx + ptx,
            "rx_bytes": lrx + prx,
            "total_bytes": ltx + ptx + lrx + prx,
        },
        # online_connections — сырое число соединений всех движков (включая пинги),
        # оставлено для совместимости API. online — «реально пользуется сейчас»
        # по движению трафика (см. _online_sampler): пинги его не накручивают.
        "online_connections": (lonline or 0) + ponline if lonline is not None else ponline,
        "online": is_online(user),
        "devices_seen": user_ip_count(user),
    }


# ---------- dispatch (мутации и сборка ссылок через lib/*.sh) ----------

def run_dispatch(verb, *args):
    """Возвращает (dict из key=value строк, None) либо (None, (http_код, api_код, сообщение))."""
    env = dict(os.environ, HY2M_DATA_DIR=DATA_DIR, HY2M_CONFIG=CONFIG_YAML)
    try:
        proc = subprocess.run([DISPATCH, verb, *args], capture_output=True,
                              text=True, timeout=60, env=env)
    except subprocess.TimeoutExpired:
        return None, (504, "dispatch_timeout", "менеджер не ответил за 60 секунд")
    except OSError as e:
        # Детали (путь, errno) — только в лог: наружу они раскрывают устройство
        # сервера и бесполезны клиенту.
        sys.stderr.write(f"dispatch {verb}: запуск не удался: {e!r}\n")
        return None, (500, "dispatch_unavailable", "менеджер недоступен")
    out = {}
    for line in proc.stdout.splitlines():
        if "=" in line:
            k, _, v = line.partition("=")
            out[k] = v
    if proc.returncode == 0:
        return out, None
    if proc.returncode == 2:
        return None, (404, out.get("error", "not_found"), out.get("message", "объект не найден"))
    if proc.returncode == 3:
        return None, (409, out.get("error", "conflict"), out.get("message", "конфликт состояния"))
    if proc.returncode == 75:
        # flock -w в dispatch.sh не дождался блокировки: менеджер занят другой
        # мутацией. Это не ошибка менеджера, а «попробуйте позже» — 503 + Retry-After.
        return None, (503, "busy", "менеджер занят, повторите позже",
                      {"Retry-After": "15"})
    sys.stderr.write(f"dispatch {verb} rc={proc.returncode}: {proc.stderr.strip()}\n")
    return None, (502, "manager_error", "внутренняя ошибка менеджера")


# ---------- данные для info/tariffs/nodes/payments ----------

def manager_version():
    try:
        with open(os.path.join(MANAGER_DIR, "VERSION"), encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return None


def enabled_protocols():
    """Список доп. протоколов, включённых на ноде (из protocols.conf).

    Подписка юзера физически содержит по ключу на каждый включённый протокол —
    это поле лишь позволяет кабинету показать бейджи «VLESS/SS2022/TUIC», не
    разбирая base64 подписки. Hysteria 2 присутствует всегда как базовый.
    """
    p = read_kv(data_path("protocols.conf"))
    out = ["hysteria2"]
    if p.get("PROTO_VLESS_ENABLED") == "1":
        out.append("vless-reality-xhttp")
    if p.get("PROTO_SS_ENABLED") == "1":
        out.append("shadowsocks-2022")
    if p.get("PROTO_TUIC_ENABLED") == "1":
        out.append("tuic-v5")
    return out


def node_info():
    node = read_kv(data_path("node.conf"))
    users = colon_db(data_path("users.db"))
    disabled = pipe_rows(data_path("disabled.dat"), 2)
    peers = pipe_rows(data_path("cluster.conf"), 2)
    return {
        "manager_version": manager_version(),
        "node_name": node.get("NODE_NAME"),
        "node_host": node.get("NODE_HOST"),
        "users_active": len(users),
        "users_disabled": len(disabled),
        "cluster_peers": len(peers),
        "protocols": enabled_protocols(),
    }


def tariffs():
    out = []
    for r in pipe_rows(data_path("tariffs.conf"), 6):
        if not r[2].isdigit():
            continue
        # Поля цены/валюты могут быть '/'-списками одинаковой длины (мультивалютный
        # тариф). Разбираем в prices=[{currency, price}]; price/currency = первый
        # (основной) элемент — для обратной совместимости со старыми клиентами.
        prices_raw = (r[4] or "").split("/")
        curs_raw = (r[5] or "").split("/")
        prices = []
        for i, p in enumerate(prices_raw):
            p = p.strip()
            c = (curs_raw[i].strip().upper() if i < len(curs_raw) else "")
            if c and re.fullmatch(r"\d+([.,]\d+)?", p):
                prices.append({"currency": c, "price": p})
        if not prices:
            continue
        out.append({
            "code": r[0], "title": r[1], "days": int(r[2]),
            "devices": int(r[3]) if r[3].isdigit() else 0,
            "price": prices[0]["price"], "currency": prices[0]["currency"],
            "prices": prices,
        })
    return out


def nodes():
    node = read_kv(data_path("node.conf"))
    out = []
    if node.get("NODE_NAME") or node.get("NODE_HOST"):
        out.append({"name": node.get("NODE_NAME"), "host": node.get("NODE_HOST"),
                    "label": node.get("NODE_LABEL") or node.get("NODE_NAME"), "self": True})
    for r in pipe_rows(data_path("cluster.conf"), 2):
        out.append({"name": r[0], "host": r[1], "label": r[0], "self": False})
    return out


def payments(since_charge, limit):
    """payments.log: datetime|tg_id|user|code|amount|currency|charge_id.
    Курсор — charge_id (уникален у Telegram); datetime не монотонен (локальная TZ)."""
    rows = pipe_rows(data_path("payments.log"), 7)
    start = 0
    if since_charge:
        for i, r in enumerate(rows):
            if r[6] == since_charge:
                start = i + 1
                break
        else:
            start = 0  # курсор не найден (лог ротирован?) — отдаём с начала
    out = []
    for r in rows[start:start + limit]:
        out.append({"paid_at": r[0], "tg_id": r[1], "username": r[2],
                    "tariff_code": r[3], "amount": r[4], "currency": r[5],
                    "charge_id": r[6]})
    return {"payments": out, "next_since_charge": out[-1]["charge_id"] if out else since_charge}


def subscription_payload(user):
    active, disabled = user_exists(user)
    if not active and not disabled:
        return None
    node = read_kv(data_path("node.conf"))
    host = node.get("NODE_HOST")
    urls = [f"https://{host}/sub/{t}" for t in sub_tokens(user)] if host else []
    links = []
    res, err = run_dispatch("user-links", user)
    if res and res.get("link"):
        links.append(res["link"])
    return {
        "username": user,
        "subscription_urls": urls,
        "subscription_url": urls[0] if urls else None,
        "links": links,   # прямые hysteria2:// (эта нода; остальные — внутри подписки)
    }


# ---------- HTTP ----------

ROUTES = [
    # (method, regex, scope|None, handler_name)
    ("GET", re.compile(r"^/v1/health$"), None, "h_health"),
    ("GET", re.compile(r"^/v1/info$"), "read", "h_info"),
    ("GET", re.compile(r"^/v1/tariffs$"), "read", "h_tariffs"),
    ("GET", re.compile(r"^/v1/nodes$"), "read", "h_nodes"),
    ("GET", re.compile(r"^/v1/users/([^/]+)$"), "read", "h_user"),
    ("GET", re.compile(r"^/v1/users/([^/]+)/subscription$"), "read", "h_user_sub"),
    ("GET", re.compile(r"^/v1/users/by-telegram/([^/]+)$"), "read", "h_user_by_tg"),
    ("GET", re.compile(r"^/v1/telegram/([^/]+)$"), "read", "h_tg"),
    ("GET", re.compile(r"^/v1/payments$"), "payments", "h_payments"),
    ("POST", re.compile(r"^/v1/users$"), "users", "h_provision"),
    ("POST", re.compile(r"^/v1/users/([^/]+)/extend$"), "users", "h_extend"),
    ("POST", re.compile(r"^/v1/users/([^/]+)/enable$"), "users", "h_enable"),
    ("POST", re.compile(r"^/v1/users/([^/]+)/disable$"), "users", "h_disable"),
    ("POST", re.compile(r"^/v1/users/([^/]+)/limits$"), "users", "h_limits"),
    ("POST", re.compile(r"^/v1/telegram/bind$"), "telegram", "h_bind"),
    ("POST", re.compile(r"^/v1/codes/redeem$"), "telegram", "h_redeem"),
]


class ApiError(Exception):
    def __init__(self, status, code, message, headers=None):
        self.status, self.code, self.message = status, code, message
        self.headers = headers or {}  # доп. заголовки ответа (Retry-After и т.п.)


def need_username(value):
    if not RE_USERNAME.fullmatch(value or ""):
        raise ApiError(400, "invalid_username", "имя: латиница, цифры, _ и -, до 64 символов")
    return value


def need_tg_id(value):
    if not RE_TG_ID.fullmatch(str(value or "")):
        raise ApiError(400, "invalid_tg_id", "tg_id: только цифры")
    return str(value)


def is_int(value):
    # bool — подкласс int (isinstance(True, int) == True), но str(True) = "True"
    # ломает контракт dispatch.sh (rc 64 → 502). Отвергаем bool явно, чтобы
    # клиент получил честный 400.
    return isinstance(value, int) and not isinstance(value, bool)


class Handler(BaseHTTPRequestHandler):
    server_version = "hy2-webapi"
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):   # стандартный stderr-лог заменён нашим audit()
        pass

    # -- обработчики --

    def h_health(self):
        return {"version": manager_version()}

    def h_info(self):
        return node_info()

    def h_tariffs(self):
        return {"tariffs": tariffs()}

    def h_nodes(self):
        return {"nodes": nodes()}

    def h_user(self, name):
        payload = user_payload(need_username(name))
        if payload is None:
            raise ApiError(404, "user_not_found", "пользователь не найден")
        return payload

    def h_user_sub(self, name):
        payload = subscription_payload(need_username(name))
        if payload is None:
            raise ApiError(404, "user_not_found", "пользователь не найден")
        return payload

    def h_user_by_tg(self, tg_id):
        user = tg_username(need_tg_id(tg_id))
        if not user:
            raise ApiError(404, "not_linked", "telegram-аккаунт не привязан")
        payload = user_payload(user)
        if payload is None:
            raise ApiError(404, "user_not_found", "привязка есть, но пользователь удалён")
        return payload

    def h_tg(self, tg_id):
        user = tg_username(need_tg_id(tg_id))
        return {"tg_id": tg_id, "bound": user is not None, "username": user}

    def h_payments(self):
        since = self.query.get("since_charge", "")
        if since and not RE_CHARGE.fullmatch(since):
            raise ApiError(400, "invalid_cursor", "недопустимый since_charge")
        limit = self.query.get("limit", "200")
        limit = min(500, int(limit)) if limit.isdigit() and int(limit) > 0 else 200
        return payments(since or None, limit)

    def h_provision(self):
        user = need_username(self.body.get("username"))
        active, disabled = user_exists(user)
        res = self.dispatch("provision", user)
        return {"username": user, "created": not (active or disabled),
                "password": res.get("password"),
                "subscription_url": res.get("sub_url") or None}

    def h_extend(self, name):
        user = need_username(name)
        days = self.body.get("days")
        if not (is_int(days) and 1 <= days <= 3650):
            raise ApiError(400, "invalid_days", "days: целое 1..3650")
        res = self.dispatch("extend", user, str(days))
        return {"username": user, "expiry": res.get("expiry"),
                "days_left": days_left(res.get("expiry"))}

    def h_enable(self, name):
        user = need_username(name)
        self.dispatch("enable", user)
        return {"username": user, "status": "active"}

    def h_disable(self, name):
        user = need_username(name)
        self.dispatch("disable", user)
        return {"username": user, "status": "disabled"}

    def h_limits(self, name):
        user = need_username(name)
        current = user_limits(user)
        devices = self.body.get("devices", current["devices"])
        rate = self.body.get("rate_mbps", current["rate_mbps"])
        if not (is_int(devices) and 0 <= devices <= 1000):
            raise ApiError(400, "invalid_devices", "devices: целое 0..1000")
        if not (is_int(rate) and 0 <= rate <= 100000):
            raise ApiError(400, "invalid_rate", "rate_mbps: целое 0..100000")
        self.dispatch("set-limits", user, str(devices), str(rate))
        return {"username": user, "limits": user_limits(user)}

    def h_bind(self):
        tg_id = need_tg_id(self.body.get("tg_id"))
        user = need_username(self.body.get("username"))
        self.dispatch("tg-bind", tg_id, user)
        return {"tg_id": tg_id, "username": user, "bound": True}

    def h_redeem(self):
        code = self.body.get("code")
        if not RE_CODE.fullmatch(str(code or "")):
            raise ApiError(400, "invalid_code", "недопустимый формат кода")
        args = [str(code)]
        tg_id = self.body.get("tg_id")
        if tg_id is not None:
            args.append(need_tg_id(tg_id))
        res = self.dispatch("redeem", *args)
        return {"username": res.get("username"),
                "bound": bool(tg_id)}

    # -- инфраструктура --

    def dispatch(self, verb, *args):
        res, err = run_dispatch(verb, *args)
        if err:
            raise ApiError(*err)
        return res

    def handle_route(self, method):
        started = time.monotonic()
        path, _, qs = self.path.partition("?")
        self.query = {}
        for pair in qs.split("&"):
            if "=" in pair:
                k, _, v = pair.partition("=")
                self.query[k] = urllib.parse.unquote(v)
        key = None
        status = 500
        # Соединение keep-alive (HTTP/1.1): пока тело запроса не вычитано из
        # rfile, отвечать нельзя — невычитанные байты распарсятся как следующий
        # запрос. Флаг сбрасывается на каждый запрос (Handler живёт всё соединение).
        self._body_consumed = False
        try:
            matched = None
            for m, rx, scope, handler in ROUTES:
                match = rx.match(path)
                if match:
                    matched = True
                    if m == method:
                        break
            else:
                raise ApiError(405 if matched else 404,
                               "method_not_allowed" if matched else "no_such_endpoint",
                               "метод не поддерживается" if matched else "нет такого эндпоинта (см. docs/API.md)")
            if scope is not None:
                key = authenticate(self.headers.get("Authorization"))
                if key is None:
                    raise ApiError(401, "unauthorized", "нужен заголовок Authorization: Bearer <ключ>")
                if not rate_ok(key["name"], conf()["rate_rpm"]):
                    raise ApiError(429, "rate_limited", "слишком много запросов",
                                   {"Retry-After": "10"})
                if not has_scope(key, scope):
                    raise ApiError(403, "forbidden", f"ключу не выдан scope «{scope}»")
            if method == "POST":
                length = int(self.headers.get("Content-Length") or 0)
                if length > 65536:
                    raise ApiError(413, "payload_too_large", "тело запроса больше 64 КБ")
                raw = self.rfile.read(length) if length else b""
                self._body_consumed = True
                if raw:
                    try:
                        self.body = json.loads(raw.decode("utf-8"))
                    except (ValueError, UnicodeDecodeError):
                        raise ApiError(400, "invalid_json", "тело должно быть валидным JSON")
                    if not isinstance(self.body, dict):
                        raise ApiError(400, "invalid_json", "ожидается JSON-объект")
                else:
                    self.body = {}
            data = getattr(self, handler)(*match.groups())
            status = 200
            self.respond(200, {"ok": True, "data": data})
        except ApiError as e:
            status = e.status
            self.respond(e.status, {"ok": False, "error": {"code": e.code, "message": e.message}},
                         e.headers)
        except Exception as e:  # не роняем демон из-за одного запроса
            sys.stderr.write(f"unhandled {method} {path}: {e!r}\n")
            status = 500
            try:
                self.respond(500, {"ok": False, "error": {"code": "internal",
                             "message": "внутренняя ошибка"}})
            except Exception:
                pass
        finally:
            ms = int((time.monotonic() - started) * 1000)
            audit(key["name"] if key else "-", method, path, status, ms)

    # Потолок дренажа невычитанного тела. Валидные тела ограничены 64 КБ (413);
    # всё, что больше, дешевле не дочитывать, а закрыть соединение.
    MAX_DRAIN = 1 << 20

    def drain_body(self):
        """Дочитывает невычитанное тело запроса перед отправкой ответа.

        Ранние ответы (401/403/404/405/413/429) уходят ДО чтения тела POST; в
        keep-alive-соединении оставшиеся байты иначе были бы распарсены как
        следующий запрос (клиент за Caddy/Guzzle получил бы битые ответы).
        Если дочитать нельзя (слишком большое или битый Content-Length) —
        закрываем соединение, respond() добавит Connection: close."""
        if self._body_consumed:
            return
        self._body_consumed = True
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = -1
        if length <= 0:
            if length < 0:
                self.close_connection = True
            return
        if length > self.MAX_DRAIN:
            self.close_connection = True
            return
        try:
            while length > 0:
                chunk = self.rfile.read(min(length, 65536))
                if not chunk:      # клиент недослал тело — соединение мёртвое
                    self.close_connection = True
                    break
                length -= len(chunk)
        except OSError:
            self.close_connection = True

    def respond(self, status, obj, headers=None):
        self.drain_body()
        payload = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        if self.close_connection:
            # Дренаж не удался: честно предупреждаем клиента, что соединение
            # закрывается, — иначе он ждал бы следующий keep-alive-ответ.
            self.send_header("Connection", "close")
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        self.handle_route("GET")

    def do_POST(self):
        self.handle_route("POST")


def main():
    c = conf()
    threading.Thread(target=_online_sampler, daemon=True).start()
    server = ThreadingHTTPServer((c["bind"], c["port"]), Handler)
    sys.stderr.write(f"hy2-webapi: listening on {c['bind']}:{c['port']}, DATA_DIR={DATA_DIR}, "
                     f"online>={ONLINE_RATE_BPS}B/s@{ONLINE_SAMPLE_SEC}s\n")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
