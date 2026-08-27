#!/usr/bin/env python3
# ================================================
# hy2-webapi — HTTP JSON API менеджера Hysteria2 для внешних приложений
# (Telegram mini-app, биллинги, боты сторонних разработчиков).
#
# Только stdlib (python3 ≥ 3.9): демон обязан работать на голом Debian/Ubuntu
# без pip. Слушает localhost; наружу выставляется через Caddy (handle /api/* →
# reverse_proxy), см. lib/webapi.sh и setup_caddy в lib/caddy.sh.
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
# Документация API для разработчиков: docs/guide/API.md.
# ================================================
import base64
import hashlib
import hmac
import json
import os
import re
import subprocess
import signal
import sys
import threading
import time
import urllib.parse
import urllib.parse
import urllib.request
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from wa_core import *  # noqa: E402,F403
from wa_users import *  # noqa: E402,F403
from wa_online import *  # noqa: E402,F403
from wa_online import _stream_cv, _stream_subs, _stream_state, _stream_samples, _stream_watcher, stream_payload, user_nodes  # noqa: E402
from wa_payload import *  # noqa: E402,F403
from wa_footprint import footprint  # noqa: E402
from wa_dispatch import *  # noqa: E402,F403

# ---------- HTTP ----------

ROUTES = [
    # (method, regex, scope|None, handler_name)
    ("GET", re.compile(r"^/v1/health$"), None, "h_health"),
    ("GET", re.compile(r"^/v1/info$"), "read", "h_info"),
    ("GET", re.compile(r"^/v1/tariffs$"), "read", "h_tariffs"),
    ("GET", re.compile(r"^/v1/nodes$"), "read", "h_nodes"),
    ("GET", re.compile(r"^/v1/online$"), "read", "h_online"),
    ("GET", re.compile(r"^/v1/stats$"), "read", "h_stats"),
    ("GET", re.compile(r"^/v1/users/([^/]+)$"), "read", "h_user"),
    ("GET", re.compile(r"^/v1/users/([^/]+)/subscription$"), "read", "h_user_sub"),
    ("GET", re.compile(r"^/v1/users/([^/]+)/devices$"), "read", "h_devices"),
    # Адреса, которые нода помнит про юзера. Заведено для экрана «мои данные» в
    # кабинете: человек вправе видеть, что о нём хранится (DATA-RETENTION.md).
    ("GET", re.compile(r"^/v1/users/([^/]+)/ips$"), "read", "h_user_ips"),
    # Полный след человека на узле — для экрана «Мои данные» в кабинете.
    ("GET", re.compile(r"^/v1/users/([^/]+)/footprint$"), "read", "h_user_footprint"),
    # Забыть адреса старше суток. Свежие не трогаются: на них счёт устройств.
    ("DELETE", re.compile(r"^/v1/users/([^/]+)/ips$"), "users", "h_user_ips_forget"),
    # Забыть, чем скачивали подписку. В отличие от адресов — целиком: на этих
    # записях не стоит ни лимит, ни шейпинг (docs/guide/SUB-CLIENTS.md).
    ("DELETE", re.compile(r"^/v1/users/([^/]+)/clients$"), "users", "h_user_clients_forget"),
    ("GET", re.compile(r"^/v1/users/by-telegram/([^/]+)$"), "read", "h_user_by_tg"),
    # Кто владелец ссылки-подписки. Нужно приложению, чтобы показать человеку
    # страницу подписки, когда ссылку открыли браузером (docs/guide/SUB-BROWSER.md).
    ("GET", re.compile(r"^/v1/users/by-subtoken/([^/]+)$"), "read", "h_user_by_subtoken"),
    ("GET", re.compile(r"^/v1/telegram/([^/]+)$"), "read", "h_tg"),
    ("GET", re.compile(r"^/v1/payments$"), "payments", "h_payments"),
    # Каталог на запись (scope tariffs): менеджер — источник правды по продаже,
    # внешняя админка правит тарифы здесь, а не заводит свои. См. design/SALES.
    ("POST", re.compile(r"^/v1/tariffs$"), "tariffs", "h_tariff_set"),
    ("DELETE", re.compile(r"^/v1/tariffs/([^/]+)$"), "tariffs", "h_tariff_del"),
    ("POST", re.compile(r"^/v1/tariffs/([^/]+)/move$"), "tariffs", "h_tariff_move"),
    ("POST", re.compile(r"^/v1/pricing$"), "tariffs", "h_pricing_set"),
    ("POST", re.compile(r"^/v1/users$"), "users", "h_provision"),
    ("POST", re.compile(r"^/v1/users/([^/]+)/extend$"), "users", "h_extend"),
    ("POST", re.compile(r"^/v1/users/([^/]+)/enable$"), "users", "h_enable"),
    ("POST", re.compile(r"^/v1/users/([^/]+)/disable$"), "users", "h_disable"),
    ("POST", re.compile(r"^/v1/users/([^/]+)/limits$"), "users", "h_limits"),
    ("POST", re.compile(r"^/v1/users/([^/]+)/prefer$"), "users", "h_prefer"),
    ("POST", re.compile(r"^/v1/users/([^/]+)/reset-subscription$"), "users", "h_reset_sub"),
    ("POST", re.compile(r"^/v1/users/([^/]+)/devices$"), "users", "h_device_add"),
    ("DELETE", re.compile(r"^/v1/users/([^/]+)/devices/([^/]+)$"), "users", "h_device_del"),
    ("POST", re.compile(r"^/v1/demo$"), "users", "h_demo"),
    # Состояние выданного демо: живёт в demos.db и ПЕРЕЖИВАЕТ удаление юзера
    # (доступ отбирают по лимиту, а строка остаётся) — поэтому отдельно от
    # /v1/users/{name}, который на отобранном демо уже 404.
    ("GET", re.compile(r"^/v1/demo/([^/]+)$"), "read", "h_demo_state"),
    ("POST", re.compile(r"^/v1/demo/([^/]+)/refresh$"), "read", "h_demo_state_fresh"),
    ("POST", re.compile(r"^/v1/users/([^/]+)/free-plan$"), "users", "h_free_plan"),
    # Право на забвение: стирает все следы человека на этом узле. Отдельным
    # scope не гейтится — это разновидность удаления (см. docs/guide/DATA-RETENTION.md).
    ("POST", re.compile(r"^/v1/users/([^/]+)/erase$"), "users", "h_erase"),
    ("POST", re.compile(r"^/v1/telegram/bind$"), "telegram", "h_bind"),
    ("POST", re.compile(r"^/v1/codes/redeem$"), "telegram", "h_redeem"),
    # SSE: выдача тикета — по Bearer (Laravel); сам поток — по тикету (браузер).
    ("POST", re.compile(r"^/v1/stream/ticket$"), "read", "h_stream_ticket"),
    ("GET", re.compile(r"^/v1/stream/online$"), None, "h_stream_online"),
]


