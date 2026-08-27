#!/usr/bin/env python3
# ================================================
# Сборка JSON-ответа по пользователю: токены подписки, привязка Telegram.
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



def sub_tokens(user):
    """Ссылки-устройства юзера: свои (первая — основная) + доп. ссылки пиров.

    ПЕРВЫЙ токен юзера в файле пира — основной токен ТОЙ ноды: свой основной
    заводит каждая нода кластера, и это копия той же подписки, а не купленная
    ссылка. В устройства такие копии не идут — иначе человек «занимал» бы N−1
    устройств, которых не покупал (P-101). То же правило на стороне менеджера —
    sub_links_used (lib/sub_links.sh); считать надо одинаково, иначе кабинет и
    нода разойдутся в том, сколько устройств занято.
    """
    tokens = list(colon_db(data_path("subtokens.db")).get(user, []))
    try:
        names = sorted(os.listdir(PEERS_DIR))
    except OSError:
        names = []
    for name in names:
        if not name.endswith(".subtokens"):
            continue
        peer = [t for t in colon_db(os.path.join(PEERS_DIR, name)).get(user, []) if t not in tokens]
        # Своих токенов нет вовсе (юзера завела другая нода) — её основной
        # становится основным и здесь, иначе список остался бы пустым.
        tokens.extend(peer[1:] if tokens else peer)
    return tokens


def served_tokens(user):
    """ВСЕ токены, по которым наша нода отдаёт подписку этого юзера.

    Отличается от sub_tokens: там устройства (основные токены пиров не в счёт,
    P-101), здесь — по каким путям к нам вообще ходят за подпиской. Наш Caddy
    отдаёт и токены, выданные соседями, значит их скачивания тоже записаны в
    subapps.dat нашим сборщиком.
    """
    tokens = list(colon_db(data_path("subtokens.db")).get(user, []))
    try:
        names = sorted(os.listdir(PEERS_DIR))
    except OSError:
        names = []
    for name in names:
        if name.endswith(".subtokens"):
            tokens.extend(t for t in colon_db(os.path.join(PEERS_DIR, name)).get(user, [])
                          if t not in tokens)
    return tokens


def subtoken_user(token):
    """Обратный поиск: чей это токен подписки.

    Смотрим и свою базу, и кэши токенов пиров: у каждой ноды кластера для одного
    человека свой токен, а ссылку он мог получить с любой из них — искать только
    у себя значило бы «не наш токен» для половины живых ссылок.
    """
    if not token:
        return None
    paths = [data_path("subtokens.db")]
    try:
        paths += [os.path.join(PEERS_DIR, n) for n in sorted(os.listdir(PEERS_DIR))
                  if n.endswith(".subtokens")]
    except OSError:
        pass
    for path in paths:
        for user, tokens in colon_db(path).items():
            if token in tokens:
                return user
    return None


def user_clients(user):
    """Чем скачивали подписку: приложение, версия, ОС, устройство.

    Источник — subapps.dat (docs/guide/SUB-CLIENTS.md), заполняется разбором
    заголовков запроса за подпиской. На туннеле приложение не видно ни одному
    движку, поэтому других источников у этих полей нет.

    Сам X-Hwid наружу НЕ отдаём — это отпечаток устройства, и место ему там же,
    где паролю профиля: нигде. Наружу идёт хвост, которого хватает отличить одну
    запись от другой и не хватает опознать аппарат. Клиент, не приславший hwid
    (Hiddify, v2rayNG), помечен identified=false: это не устройство, а «кто-то с
    таким приложением», и считать по нему устройства нельзя.
    """
    tokens = set(served_tokens(user))
    if not tokens:
        return []
    out = []
    for r in pipe_rows(data_path("subapps.dat"), 9):
        if r[0] not in tokens:
            continue
        hwid = r[1]
        synthetic = hwid.startswith("~")
        try:
            first, last, hits = int(r[6]), int(r[7]), int(r[8])
        except ValueError:
            continue
        out.append({
            "id": None if synthetic else hwid[-6:],
            "identified": not synthetic,
            "app": r[2] or None,
            "version": r[3] or None,
            "os": r[4] or None,
            "model": r[5] or None,
            "first_seen": first,
            "last_seen": last,
            "fetches": hits,
        })
    out.sort(key=lambda c: c["last_seen"], reverse=True)
    return out


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
        # Чем человек пользуется (docs/guide/SUB-CLIENTS.md). Пустой список —
        # не «нет устройств», а «за подпиской ещё не приходили с этой ноды».
        "clients": user_clients(user),
    }

