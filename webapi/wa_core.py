#!/usr/bin/env python3
# ================================================
# Конфиг демона, ключи и аутентификация, rate-limit, аудит, чтение файлов DATA_DIR.
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


# --- «Онлайн сейчас» = юзер реально пользуется (не пинг), по всему кластеру ---
# Признак активности («active») считает менеджер (collect_activity, lib/traffic.sh)
# по движению байтовых счётчиков ВСЕХ протоколов (Hysteria/Xray/TUIC) с порогом,
# отсекающим пинги. Локально он лежит в activity.dat, а по кластеру уже
# синхронизируется в peers/*.stats (поле active) каждые ~4с. Здесь мы этот готовый
# сигнал только читаем — не пересчитываем (нагрузку не добавляем).
# Гистерезис: держим «онлайн» ещё ONLINE_GRACE_SEC после последнего наблюдения
# active=1 — чтобы статус не мигал на минутных провалах активности (пауза видео)
# и джиттере кросс-нодового синка.
ONLINE_GRACE_SEC = _env_int("HY2M_ONLINE_GRACE_SEC", 90)
_online_lock = threading.Lock()
_online_last_active = {}  # user -> ts последнего наблюдения active=1 (для гистерезиса)


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