# Единственная ветка API, куда пускают по общему секрету кластера, а не по
# ключу webapi.keys (см. handle_route и wa_core.cluster_auth_ok).
CLUSTER_AUTH_PREFIX = "/v1/demo"


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


RE_TARIFF_CODE = re.compile(r"^[A-Za-z0-9_-]{1,32}$")
RE_TARIFF_PRICE = re.compile(r"^\d{1,9}([.,]\d{1,2})?$")
RE_TARIFF_CURRENCY = re.compile(r"^[A-Z]{3}$")
RE_TARIFF_OPTIONS = re.compile(r"^[A-Za-z0-9=;.]{0,128}$")


def need_tariff_code(value):
    if not RE_TARIFF_CODE.fullmatch(str(value or "")):
        raise ApiError(400, "invalid_code", "код тарифа: латиница, цифры, _ и -, до 32 символов")
    return str(value)


def need_tariff_title(value):
    title = str(value or "").strip()
    # «|» — разделитель полей tariffs.conf, перевод строки — разделитель строк:
    # и то и другое расщепило бы запись на две.
    if not title or len(title) > 64 or "|" in title or "\n" in title:
        raise ApiError(400, "invalid_title", "название: 1..64 символа, без «|» и переводов строк")
    return title


def need_tariff_prices(body):
    """prices[{currency,price}] (или одиночные price/currency) → «/»-списки.

    Формат хранения — два выровненных списка в одной строке tariffs.conf
    (см. lib/tariffs.sh); здесь единственное место, где внешний JSON в него
    переводится.
    """
    entries = body.get("prices")
    if entries is None:
        entries = [{"currency": body.get("currency"), "price": body.get("price")}]
    if not isinstance(entries, list) or not 1 <= len(entries) <= 8:
        raise ApiError(400, "invalid_prices", "prices: список из 1..8 цен")
    prices, currencies = [], []
    for e in entries:
        if not isinstance(e, dict):
            raise ApiError(400, "invalid_prices", "цена: объект {currency, price}")
        price = str(e.get("price", "")).strip().replace(",", ".")
        currency = str(e.get("currency", "")).strip().upper()
        if not RE_TARIFF_PRICE.fullmatch(price):
            raise ApiError(400, "invalid_price", "price: число, до 2 знаков после запятой")
        if not RE_TARIFF_CURRENCY.fullmatch(currency):
            raise ApiError(400, "invalid_currency", "currency: три заглавные буквы (XTR — Telegram Stars)")
        if currency in currencies:
            raise ApiError(400, "duplicate_currency", f"валюта {currency} указана дважды")
        if currency == "XTR" and "." in price:
            raise ApiError(400, "invalid_price", "цена в звёздах — целое число")
        prices.append(price)
        currencies.append(currency)
    return "/".join(prices), "/".join(currencies)


