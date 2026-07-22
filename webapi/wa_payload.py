#!/usr/bin/env python3
# ================================================
# Сборка JSON-ответа по пользователю: токены подписки, привязка Telegram.
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
from wa_users import *  # noqa: F403
from wa_online import *  # noqa: F403



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
    total = ltx + ptx + lrx + prx
    return {
        "username": user,
        # Бесплатный тариф (idea 02): null — юзер не на нём. Расход показываем
        # по данным сбора: он до 30 мин отстаёт от того, что видит отключение.
        "free": free_status(user, total),
        "status": "active" if active else "disabled",
        "expiry": expiry,                      # null = бессрочно
        "days_left": days_left(expiry),
        "unlimited": expiry is None,
        "limits": limits,
        "traffic": {
            "tx_bytes": ltx + ptx,
            "rx_bytes": lrx + prx,
            "total_bytes": total,
        },
        # online_connections — сырое число соединений всех движков (включая пинги),
        # оставлено для совместимости API. online — «реально пользуется сейчас»
        # по активности трафика всех протоколов (см. is_online): пинги не в счёт.
        "online_connections": (lonline or 0) + ponline if lonline is not None else ponline,
        "online": is_online(user),
        "devices_seen": user_ip_count(user),
    }

