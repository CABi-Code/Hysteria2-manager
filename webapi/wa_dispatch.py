#!/usr/bin/env python3
# ================================================
# Мутации и справочники через webapi/dispatch.sh: тарифы, ноды, платежи, ссылки.
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
from wa_users import *  # noqa: F403
from wa_online import *  # noqa: F403
from wa_payload import *  # noqa: F403

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
    return None, _dispatch_error(proc, verb, out)


def run_dispatch_lines(verb, *args):
    """Как run_dispatch, но для read-verb'ов, печатающих ПОВТОРЯЮЩИЙСЯ ключ
    (link=… построчно). Возвращает (list[str] значений первого ключа, None)
    либо (None, (http, code, msg[, headers])). Обычный run_dispatch схлопнул бы
    повторы в одну запись dict — здесь сохраняем порядок и все значения."""
    env = dict(os.environ, HY2M_DATA_DIR=DATA_DIR, HY2M_CONFIG=CONFIG_YAML)
    try:
        proc = subprocess.run([DISPATCH, verb, *args], capture_output=True,
                              text=True, timeout=60, env=env)
    except subprocess.TimeoutExpired:
        return None, (504, "dispatch_timeout", "менеджер не ответил за 60 секунд")
    except OSError as e:
        sys.stderr.write(f"dispatch {verb}: запуск не удался: {e!r}\n")
        return None, (500, "dispatch_unavailable", "менеджер недоступен")
    if proc.returncode == 0:
        values = []
        for line in proc.stdout.splitlines():
            k, sep, v = line.partition("=")
            if sep and k not in ("error", "message"):
                values.append(v)
        return values, None
    return None, _dispatch_error(proc, verb, {
        k: v for k, _, v in (l.partition("=") for l in proc.stdout.splitlines()) if _
    })


def _dispatch_error(proc, verb, out):
    """Единая трактовка ненулевых кодов возврата dispatch.sh (см. контракт).
    Возвращает кортеж ошибки (http, code, msg[, headers]); заворачивание в
    (None, err) — на вызывающем."""
    if proc.returncode == 2:
        return (404, out.get("error", "not_found"), out.get("message", "объект не найден"))
    if proc.returncode == 3:
        return (409, out.get("error", "conflict"), out.get("message", "конфликт состояния"))
    if proc.returncode == 75:
        # flock -w в dispatch.sh не дождался блокировки: менеджер занят другой
        # мутацией. Это не ошибка менеджера, а «попробуйте позже» — 503 + Retry-After.
        return (503, "busy", "менеджер занят, повторите позже",
                {"Retry-After": "15"})
    sys.stderr.write(f"dispatch {verb} rc={proc.returncode}: {proc.stderr.strip()}\n")
    return (502, "manager_error", "внутренняя ошибка менеджера")


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
        # Конструктор (7-е поле): бесплатность и лимиты трафика. Для обычных
        # тарифов free=false и лимитов нет — клиенты, не знающие про поля,
        # продолжают работать как раньше.
        opts = tariff_options(r)
        out.append({
            "code": r[0], "title": r[1], "days": int(r[2]),
            "devices": int(r[3]) if r[3].isdigit() else 0,
            "price": prices[0]["price"], "currency": prices[0]["currency"],
            "prices": prices,
            "free": opts.get("free") == "1",
            "traffic_limits": {
                "week_bytes": size_bytes(opts.get("wk")),
                "month_bytes": size_bytes(opts.get("mo")),
            },
            "period_start": opts.get("start", "paid"),
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


# Человекочитаемые названия протоколов по схеме URI ключа.
PROTO_NAMES = {
    "hysteria2": "Hysteria2",
    "vless": "VLESS",
    "ss": "Shadowsocks 2022",
    "tuic": "TUIC v5",
    "trojan": "Trojan",
}


def parse_direct_link(uri):
    """Разбирает share-ссылку в {url, protocol, protocol_name, host, port, label}.
    Хост:порт — источник группировки по серверам на фронте; label (#фрагмент) —
    подпись ключа (обычно метка ноды). Пароль может содержать '@', поэтому хост
    берём после ПОСЛЕДНЕГО '@'."""
    scheme, _, rest = uri.partition("://")
    scheme = scheme.lower()
    body, _, frag = rest.partition("#")
    label = urllib.parse.unquote(frag) if frag else None
    hostpart = body.split("/", 1)[0].split("?", 1)[0]
    hostport = hostpart.rsplit("@", 1)[-1]
    if hostport.startswith("["):            # IPv6-литерал [::1]:443
        host, _, port = hostport[1:].partition("]")
        port = port.lstrip(":")
    else:
        host, _, port = hostport.partition(":")
    return {
        "url": uri,
        "protocol": scheme,
        "protocol_name": PROTO_NAMES.get(scheme, scheme.upper() or "KEY"),
        "host": host,
        "port": port or None,
        "label": label,
    }


def subscription_payload(user):
    active, disabled = user_exists(user)
    if not active and not disabled:
        return None
    node = read_kv(data_path("node.conf"))
    host = node.get("NODE_HOST")
    urls = [f"https://{host}/sub/{t}" for t in sub_tokens(user)] if host else []
    # Прямые ключи по ВСЕМ протоколам и всем нодам кластера (см. build_user_all_links).
    raw, err = run_dispatch_lines("user-all-links", user)
    raw = raw or []
    direct = [parse_direct_link(u) for u in raw]
    return {
        "username": user,
        "subscription_urls": urls,
        "subscription_url": urls[0] if urls else None,
        "links": raw,               # плоский список строк (обратная совместимость)
        "direct_links": direct,     # структурированные (протокол/хост/метка)
    }


