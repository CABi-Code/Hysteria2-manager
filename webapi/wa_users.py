#!/usr/bin/env python3
# ================================================
# Пользователь: существование, срок, лимиты, трафик, бесплатный тариф, уникальные IP.
# Часть hy2-webapi (точка входа — webapi/hy2-webapi.py, контракт — docs/API.md).
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
from wa_core import _env_int

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


def klimit_global_down():
    """Глобальный kernel-лимит скачивания (Мбит/с) из klimit.conf, 0 если не задан.
    Это потолок ВСЕХ клиентов без личного тарифа (см. lib/perf.sh). Отдаём в
    payload, чтобы веб-апп показывал реальное ограничение, а не «без лимита»."""
    for line in read_lines(data_path("klimit.conf")):
        if line.startswith("DOWN_MBIT="):
            v = line.split("=", 1)[1].strip()
            return int(v) if v.isdigit() else 0
    return 0


def user_limits(user):
    glob = klimit_global_down()
    for r in pipe_rows(data_path("userlimits.dat"), 2):
        if r[0] == user:
            devices = int(r[1]) if r[1].isdigit() else 1
            hardcheck = 1 if len(r) > 2 and r[2] == "1" else 0
            rate = int(r[3]) if len(r) > 3 and r[3].isdigit() else 0
            return {"devices": devices, "hardcheck": bool(hardcheck),
                    "rate_mbps": rate, "global_mbps": glob}
    return {"devices": 1, "hardcheck": False, "rate_mbps": 0, "global_mbps": glob}


FREE_WEEK_SEC = 604800      # окна бесплатного тарифа — как в lib/freeplan.sh
FREE_MONTH_SEC = 2592000


def size_bytes(value):
    """«5G» / «500M» / «100K» / «123» → байты (как free_size_bytes в bash)."""
    s = (value or "").strip().upper()
    mult = {"G": 1024 ** 3, "M": 1024 ** 2, "K": 1024}.get(s[-1:], 1)
    if mult != 1:
        s = s[:-1]
    return int(s) * mult if s.isdigit() else 0


def tariff_options(row):
    """7-е поле tariffs.conf — конструктор тарифа «k=v;k=v» (см. lib/freeplan.sh)."""
    out = {}
    for part in (row[6] if len(row) > 6 else "").split(";"):
        key, sep, val = part.partition("=")
        if sep and key.strip():
            out[key.strip()] = val.strip()
    return out


def free_tariff():
    """(код, опции) бесплатного тарифа или (None, {}) — фича выключена."""
    for r in pipe_rows(data_path("tariffs.conf"), 6):
        opts = tariff_options(r)
        if opts.get("free") == "1":
            return r[0], opts
    return None, {}


def window_reset(start, window, now):
    """Конец текущего окна: катим старт шагами по длине окна (как freeplan_window_start)."""
    if not start or start <= 0:
        return None
    return start + ((now - start) // window + 1) * window


def free_status(user, total_bytes):
    """Состояние бесплатного тарифа юзера или None. Расход = общий трафик по
    кластеру минус база, зафиксированная на старте окна (lib/freeplan.sh)."""
    row = next((r for r in pipe_rows(data_path("freeplan.dat"), 9) if r[0] == user), None)
    if row is None:
        return None
    code, opts = free_tariff()
    if code is None:
        return None
    nums = [int(x) if x.lstrip("-").isdigit() else 0 for x in row[2:8]]
    _start, wk_start, wk_base, mo_start, mo_base, _notified = nums
    pending = row[1] == "pending"
    now = int(time.time())

    def window(start, base, limit_key, window_sec):
        limit = size_bytes(opts.get(limit_key))
        used = 0 if pending else max(0, total_bytes - base)
        return {
            "used_bytes": used,
            "limit_bytes": limit,
            "left_bytes": max(0, limit - used) if limit else None,
            # null = окна ещё не запущены (ждём первого выхода в онлайн).
            "reset_at": None if pending else window_reset(start, window_sec, now),
        }

    return {
        "tariff": code,
        "state": row[1],
        "week": window(wk_start, wk_base, "wk", FREE_WEEK_SEC),
        "month": window(mo_start, mo_base, "mo", FREE_MONTH_SEC),
    }


def demo_status(user, total_bytes):
    """Состояние демо-профиля или None. Строка demos.db:
    user|state|created|expires|cap|base|used (см. lib/demo.sh). Расход считаем
    ровно как demo_tick, который и отбирает доступ: текущий трафик минус база
    на момент выдачи. У отобранного демо (state=expired) расход уже записан в
    строке — текущий трафик там ни при чём."""
    row = next((r for r in pipe_rows(data_path("demos.db"), 7) if r[0] == user), None)
    if row is None:
        return None
    nums = [int(x) if x.lstrip("-").isdigit() else 0 for x in row[2:7]]
    created, expires, cap, base, used = nums
    spent = used if row[1] != "active" else max(0, total_bytes - base)
    return {
        "state": row[1],
        "created_at": created,
        "expires_at": expires,
        "used_bytes": spent,
        "limit_bytes": cap,
        "left_bytes": max(0, cap - spent) if cap else None,
    }


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
