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
# Документация API для разработчиков: docs/API.md.
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
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from wa_core import *  # noqa: E402,F403
from wa_users import *  # noqa: E402,F403
from wa_online import *  # noqa: E402,F403
from wa_online import _stream_cv, _stream_subs, _stream_state, _stream_watcher  # noqa: E402
from wa_payload import *  # noqa: E402,F403
from wa_dispatch import *  # noqa: E402,F403

# ---------- HTTP ----------

ROUTES = [
    # (method, regex, scope|None, handler_name)
    ("GET", re.compile(r"^/v1/health$"), None, "h_health"),
    ("GET", re.compile(r"^/v1/info$"), "read", "h_info"),
    ("GET", re.compile(r"^/v1/tariffs$"), "read", "h_tariffs"),
    ("GET", re.compile(r"^/v1/nodes$"), "read", "h_nodes"),
    ("GET", re.compile(r"^/v1/online$"), "read", "h_online"),
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
    ("POST", re.compile(r"^/v1/users/([^/]+)/reset-subscription$"), "users", "h_reset_sub"),
    # Пересчёт «сейчас» — read: ничего не меняет, только освежает снимок трафика.
    ("POST", re.compile(r"^/v1/users/([^/]+)/refresh$"), "read", "h_user_refresh"),
    ("POST", re.compile(r"^/v1/demo$"), "users", "h_demo"),
    ("POST", re.compile(r"^/v1/users/([^/]+)/free-plan$"), "users", "h_free_plan"),
    ("POST", re.compile(r"^/v1/telegram/bind$"), "telegram", "h_bind"),
    ("POST", re.compile(r"^/v1/codes/redeem$"), "telegram", "h_redeem"),
    # SSE: выдача тикета — по Bearer (Laravel); сам поток — по тикету (браузер).
    ("POST", re.compile(r"^/v1/stream/ticket$"), "read", "h_stream_ticket"),
    ("GET", re.compile(r"^/v1/stream/online$"), None, "h_stream_online"),
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

    def h_online(self):
        users = online_users()
        return {"users": users, "count": len(users)}

    def h_user(self, name):
        payload = user_payload(need_username(name))
        if payload is None:
            raise ApiError(404, "user_not_found", "пользователь не найден")
        return payload

    def h_user_refresh(self, name):
        """Тот же профиль, что GET /v1/users/{name}, но сперва пересчитав трафик
        и активность (таймеры тикают раз в минуту — странице веб-аппа этого
        мало). Пересчёт глобальный и с кулдауном: `refreshed:false` значит
        «недавно уже считали», данные всё равно свежие настолько, насколько
        возможно. Ошибку пересчёта не поднимаем — профиль важнее свежести."""
        user = need_username(name)
        try:
            res = self.dispatch("traffic-refresh")
            refreshed = res.get("refreshed") == "1"
        except ApiError:
            refreshed = False
        payload = user_payload(user)
        if payload is None:
            raise ApiError(404, "user_not_found", "пользователь не найден")
        return dict(payload, refreshed=refreshed)

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

    def h_demo(self):
        # Демо-профиль гостю (idea 13): рабочий доступ до регистрации, жёстко
        # закапанный по скорости/трафику/времени. Кого пускать (один раз на
        # устройство) решает веб-апп — менеджер просто выдаёт профиль.
        res = self.dispatch("demo-create")
        expires = res.get("expires")
        return {"username": res.get("user"),
                "subscription_url": res.get("sub_url"),
                "expires_at": int(expires) if str(expires).isdigit() else None,
                "cap_bytes": int(res.get("cap") or 0),
                "rate_mbps": int(res.get("rate") or 0)}

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
            self._sse(f"data: {json.dumps(dict(zip(('online', 'bps'), last)))}\n\n")
            while True:
                with _stream_cv:
                    _stream_cv.wait_for(lambda: _stream_state.get(user) != last,
                                        timeout=STREAM_PING_SEC)
                    val = _stream_state.get(user, last)
                if val != last:
                    last = val
                    self._sse(f"data: {json.dumps(dict(zip(('online', 'bps'), last)))}\n\n")
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

    def do_POST(self):
        self.handle_route("POST")


def main():
    c = conf()
    threading.Thread(target=_stream_watcher, daemon=True).start()
    server = ThreadingHTTPServer((c["bind"], c["port"]), Handler)
    sys.stderr.write(f"hy2-webapi: listening on {c['bind']}:{c['port']}, DATA_DIR={DATA_DIR}\n")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