def need_tariff_options(value):
    """7-е поле «k=v;k=v» (free/wk/mo/start, см. lib/freeplan.sh). Пусто = нет опций."""
    options = str(value or "").strip()
    if not RE_TARIFF_OPTIONS.fullmatch(options):
        raise ApiError(400, "invalid_options", "options: строка вида «free=1;wk=3G;mo=10G»")
    return options


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
        return {"tariffs": tariffs(), "pricing": pricing()}

    def h_tariff_set(self):
        """Создать или заменить тариф целиком (upsert по коду).

        Существующий правится НА МЕСТЕ: позиция в витрине — часть каталога, и
        сохранить её важнее, чем сэкономить ветку. Опции (7-е поле) передаются
        явно: не прислали — значит их нет (иначе внешняя админка не смогла бы
        снять лимиты, docs/guide/API.md).
        """
        code = need_tariff_code(self.body.get("code"))
        title = need_tariff_title(self.body.get("title"))
        days = self.body.get("days")
        devices = self.body.get("devices", 0)
        if not (is_int(days) and 0 <= days <= 3650):
            raise ApiError(400, "invalid_days", "days: целое 0..3650")
        if not (is_int(devices) and 0 <= devices <= 1000):
            raise ApiError(400, "invalid_devices", "devices: целое 0..1000")
        prices, currencies = need_tariff_prices(self.body)
        options = need_tariff_options(self.body.get("options", ""))
        self.dispatch("tariff-set", code, title, str(days), str(devices),
                      prices, currencies, options)
        return {"tariff": next((t for t in tariffs() if t["code"] == code), None)}

    def h_tariff_del(self, code):
        code = need_tariff_code(code)
        self.dispatch("tariff-del", code)
        return {"code": code, "deleted": True}

    def h_tariff_move(self, code):
        """Порядок тарифов в витрине: up/down или на позицию N (с 1)."""
        code = need_tariff_code(code)
        where = self.body.get("position", self.body.get("direction"))
        if is_int(where) and 1 <= where <= 999:
            where = str(where)
        elif where not in ("up", "down"):
            raise ApiError(400, "invalid_move", "direction: up|down либо position: 1..999")
        self.dispatch("tariff-move", code, where)
        return {"tariffs": tariffs()}

    def h_pricing_set(self):
        """Режим звёздной цены ноды (см. guide/TARIFF-PRICING.md)."""
        current = pricing()
        mode = self.body.get("stars_mode", current["stars_mode"])
        rate = self.body.get("rub_per_star", current["rub_per_star"])
        if mode not in ("fixed", "rate"):
            raise ApiError(400, "invalid_mode", "stars_mode: fixed|rate")
        try:
            rate = float(str(rate).replace(",", "."))
        except (TypeError, ValueError):
            rate = 0
        if not 0 < rate <= 10000:
            raise ApiError(400, "invalid_rate", "rub_per_star: число больше 0")
        self.dispatch("pricing-set", mode, f"{rate:g}")
        return {"pricing": pricing()}

    def h_nodes(self):
        return {"nodes": nodes()}

    def h_online(self):
        users = online_users()
        return {"users": users, "count": len(users)}

    def h_stats(self):
        """Сводка по кластеру для витрин: сколько людей в сети сейчас (любых —
        платных, бесплатных, демо) и сколько трафика прокачано за всё время.

        «В сети» здесь — подключён к любой ноде (connected_users), а не «двигает
        трафик» как в /v1/online: витрине нужен человек, который сидит с
        включённым клиентом, даже если он в этот момент ничего не качает.
        """
        return {"online": len(connected_users()), "traffic_bytes": total_traffic()}

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

    def h_devices(self, name):
        payload = devices_payload(need_username(name))
        if payload is None:
            raise ApiError(404, "user_not_found", "пользователь не найден")
        return payload

    def h_user_ips(self, name):
        user = need_username(name)
        # Существование проверяем тем же payload, что и h_user: несуществующему
        # имени положен 404, а не пустой список (он читался бы как «чисто»).
        if user_payload(user) is None:
            raise ApiError(404, "user_not_found", "пользователь не найден")
        return user_ips(user)

    def h_user_footprint(self, name):
        user = need_username(name)
        if user_payload(user) is None:
            raise ApiError(404, "user_not_found", "пользователь не найден")
        return footprint(user)

    def h_user_ips_forget(self, name):
        user = need_username(name)
        res = self.dispatch("ips-forget", user)

        return {"username": user, "removed": int(res.get("removed") or 0),
                "left": int(res.get("left") or 0),
                "kept_newer_than_hours": 24}

    def h_user_clients_forget(self, name):
        user = need_username(name)
        res = self.dispatch("apps-forget", user)
        return {"username": user, "removed": int(res.get("removed") or 0)}

    def h_device_add(self, name):
        # Новая ссылка-устройство: свой пароль и свой слот в движке
        # (hy2-manager/docs/guide/SLOTS.md). Лимит — по числу устройств юзера,
        # его держит сам менеджер (sub_link_add), здесь не дублируем.
        user = need_username(name)
        res = self.dispatch("link-add", user)
        return {"username": user, "token": res.get("token"),
                "devices": devices_payload(user)}

    def h_device_del(self, name, token):
        user = need_username(name)
        self.dispatch("link-del", user, token)
        return {"username": user, "removed": token,
                "devices": devices_payload(user)}

    def h_user_by_tg(self, tg_id):
        user = tg_username(need_tg_id(tg_id))
        if not user:
            raise ApiError(404, "not_linked", "telegram-аккаунт не привязан")
        payload = user_payload(user)
        if payload is None:
            raise ApiError(404, "user_not_found", "привязка есть, но пользователь удалён")
        return payload

    def h_user_by_subtoken(self, token):
        """Юзер по токену подписки. Токен — секрет самого человека: предъявивший
        его и так скачивает по нему ключи, ничего нового мы не открываем."""
        if not re.fullmatch(r"[A-Za-z0-9]{16,64}", token or ""):
            raise ApiError(400, "invalid_token", "токен подписки: латиница и цифры")
        user = subtoken_user(token)
        if not user:
            raise ApiError(404, "unknown_token", "токен подписки не найден")
        payload = user_payload(user)
        if payload is None:
            raise ApiError(404, "user_not_found", "токен есть, но пользователь удалён")
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
        # Отрицательные дни укорачивают срок: так мини-апп забирает дни в
        # эскроу подарочной ссылки. Ноль запрещён — это не операция.
        if not (is_int(days) and days != 0 and -3650 <= days <= 3650):
            raise ApiError(400, "invalid_days", "days: целое -3650..3650, кроме 0")
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

    def h_prefer(self, name):
        # Какой ключ идёт в подписке первым, «host/протокол» (P-76). Пустая
        # строка или null — снять выбор. Отдельно от limits: там пересборка
        # kernel-лимитов, которая к порядку ключей отношения не имеет и стоит
        # секунд, а этот вызов делает клиент из кабинета и ждёт ответа.
        user = need_username(name)
        prefer = self.body.get("prefer") or ""
        if not isinstance(prefer, str) or (prefer and not RE_PREFER.match(prefer)):
            raise ApiError(400, "invalid_prefer", "prefer: «host/протокол» или пусто")
        # «-» = снять: пустой аргумент потерялся бы в вызове dispatch.sh.
        res = self.dispatch("set-prefer", user, prefer or "-")
        return {"username": user, "prefer": res.get("prefer", "")}

    def h_reset_sub(self, name):
        # Новая ссылка + новый пароль (а значит и все производные ключи протоколов).
        # На пирах пароль прокрутится на их ближайшем cluster_sync (~5 мин).
        user = need_username(name)
        res = self.dispatch("reset-subscription", user)
        return {"username": user, "subscription_url": res.get("sub_url")}

    def h_free_plan(self, name):
        # Подключить бесплатный тариф по кнопке в кабинете (idea 02): окна
        # трафика стартуют с первого выхода в онлайн, поэтому сразу — pending.
        user = need_username(name)
        res = self.dispatch("free-activate", user)
        return {"username": user, "state": res.get("state"), "free": free_status(user, sum(local_traffic(user)) + sum(peer_stats(user)[1:]))}

    def h_erase(self, name):
        """Стереть все следы пользователя: профиль, привязку Telegram, адреса,
        окна бесплатного тарифа, строки журналов. Идемпотентно: профиля может
        уже не быть, тогда чистятся только остатки."""
        user = need_username(name)
        self.dispatch("erase", user)
        return {"username": user, "erased": True}

    def h_demo(self):
        # Демо-профиль гостю (idea 13): рабочий доступ до регистрации, жёстко
        # закапанный по скорости/трафику/времени. Кого пускать (один раз на
        # устройство) решает веб-апп — менеджер просто выдаёт профиль.
        # Ноду-приёмник выбирает менеджер (lib/demo.sh: demo_pick_node), поэтому
        # ссылка может вести на любую ноду кластера — её домен в поле node.
        res = self.dispatch("demo-create")
        expires = res.get("expires")
        return {"username": res.get("user"),
                "subscription_url": res.get("sub_url"),
                "expires_at": int(expires) if str(expires).isdigit() else None,
                "cap_bytes": int(res.get("cap") or 0),
                "rate_mbps": int(res.get("rate") or 0),
                "node": res.get("node") or node_host()}

    def h_demo_state(self, name, refresh=False):
        """Что сейчас с демо-профилем: состояние, лимит, расход, онлайн.
        `alive` — жив ли ещё сам пользователь (лимит исчерпан или время вышло →
        доступ отобран, но строка demos.db остаётся: гостю надо объяснить, что
        случилось). refresh=True сперва пересчитывает трафик (см.
        /v1/users/{name}/refresh)."""
        user = need_username(name)
        row = demo_row(user)
        if row is None:
            raise ApiError(404, "demo_not_found", "демо-профиль не найден")

        # Профиль на другой ноде — спрашиваем её: трафик, TTL и отбор доступа
        # считает она, а у нас лежит только строка-указатель. Клиенту при этом
        # ничего не меняется: ручка та же, поля те же.
        node = demo_node(row)
        if node and node != node_host():
            path = "/v1/demo/%s%s" % (urllib.parse.quote(user), "/refresh" if refresh else "")
            try:
                data = cluster_request(node, path, "POST" if refresh else "GET")
            except Exception:
                raise ApiError(502, "demo_node_unreachable",
                               "нода демо-профиля не отвечает")
            return dict(data, username=user, node=node)

        refreshed = False
        if refresh:
            try:
                refreshed = self.dispatch("traffic-refresh").get("refreshed") == "1"
            except ApiError:
                refreshed = False
        active, _disabled = user_exists(user)
        total = sum(local_traffic(user)) + sum(peer_stats(user)[1:])
        demo = demo_status(user, total)
        if demo is None:
            raise ApiError(404, "demo_not_found", "демо-профиль не найден")
        return dict(demo, username=user, alive=bool(active),
                    online=is_online(user) if active else False, refreshed=refreshed,
                    node=node or node_host())

    def h_demo_state_fresh(self, name):
        return self.h_demo_state(name, refresh=True)

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

    # -- SSE live-статус онлайн --

    def h_stream_ticket(self):
        user = need_username(self.body.get("username"))
        return {"ticket": make_stream_ticket(user), "expires_in": STREAM_TICKET_TTL}

    def h_stream_online(self):
        user = parse_stream_ticket(self.query.get("ticket", ""))
        if not user:
            raise ApiError(401, "invalid_ticket", "плохой или просроченный тикет")
        self._stream_online(user)
        return STREAM_HANDLED

    def _stream_online(self, user):
        """Держит text/event-stream и пушит {online:bool, bps:int} при изменении
        статуса или скорости (+ keepalive-комментарии). Под HTTP/1.1 без
        Content-Length закрываем keep-alive: клиент читает поток до закрытия
        сокета (EventSource — ок)."""
        self.close_connection = True
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.send_header("X-Accel-Buffering", "no")  # на случай буферизующих прокси
        self.end_headers()
        with _stream_cv:
            _stream_subs[user] = _stream_subs.get(user, 0) + 1
        try:
            last = stream_snapshot(user)
            with _stream_cv:
                _stream_state[user] = last
                payload = stream_payload(user, last)
            payload["nodes"] = user_nodes(user)   # разбивка по нодам, вне лока (файлы)
            self._sse(f"data: {json.dumps(payload)}\n\n")
            while True:
                with _stream_cv:
                    _stream_cv.wait_for(lambda: _stream_state.get(user) != last,
                                        timeout=STREAM_PING_SEC)
                    val = _stream_state.get(user, last)
                    payload = stream_payload(user, val) if val != last else None
                if payload is not None:
                    last = val
                    payload["nodes"] = user_nodes(user)   # вне лока (файлы)
                    self._sse(f"data: {json.dumps(payload)}\n\n")
                else:
                    self._sse(": ping\n\n")   # keepalive: держим соединение живым
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass  # клиент отвалился — штатно
        finally:
            with _stream_cv:
                n = _stream_subs.get(user, 0) - 1
                if n <= 0:
                    _stream_subs.pop(user, None)
                    _stream_state.pop(user, None)
                    _stream_samples.pop(user, None)
                else:
                    _stream_subs[user] = n

    def _sse(self, text):
        self.wfile.write(text.encode("utf-8"))
        self.wfile.flush()

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
                               "метод не поддерживается" if matched else "нет такого эндпоинта (см. docs/guide/API.md)")
            if scope is not None:
                key = authenticate(self.headers.get("Authorization"))
                # Соседняя нода приходит не с ключом, а с общим секретом кластера
                # (тем же, что в cluster_call) — и только за демо: она заводит
                # профиль у себя по нашему выбору ноды (lib/demo.sh:
                # demo_create_remote) и отвечает нам о его состоянии.
                if key is None and path.startswith(CLUSTER_AUTH_PREFIX) \
                        and cluster_auth_ok(self.headers.get("X-Cluster-Auth")):
                    key = {"name": "cluster", "scopes": {"read", "users"}}
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
                    # Пустой список — это «параметров нет»: так сериализуется
                    # пустой массив в PHP/Laravel (json_encode([]) → "[]").
                    # Отвергать такой запрос к ручке без параметров незачем.
                    if self.body == []:
                        self.body = {}
                    if not isinstance(self.body, dict):
                        raise ApiError(400, "invalid_json", "ожидается JSON-объект")
                else:
                    self.body = {}
            data = getattr(self, handler)(*match.groups())
            status = 200
            if data is not STREAM_HANDLED:   # SSE-хендлер уже сам отдал поток
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

    def do_DELETE(self):
        self.handle_route("DELETE")

    def do_POST(self):
        self.handle_route("POST")


def main():
    c = conf()
    threading.Thread(target=_stream_watcher, daemon=True).start()
    server = ThreadingHTTPServer((c["bind"], c["port"]), Handler)
    # systemctl stop шлёт SIGTERM, а не SIGINT: без обработчика процесс умирал
    # на месте, обрывая открытые SSE-соединения на полуслове.
    signal.signal(signal.SIGTERM, lambda *_: threading.Thread(target=server.shutdown).start())
    sys.stderr.write(f"hy2-webapi: listening on {c['bind']}:{c['port']}, DATA_DIR={DATA_DIR}\n")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        sys.stderr.write("hy2-webapi: stopped\n")


if __name__ == "__main__":
    main()
